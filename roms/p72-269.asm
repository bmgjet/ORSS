; p72-269.asm - the P72 ECU (269, JDM B18C), annotated.
;
; Disassembled by OkiRomSim from the raw ROM image, then annotated: the routine names and the comment
; blocks above them were worked out from the code (roms/p72work), and the calibration tables are
; labelled with table definitions. The maps, their axes and the fuel column multipliers come from P72's
; own lookup code; the other tables were found by lining P72's code up with the stock P30's, which is
; the same design, and carry the P30 skeleton's names. Anything never reached from the vectors is kept
; as DB bytes. Assembling this file reproduces the original image byte for byte.
;
; Maps: FuelLow 20x10 and FuelHigh 15x10 (each with its column multipliers after the last row),
; IgnitionLow 20x10 and IgnitionHigh 15x10, a second pair IgnitionLow2 / IgnitionHigh2, and VEHigh 15x10.
; Loads are the MAP byte (x * 3.6105 + 114.3 mbar); the high-cam rpm byte is 53125 / period.

                org 0000h
int_start_vec:            DW  boot_main
int_break_vec:            DW  boot_trap_handler
int_WDT_vec:              DW  wdt_trap
int_NMI_vec:              DW  nmi_period_sync
int_INT0_vec:             DW  int0_tdc_flag
int_serial_rx_vec:        DW  serial_rx_state
int_serial_tx_vec:        DW  spurious_irq_trap
int_irq3_vec:             DW  irq3_engine_irq
int_timer_0_overflow_vec: DW  spurious_irq_trap
int_timer_0_vec:          DW  inj_pulse_end_irq
int_timer_1_overflow_vec: DW  spurious_irq_trap
int_timer_1_vec:          DW  iacv_tick_irq
int_timer_2_overflow_vec: DW  t2_overflow_irq
int_timer_2_vec:          DW  ckp_edge_irq
int_timer_3_overflow_vec: DW  spurious_irq_trap
int_timer_3_vec:          DW  ign_fire_irq
int_adc_vec:              DW  spurious_irq_trap
int_PWM_vec:              DW  pwm_tick_irq
int_irq14_vec:            DW  spurious_irq_trap
int_INT1_vec:             DW  engine_main_irq
vcal_0_vec:               DW  vcal0_interp_entry
vcal_1_vec:               DW  vcal1_interp_entry
vcal_2_vec:               DW  vcal2_interp_entry
vcal_3_vec:               DW  housekeeping_tick
vcal_4_vec:               DW  vcal4_interp_entry
vcal_5_vec:               DW  vcal5_interp_entry
vcal_6_vec:               DW  vcal6_scale_entry
vcal_7_vec:               DW  vcal7_scale_entry
                DB  000h,063h,062h,000h
; NMI = periodic sync tick: advances the analog mux (P2.5-7) and reads the A/D channel, uses TMR1,
; reads the period words at RAM 0x05/0x07, table lookups, 2 loops, can BRK on fault.
nmi_period_sync:
                CLR PSW
                MOV LRB, #00041h
                RB off(030h).7
                JEQ nmi_snapshot_dp_skip
                L A, DP
                ST A, 00084h[X1]
nmi_snapshot_dp_skip:
                MOV DP, #00007h
nmi_period_sync_branch:
                JRNZ DP, nmi_period_sync_branch
                MOV DP, #00005h
nmi_poll_p4_1:
                MB C, P4.1
                JGE nmi_period_sync_load_ramf5
                JRNZ DP, nmi_poll_p4_1
                MOVB P2, #0FFh
                RB TCON0.2
                SB TCON0.2
                CLRB A
                STB A, ADSCAN
                STB A, ADSEL
                MOV IE, #00040h
                MOVB TCON1, #0E0h
                CLR IRQ
                SB P4SF.1
                MOV TM1, #0FFFFh
                SB TCON1.4
                SB SBYCON.2
                LB A, #005h
                STB A, STPACP
                SLLB A
                STB A, STPACP
                SB SBYCON.0
                RB 0B7h.1
nmi_period_sync_load_ramf5:
                LB A, 0F5h
                JNE nmi_period_sync_trap
                MOVB 0F5h, #047h
nmi_period_sync_trap:
                BRK
; TMR0 match = injector pulse end: re-arms TMR0 (TM0), advances the bank pattern (096h/097h), updates
; the P2 injector drivers and TCON0; 4 loop states.
inj_pulse_end_irq:
                MOV LRB, #00022h
                ANDB TCON0, #0FBh
                CMPB r7, #00Fh
                JEQ timer0_return
                L A, er0
                JNE timer0_bit_accumulate
                L A, er1
                JEQ timer0_final_bit_check
                ADD TMR0, A
                LB A, r6
                MB C, ACC.7
                ROLB r6
                ORB A, r6
                ANDB A, #00Fh
                ORB r7, A
                ORB off(097h), A
                LB A, r6
                SLLB A
                ROLB r6
                MOV er0, er2
                L A, #00001h
                ST A, er1
timer0_bitshift_loop:
                ST A, er2
                L A, er0
                JNE timer0_bit_shift_right
                L A, er1
                JEQ timer0_bit_invert
                LB A, r6
                SRLB A
                SRLB A
                SRLB A
                ORB A, r6
timer0_bit_output:
                ORB A, off(097h)
                ANDB A, #00Fh
                ORB P2, A
                RTI
timer0_bit_shift_right:
                LB A, r6
                SJ timer0_bit_output
timer0_bit_invert:
                LB A, r6
                RORB A
                XORB A, #0FFh
                J timer0_bit_output
timer0_return:
                RTI
timer0_bit_accumulate:
                ADD TMR0, A
                LB A, r6
                ANDB A, #00Fh
                ORB r7, A
                ORB off(097h), A
                LB A, r6
                SLLB A
                ROLB r6
                MOV er0, er1
                MOV er1, er2
                L A, #00001h
                J timer0_bitshift_loop
timer0_final_bit_check:
                L A, er2
                JEQ timer0_sequence_done
                ADD TMR0, A
                LB A, r6
                MB C, ACC.0
                RORB A
                STB A, r6
                XORB A, #0FFh
                ANDB A, #00Fh
                ORB r7, A
                ORB off(097h), A
                LB A, r6
                ANDB A, #00Fh
timer0_sequence_reset:
                ORB P2, A
                L A, #00001h
                ST A, er0
                ST A, er1
                ST A, er2
                RTI
timer0_sequence_done:
                LB A, #00Fh
                STB A, r7
                STB A, off(097h)
                SJ timer0_sequence_reset
; TMR1 match = IACV PWM tick (2.048 ms period): duty 041h, phase words 098h/09Ah, 068h, updates 036h/
; 041h/0B6h.
iacv_tick_irq:
                MOV LRB, #00013h
                JBR off(041h).3, timer1_tmr1_reload
                RB off(0B6h).5
                JNE timer1_check_start
                CMP er1, #0064Ah
                JLT timer1_check_start
                ORB off(0B6h), #020h
                L A, #003B6h
                SUB er1, A
                ADD off(036h), A
                RTI
timer1_check_start:
                ANDB off(041h), #0F7h
                L A, off(068h)
                ST A, er2
                ADD off(036h), off(09Ah)
                RTI
timer1_tmr1_reload:
                ORB off(041h), #008h
                INCB r6
                L A, #00A00h
                SUB A, er0
                ST A, er1
                ADD off(036h), off(098h)
                RTI
; TMR2 compare = CKP tooth edge: captures TM2 into 018h/019h, period words 03Ah/03Ch, RPM 043h,
; 06Ch/0A0h/0E8h state, flags 0B7h/0BAh; 6 loop states.
ckp_edge_irq:
                MOV LRB, #00014h
                LB A, r2
                CMPB A, #003h
                JGE ckp_edge_irq_branch
                ADDB A, #001h
                JBS off(006h).0, timer2_state_dispatch
                MOV off(0BAh), off(06Ch)
timer2_state_dispatch:
                CMPB A, r0
                JEQ timer3_reload_add
                JLT timer3_reload_dec
timer2_tcon3_and_ram43:
                ANDB off(043h), #0FBh
timer3_reload_dec:
                L A, off(03Ch)
                SUB A, #00001h
                ST A, off(03Eh)
timer2_irq_and_ram19:
                ANDB off(019h), #0F7h
                ORB off(018h), #008h
                RB off(046h).0
                JEQ ckp_edge_irq_return
                SB off(0B7h).2
ckp_edge_irq_return:
                RTI
ckp_edge_irq_branch:
                JEQ timer2_state2_check
                JBR off(006h).0, timer2_tcon3_check2
                JBS off(0A0h).3, timer2_tcon3_and_ram43
                CLRB A
                ORB off(043h), #004h
                J timer2_state_dispatch
timer2_state2_check:
                LB A, r0
                ADDB A, #001h
                CMPB A, #005h
                JGE timer2_load_ram3a
                ANDB off(043h), #0FBh
                L A, er2
                CMP A, #0001Fh
                JGE timer2_tmr2_add
                L A, #0001Fh
timer2_tmr2_add:
                ADD A, off(03Ah)
                J timer3_reload_store_ram3e
timer2_tcon3_check:
                JBS off(043h).3, timer3_reload_dec
timer2_load_ram3a:
                L A, off(03Ah)
                ADD A, er2
                ST A, er3
timer3_reload_add:
                L A, off(03Ah)
                ADD A, off(0E8h)
                ST A, off(03Eh)
                ANDB off(043h), #0F7h
                SJ timer2_irq_and_ram19
timer2_tcon3_check2:
                JBS off(043h).2, timer2_tcon3_check
                L A, off(03Ch)
                SUB A, off(03Ah)
                ADD A, #00006h
                CMP A, er2
                JGE timer3_reload_alt
                L A, off(03Ah)
                ADD A, er2
                SJ timer3_reload_store_ram3e
timer3_reload_alt:
                L A, off(03Ch)
                ADD A, #00004h
timer3_reload_store_ram3e:
                ST A, off(03Eh)
                ORB off(043h), #008h
                J timer2_irq_and_ram19
; INT0 (P3.2 on the P28 board = TDC/CKP flag line): reads TM2 and the period word 0x07, sets the 01Ah
; (bit 7) and 0B6h flags, restores IE from 0F8h/0FAh.
int0_tdc_flag:
                L A, 0FAh
                ST A, IE
                L A, TM2
                ORB PSWH, #001h
                MOV LRB, #00015h
                JBS off(007h).7, int_int0_edge_check
                JBR off(019h).0, int_int0_edge_check
                INCB r3
                ORB off(0B6h), #002h
int_int0_edge_check:
                XCHG A, er0
                ST A, er2
                CLRB A
                XCHGB A, r3
                STB A, r2
                ORB off(0B6h), #004h
                L A, off(0F8h)
                ANDB PSWH, #0FEh
                ST A, off(01Ah)
                RTI
; Serial RX (P3.1, tuning-link / datalog): the RX state machine - SRBUF byte in, SRCON status,
; 0x035C table, byte counter 056h / step 05Ch, 7 loop states, STBUF byte out, IE restore.
serial_rx_state:
                L A, 0FAh
                ST A, IE
                MOV PSW, #00102h
                MOV LRB, #0007Eh
                JBR off(056h).1, int_serial_rx_clear_acc
                RB off(056h).6
                JEQ int_serial_rx_load_r7
                CLR A
                LB A, r5
                CMPB A, #002h
                JEQ int_serial_rx_load_r2
                CMPB A, r2
                JGE int_serial_rx_branch
                ADDB A, r3
                L A, ACC
                SLL A
                ADD A, #06059h
                MOV DP, A
                LC A, [DP]
                MOV DP, A
                LB A, [DP]
int_serial_rx_addb_add_r6:
                ADDB r6, A
int_serial_rx_store_stbuf:
                STB A, STBUF
                INCB r5
                SB off(056h).6
int_serial_rx_load_ramf8:
                L A, 0F8h
                ANDB PSWH, #0FEh
                ST A, IE
                RTI
int_serial_rx_load_r2:
                LB A, r2
                SJ int_serial_rx_addb_add_r6
int_serial_rx_branch:
                JNE int_serial_rx_load_ramf8
                CLRB A
                SUBB A, r6
                SJ int_serial_rx_store_stbuf
int_serial_rx_load_r7:
                LB A, r7
                JEQ int_serial_rx_set_r0
                LB A, r5
                CMPB A, #001h
                JEQ int_serial_rx_load_srbuf
                ADDB A, #001h
                CMPB A, r2
                JEQ int_serial_rx_load_srbuf_2
                LB A, SRBUF
                CMPB r5, #002h
                JNE int_serial_rx_store_r4
                STB A, r3
                SJ int_serial_rx_addb_add_r6_2
int_serial_rx_store_r4:
                STB A, r4
int_serial_rx_addb_add_r6_2:
                ADDB r6, A
                INCB r5
int_serial_rx_set_r7:
                MOVB r7, #002h
                J int_serial_rx_load_ramf8_2
int_serial_rx_set_r0:
                MOVB r0, r1
                LB A, SRBUF
                STB A, r1
                STB A, r6
                MOVB r5, #001h
                SJ int_serial_rx_set_r7
int_serial_rx_load_srbuf:
                LB A, SRBUF
                STB A, r2
                SJ int_serial_rx_addb_add_r6_2
int_serial_rx_load_srbuf_2:
                LB A, SRBUF
                ADDB A, r6
                JNE int_serial_rx_clear_r7
                LB A, r1
                ANDB A, #0E0h
                CMPB A, #020h
                JNE int_serial_rx_clear_r7
                SB off(056h).7
int_serial_rx_clear_r7:
                CLRB r7
int_serial_rx_load_ramf8_2:
                L A, 0F8h
                ANDB PSWH, #0FEh
                ST A, IE
                RTI
int_serial_rx_clear_acc:
                CLRB A
                RB SRSTAT.3
                JEQ int_serial_rx_clear_srstat_b2
                ADDB A, #001h
int_serial_rx_clear_srstat_b2:
                RB SRSTAT.2
                JEQ int_serial_rx_store_acch
                ADDB A, #002h
int_serial_rx_store_acch:
                STB A, ACCH
                LB A, SRBUF
                MOV DP, A
                L A, DP
                JEQ int_serial_rx_set_dp
                SRL A
                JLT int_serial_rx_load_ind
                L A, [DP]
                LB A, ACC
                MOVB off(05Ch), ACCH
int_serial_rx_store_stbuf_2:
                STB A, STBUF
                SJ int_serial_rx_load_ramf8
int_serial_rx_set_dp:
                MOV DP, #0035Ch
int_serial_rx_load_ind:
                LB A, [DP]
                SJ int_serial_rx_store_stbuf_2
                DB  0E5h,0FAh,0D5h,01Ah,0B5h,004h,098h,002h
                DB  001h,067h,000h,001h,0F5h,055h,0C5h,056h
                DB  00Bh,0CEh,00Ch,0C5h,006h,02Fh,0C5h,007h
                DB  015h,0CAh,004h,0C5h,007h,098h,002h,052h
                DB  0F2h,0D5h,051h,0E5h,0F8h,0A2h,008h,0B5h
                DB  01Ah,08Ah,002h
; TMR2 overflow: small handler, masks IE.
t2_overflow_irq:
                L A, 0FAh
                ST A, IE
                ORB PSWH, #001h
                MOV LRB, #00015h
                RB off(0B6h).0
                JNE timer2ovf_edge_check2
                INCB r6
timer2ovf_edge_check2:
                RB off(0B6h).1
                JNE timer2ovf_return
                INCB r3
timer2ovf_return:
                L A, 0F8h
                ANDB PSWH, #0FEh
                ST A, IE
                RTI
; TMR3 compare = spark fire: updates the fire state 03Eh/043h (reads 043h), restores IE.
ign_fire_irq:
                L A, 0FAh
                ST A, IE
                ORB PSWH, #001h
                MOV LRB, #00014h
                LB A, r0
                ADDB A, #001h
                CMPB A, #005h
                JLT timer3isr_return
                JBS off(043h).2, timer3isr_return
                MOV off(03Eh), er3
                ORB off(043h), #008h
timer3isr_return:
                L A, off(0F8h)
                ANDB PSWH, #0FEh
                ST A, IE
                RTI
; PWM interrupt: reads TM2 (period), restores IE.
pwm_tick_irq:
                L A, 0FAh
                ST A, IE
                ORB PSWH, #001h
                MOV LRB, #0007Dh
                L A, 0F8h
                ANDB PSWH, #0FEh
                ST A, IE
                RTI
; The main engine interrupt (INT1): sensor A/D scan, TMR0/TMR2 capture, CYP/igniter feedback (TRNSIT),
; multiply/divide, table lookups (0x0311, 0x0362, 0x0366, 0x0375, 0x037B), calls inj_pulse_engine,
; vss_rpm_update, the interp entries vcal1/6/7 and the scale helpers, inj_words_
;stash, then tail-jumps to ign_dispatch (0x649E).
engine_main_irq:
                L A, #000A0h
                ST A, IE
                MOV PSW, #00102h
                MOV LRB, #00021h
                MOV USP, #00280h
                CAL inj_words_stash
                SB off(028h).4
                JBS off(01Ah).7, int1_dispatch_main_cycle
                JBS off(01Ah).3, int1_dispatch_alt1
                RB IRQH.1
                JEQ dtc04_ckp_latch
                RB 0B4h.0
                MOVB off(0D1h), #02Dh
int1_dispatch_main_cycle:
                J crank_cycle_entry
dtc04_ckp_latch:
                SB 0B4h.0
int1_dispatch_alt1:
                L A, ADCR6
                ST A, 0BAh
                L A, TM2
                ST A, 0F0h
                MOVB 0A2h, #000h
                LB A, #003h
                RB TRNSIT.0
                JNE crank_tooth_count_store_ram34
                LB A, off(034h)
                ADDB A, #006h
                CMPB A, #018h
                JLT crank_tooth_count_store_ram34
                LB A, #003h
crank_tooth_count_store_ram34:
                STB A, off(034h)
                SB P4.0
                MB C, off(01Bh).6
                MB off(02Ah).1, C
                JBS off(028h).2, int1_exit_jump
                LB A, off(03Dh)
                JNE int1_exit_jump
                STB A, off(03Ch)
                SB off(028h).2
                ANDB PSWH, #0FEh
                MOVB off(096h), #077h
                MOVB off(016h), #011h
                ORB PSWH, #001h
int1_exit_jump:
                J crank_cycle_dispatch2
; IRQ3: second entry into the engine interrupt - same body and callees as engine_main_irq (inj_pulse_
;engine, vss_rpm_update, vcal1/7, the scale helpers, inj_words_stash) without vcal6; INT1 and IRQ3
; both drive the engine computation.
irq3_engine_irq:
                L A, #000A0h
                ST A, IE
                MOV PSW, #00102h
                MOV LRB, #00021h
                MOV USP, #00280h
                L A, -110[USP]
                ST A, off(01Ah)
                L A, -108[USP]
                ST A, off(01Ch)
                L A, -106[USP]
                ST A, off(01Eh)
                MOVB off(0D1h), #02Dh
                JBR off(028h).3, crank_sync_flags_clear_irqh_b7
                JBS off(01Ah).7, irq3_engine_irq_set_ram28_b4
                RB IRQH.7
                JNE crank_sync_lost_path_set_ram28_b4
                RB 0B6h.7
                JNE crank_sync_lost_path_set_ram28_b4
crank_sync_retry_check:
                CMPB 0A2h, #005h
                JGE crank_sync_confirm_check
                INCB 0A2h
                J crank_tooth_counter_reset_if_ram1b_b0_set
irq3_engine_irq_set_ram28_b4:
                SB off(028h).4
                SJ crank_sync_retry_check
crank_sync_confirm_check:
                JBS off(01Ah).7, crank_sync_confirmed
                SB 0B4h.1
                SB off(028h).6
crank_sync_confirmed:
                INCB 0A3h
                CLRB 0A2h
                SJ crank_tooth_counter_reset_if_ram1b_b0_set
crank_sync_flags_clear_irqh_b7:
                RB IRQH.7
                RB 0B6h.7
                RB 0B7h.2
                MB C, 0B7h.0
                JGE crank_sync_exit_jump
                SB off(028h).4
crank_sync_exit_jump:
                J crank_decode_exit
crank_sync_lost_path_set_ram28_b4:
                SB off(028h).4
                RB off(028h).6
                MOVB off(0D2h), #02Dh
                L A, 0A2h
                CMP A, #00005h
                JEQ crank_tooth_counter_reset
                SB off(025h).7
                JLT irq3_engine_irq_set_ram28_b5
                CMP A, #00105h
                JGE crank_sync_flag_high
                SB 0B5h.0
                SJ crank_tooth_counter_reset
irq3_engine_irq_set_ram28_b5:
                SB off(028h).5
                SJ crank_tooth_counter_reset
crank_sync_flag_high:
                SB 0B5h.1
crank_tooth_counter_reset:
                CLR 0A2h
crank_tooth_counter_reset_if_ram1b_b0_set:
                JBS off(01Bh).0, irq3_engine_irq_clear_ram25_b7
                RB 0B7h.2
                JEQ crank_tooth_seq_check
                RB off(028h).7
                MOVB off(0D3h), #007h
                L A, off(034h)
                CMP A, #00017h
                JNE crank_window_flag_check2
                RB off(028h).5
                JNE crank_window_flag_check2_set_ramb5_b1
                RB off(025h).7
                CMPB 0A2h, #003h
                JEQ crank_tooth_reset
irq3_engine_irq_set_ramb5_b2:
                SB 0B5h.2
                SJ crank_tooth_reset
irq3_engine_irq_clear_ram25_b7:
                RB off(025h).7
crank_tooth_seq_check:
                CMPB off(034h), #017h
                JGE crank_tooth_seq_gate
                INCB off(034h)
                J crank_tooth_mod_check
crank_tooth_seq_gate:
                JBS off(01Bh).0, crank_tooth_seq_advance
                SB 0B4h.2
                SB off(028h).7
crank_tooth_seq_advance:
                INCB off(035h)
                CLRB off(034h)
                SJ crank_tooth_mod_check
crank_window_flag_check2:
                RB off(028h).5
                JGE crank_tooth_reset
                JEQ irq3_engine_irq_set_ramb5_b2
                SB 0B5h.0
                SJ crank_tooth_reset
crank_window_flag_check2_set_ramb5_b1:
                SB 0B5h.1
crank_tooth_reset:
                CLR off(034h)
crank_tooth_mod_check:
                JBS off(01Ah).7, crank_tooth_mod6_calc
                JBS off(028h).6, crank_tooth_mod6_calc
crank_tooth_range_check:
                JBS off(01Bh).0, crank_tooth_wrap_calc
                JBS off(028h).7, crank_tooth_wrap_calc
crank_tooth_carry_rc:
                RC
                JBR off(01Bh).6, crank_sync_flag_ram2a_b1
                SJ crank_sync_confirmed_flag
crank_tooth_mod6_calc:
                CLR A
                MOVB r0, #006h
                LB A, off(034h)
                ADDB A, #003h
                DIVB
                LB A, r1
                STB A, 0A2h
                SJ crank_tooth_range_check
crank_tooth_wrap_calc:
                MOVB r0, #006h
                LB A, 0A2h
                ADDB A, #003h
                SUBB A, r0
                JGE crank_tooth_wrap_store_r2
                ADDB A, r0
crank_tooth_wrap_store_r2:
                STB A, r2
                CLR A
                LB A, off(034h)
                DIVB
                MULB
                ADDB A, r2
                STB A, off(034h)
                JBS off(01Ah).7, crank_sync_confirmed_flag
                JBR off(028h).6, crank_tooth_carry_rc
crank_sync_confirmed_flag:
                SC
                SB off(024h).2
crank_sync_flag_ram2a_b1:
                MB off(02Ah).1, C
                LB A, off(034h)
                EXTND
                MOV X1, A
                LCB A, CrankSyncPattern[X1]
                ANDB off(028h), A
                LB A, off(034h)
                JNE crank_sync_flag2_check
                JBR off(028h).2, irq3_engine_irq_and_pswh
                JBS off(01Fh).7, crank_sync_flag2_check
                JBS off(028h).0, crank_tooth_alt_flag
                RB off(028h).1
                SJ crank_tooth_alt_store_ram3c
irq3_engine_irq_and_pswh:
                ANDB PSWH, #0FEh
                MOVB off(096h), #077h
                MOVB off(016h), #011h
                ANDB off(028h), #0FCh
                ORB PSWH, #001h
                SJ crank_tooth_alt_store_ram3c
crank_tooth_alt_flag:
                LB A, #001h
                JBR off(028h).1, crank_tooth_alt_store_ram3c
                LB A, #002h
crank_tooth_alt_store_ram3c:
                STB A, off(03Ch)
crank_sync_flag2_check:
                JBS off(028h).2, crank_sync_bit_check
                CMPB off(03Dh), #004h
                JEQ crank_cycle_exit_early
                LB A, off(03Dh)
                JNE crank_sync_bit_check
                LB A, 0A2h
                JNE crank_sync_bit_check
                SB off(028h).2
crank_sync_bit_check:
                JBR off(01Fh).7, crank_sync_bit_check_2
                LB A, 0A2h
                JNE crank_cycle_exit_early
                SJ crank_cycle_dispatch2
crank_sync_bit_check_2:
                LB A, off(03Ch)
                ANDB A, #001h
                TBR off(028h)
                JNE crank_cycle_exit_early
                CLR A
                LB A, off(034h)
                JBR off(03Ch).0, crank_tooth_pattern_lookup
                ADDB A, #006h
crank_tooth_pattern_lookup:
                MOV X1, A
                LCB A, CrankToothPattern[X1]
                CMPB A, off(03Bh)
                JGE crank_cycle_dispatch2
crank_cycle_exit_early:
                J crank_decode_exit
crank_cycle_dispatch2:
                LB A, off(03Ch)
                SLLB A
                EXTND
                MOV X1, A
                JBS off(025h).4, injtimer_countdown_check
                CLR A
                MOV X2, A
                ST A, 003C2h[X2]
                ST A, 003C4h[X2]
                ST A, 003C6h[X2]
                ST A, 003C8h[X2]
                CLRB A
                STB A, off(0A5h)
                J injtimer_bit_clear_rama3_b0
injtimer_sbr_rama7:
                SBR off(0A7h)
                SB off(02Ah).7
                SB off(0A3h).0
                SJ injbase_calc_start
injtimer_load_ram4c:
                L A, off(04Ch)
                SJ injtimer_clamp_store_ind
injtimer_countdown_check:
                LB A, off(0A6h)
                SUBB A, #001h
                JGE injtimer_countdown_store_rama6
                LB A, #007h
injtimer_countdown_store_rama6:
                STB A, off(0A6h)
                CMPB A, #007h
                JGT injtimer_bit_clear_rama3_b0
                MBR C, off(0A5h)
                JLT injtimer_sbr_rama7
                ADDB A, #004h
                RBR off(0A7h)
                JNE injtimer_load_ram4c
                L A, 003C2h[X1]
                SUB A, #00000h
                JGE injtimer_clamp_store_ind
                CLR A
injtimer_clamp_store_ind:
                ST A, 003C2h[X1]
injtimer_bit_clear_rama3_b0:
                RB off(0A3h).0
injbase_calc_start:
                CLR A
                JBS off(024h).4, injbase_store_ram9e
                JBS off(02Ah).1, injbase_store_ram9e
                L A, 003BAh[X1]
                ADD A, 003C2h[X1]
                JGE injbase_store_ram9e
                L A, #0FFFFh
injbase_store_ram9e:
                ST A, off(09Eh)
                LB A, off(03Ch)
                ANDB PSWH, #0FEh
                TBR off(017h)
                JNE irq3_engine_irq_load_tmr0
                JBR off(028h).2, tm0_sync_common
                L A, TM0
                SUB A, TMR0
                JEQ tm0_sync_common
                MB C, IRQ.5
                JLT tm0_sync_common
                ADD A, #00005h
                JLT tm0_sync_common
                ADD TMR0, A
tm0_sync_common:
                ORB PSWH, #001h
                CAL vss_rpm_update
                SB off(02Ah).3
                J crank_tooth_flag_update
irq3_engine_irq_load_tmr0:
                L A, TMR0
                SUB A, TM0
                CMP A, #00005h
                JLT irq3_engine_irq_or_pswh
                CMP A, #00020h
                JLT irq3_engine_irq_or_pswh_2
irq3_engine_irq_or_pswh:
                ORB PSWH, #001h
                RB off(02Ah).3
                J crank_tooth_flag_update
irq3_engine_irq_or_pswh_2:
                ORB PSWH, #001h
                CAL vss_rpm_update
                SB off(02Ah).3
crank_tooth_flag_update:
                CAL inj_pulse_engine
                LB A, off(03Ch)
                STB A, r0
                ANDB A, #001h
                SBR off(028h)
                INCB r0
                LB A, r0
                ANDB A, #003h
                STB A, off(03Ch)
                JBS off(01Fh).3, crank_decode_exit
                JBS off(01Bh).7, crank_decode_exit
                RB off(02Ah).0
                JEQ crank_decode_exit
                RB TRNSIT.2
                JNE crank_decode_exit
                SB 0B4h.6
crank_decode_exit:
                RB off(02Ah).3
                JNE crank_decode_final_check
                CAL vss_rpm_update
crank_decode_final_check:
                LB A, 0A2h
                CMPB A, #003h
                JNE crank_cycle_dispatch
crank_cycle_dispatch_body:
                JBS off(026h).0, crank_cycle_period_saturate
                JBS off(01Fh).1, crank_cycle_period_saturate
                CMPB A, #003h
                CLR er2
                JBS off(02Ah).5, crank_cycle_alt_dp
                MOV DP, #00366h
                JEQ crank_cycle_dp_common
                CLR A
                SJ crank_cycle_store_rama4
crank_cycle_alt_dp:
                MOV DP, #00362h
                JNE crank_cycle_dp_common
                MOV er2, [DP]
crank_cycle_dp_common:
                L A, [DP]
                CLR er0
                MOVB r1, 09Fh
                MUL
                L A, er2
                ADD A, er1
                JGE crank_cycle_store_rama4
crank_cycle_period_saturate:
                L A, #0FFFFh
crank_cycle_store_rama4:
                ST A, 0A4h
crank_cycle_entry:
                L A, off(024h)
                ST A, -100[USP]
                ANDB PSWH, #0FEh
int1_rti_epilogue:
                L A, 0F8h
                ST A, IE
                RTI
crank_cycle_dispatch:
                JGE crank_cycle_dispatch_alt
                CMPB A, #001h
                JGE irq3_engine_irq_branch
                JBS off(01Bh).6, crank_cycle_p4_gate
                JBS off(025h).7, crank_cycle_p4_gate
                CMP 0C4h, #000E7h
                JLT crank_cycle_p4_gate
                RB TRNSIT.1
                JNE crank_cycle_p4_gate
                SB 0B4h.3
                SJ crank_cycle_p4_gate_if_ram1f_b2_set
crank_cycle_p4_gate:
                RB 0B4h.3
                MOVB off(0D4h), #006h
crank_cycle_p4_gate_if_ram1f_b2_set:
                JBS off(01Fh).2, irq3_engine_irq_if_ram1f_b7_set
                JBR off(01Fh).7, irq3_engine_irq_if_ram29_b1_clr
                SB P4.0
                J irq3_engine_irq_inc_ram3e
irq3_engine_irq_if_ram29_b1_clr:
                JBR off(029h).1, crank_cycle_load_imm
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                SJ crank_cycle_result_common
crank_cycle_load_imm:
                LB A, #001h
                CMPB 0F4h, #024h
                JNE crank_cycle_counter_check
                SB off(02Ah).4
crank_cycle_counter_check:
                CMPB off(0D2h), #028h
                JLE crank_cycle_result_b
                JBS off(01Fh).4, crank_cycle_result_a
                JBS off(02Ah).4, crank_cycle_result_common
                JBS off(01Ah).5, crank_cycle_result_a
                CMPB 0D9h, #034h
                JLT crank_cycle_result_common
crank_cycle_result_a:
                LB A, #003h
                SJ crank_cycle_result_common
crank_cycle_result_b:
                SB off(028h).4
crank_cycle_result_common:
                SRLB A
                MB off(026h).0, C
                SRLB A
                MB P4.0, C
crank_cycle_bailout:
                J crank_cycle_entry
crank_cycle_dispatch_alt:
                CMPB A, #004h
                JNE crank_cycle_entry
                J crank_cycle_dispatch_body
irq3_engine_irq_branch:
                JEQ crank_cycle_bailout
irq3_engine_irq_if_ram1f_b7_set:
                JBS off(01Fh).7, crank_cycle_bailout
                JBR off(028h).4, crank_cycle_bailout
irq3_engine_irq_inc_ram3e:
                INCB off(03Eh)
                JBS off(02Ah).2, crank_cycle_bailout
                LB A, off(024h)
                ANDB A, #003h
                ANDB off(03Eh), A
                JNE crank_cycle_bailout
                SB off(02Ah).2
                L A, 0F8h
                ST A, IE
                CAL flag_pair
                MOV PSW, #01101h
                MOV LRB, #00040h
                MOV USP, #00180h
                MOV DP, #0037Bh
                MOVB r0, [DP]
                LB A, 0E1h
                STB A, [DP]
                LB A, ADCR2H
                STB A, 0E1h
                SUBB A, r0
                MB off(02Bh).5, C
                JGE crank_cycle_adc_prep
                VCAL 6
crank_cycle_adc_prep:
                STB A, 0E2h
                LB A, P2
                ANDB A, #0E0h
                STB A, off(057h)
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                RB ADSCAN.4
                ANDB P2, #01Fh
                SB ADSCAN.4
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                MOV DP, #00006h
                CLR A
                MOV X1, A
                ST A, er0
                ST A, er1
irq3_engine_irq_load_ind:
                L A, 00360h[X1]
                JBR off(017h).7, irq3_engine_irq_branch_2
                MOV 00360h[X1], #00001h
                SJ irq3_engine_irq_add_er1
irq3_engine_irq_branch_2:
                JEQ rpm_period_invalid
irq3_engine_irq_add_er1:
                ADD er1, A
                ADCB r0, #000h
                INC X1
                INC X1
                JRNZ DP, irq3_engine_irq_load_ind
                RB off(017h).4
                RB off(031h).5
                L A, er1
                MOV er2, #00005h
                DIV
                CMPB r0, #000h
                JEQ rpm_period_avg_store_er0
rpm_period_invalid:
                SB off(031h).5
                L A, #0FFFFh
rpm_period_avg_store_er0:
                ST A, er0
                CLR X1
                XCHG A, 0C4h
                ST A, er1
                XCHG A, 0036Eh[X1]
                XCHG A, 00370h[X1]
                XCHG A, 00372h[X1]
                ST A, er2
                L A, er0
                SUB A, er2
                MB off(01Bh).7, C
                JGE rpm_accel_limit_check
                VCAL 7
rpm_accel_limit_check:
                ST A, 0C8h
                L A, er0
                SUB A, er1
                MB off(01Bh).6, C
                JGE rpm_decel_limit_check
                VCAL 7
rpm_decel_limit_check:
                ST A, 0C6h
                L A, 0C4h
                CMP A, #000EAh
                JLT rpm_period_normalize_lowrange
                CMP A, #00EA6h
                JGE rpm_period_normalize_highrange
                MOV er3, #0FFC0h
                MOV er0, #00007h
                MOV er2, #00753h
                MOV X1, #05300h
irq3_engine_irq_cmp_acc_er2:
                CMP A, er2
                JGE irq3_engine_irq_store_er2
                SRL er0
                ROR X1
                ADD er3, #00040h
                SRL er2
                SJ irq3_engine_irq_cmp_acc_er2
irq3_engine_irq_store_er2:
                ST A, er2
                L A, X1
                DIV
                SRL A
                MB PSWL.4, C
                ADD er3, A
                LB A, r7
                JNE rpm_clamp_0xfe
                LB A, r6
                JEQ rpm_normalize_flag_load_imm
                CMPB A, #0FFh
                JGE rpm_clamp_0xfe
                SJ rpm_calc_finalize
rpm_period_normalize_lowrange:
                CMP A, #000BBh
                LB A, #0FFh
                JLT rpm_period_normalize_done
rpm_clamp_0xfe:
                LB A, #0FEh
rpm_period_normalize_done:
                SB PSWL.4
                SJ rpm_calc_finalize
rpm_period_normalize_highrange:
                CLRB A
                JBS off(017h).4, rpm_normalize_flag_clear_pswl_b4
rpm_normalize_flag_load_imm:
                LB A, #001h
rpm_normalize_flag_clear_pswl_b4:
                RB PSWL.4
rpm_calc_finalize:
                MB C, PSWL.4
                MB 0B8h.4, C
                STB A, -77[USP]
                XCHGB A, off(036h)
                STB A, 0C3h
                CLRB r7
                JBS off(017h).4, irq3_engine_irq_rc
                DECB r7
                MOV er2, 0C4h
                MOV er0, #0D000h
                CLR A
                DIV
                SLL A
                LB A, r1
                RORB A
                SC
                JNE loadindex_flag_load_r7
                SLLB A
                LB A, r0
                JNE loadindex_store_ramc2
                MOVB r7, #001h
irq3_engine_irq_rc:
                RC
loadindex_flag_load_r7:
                LB A, r7
loadindex_store_ramc2:
                STB A, 0C2h
                MB 0B8h.3, C
                JBS off(012h).2, map_sign_flag_clear_ramb0_b0
                L A, 0BAh
                SWAP
                LB A, ACC
                CMPB A, #0A1h
                JGT dtc03_map_latch
                CMPB A, #00Bh
                JGE map_neg_helper_call_mul_shift
dtc03_map_latch:
                SB 0B0h.0
                LB A, off(035h)
                SJ map_sign_gate2
map_neg_helper_call_mul_shift:
                CAL mul_shift
map_sign_flag_clear_ramb0_b0:
                RB 0B0h.0
                JBS off(012h).2, map_sign_gate3
map_sign_gate2:
                JBR off(012h).4, map_sign_gate4
map_sign_gate3:
                LB A, 0D1h
                MOV X1, #0601Eh
                VCAL 1
map_sign_gate4:
                STB A, r0
                LB A, off(035h)
                SUBB A, r0
                RB off(01Bh).4
                MB off(01Bh).4, C
                JEQ irq3_engine_irq_flag_ramed_b6
                XORB PSWH, #080h
irq3_engine_irq_flag_ramed_b6:
                MB off(0EDh).6, C
                JBR off(01Bh).4, map_delta_store_ramc0
                VCAL 6
map_delta_store_ramc0:
                STB A, 0C0h
                MOV DP, #00375h
                LB A, [DP]
                SUBB A, r0
                MB off(01Bh).5, C
                JGE map_delta2_store_ramc1
                VCAL 6
map_delta2_store_ramc1:
                STB A, 0C1h
                LB A, r0
                STB A, -78[USP]
                XCHGB A, off(035h)
                XCHGB A, 0BDh
                DEC DP
                XCHGB A, [DP]
                INC DP
                STB A, [DP]
                LB A, #059h
                JBS off(012h).2, tps_custom_clamp_store_rambe
                JBS off(012h).4, tps_custom_clamp_store_rambe
                LB A, 0BCh
                SUBB A, off(035h)
                JGE tps_custom_clamp_store_rambe
                CLRB A
tps_custom_clamp_store_rambe:
                STB A, 0BEh
                MOV er0, #04D00h
                RC
                JBS off(012h).6, dtc07_tps_latch
                MOV er0, ADCR7
                LB A, #0FCh
                CMPB A, r1
                JLT dtc07_tps_latch
                CMPB r1, #005h
dtc07_tps_latch:
                MB 0B0h.2, C
                JLT tps_delta_alt_path
                L A, er0
                SLL A
                JLT tps_delta_clamp1
                SLL A
                LB A, ACCH
                JGE tps_delta_store1
tps_delta_clamp1:
                LB A, #0FFh
tps_delta_store1:
                STB A, 0D4h
                L A, er0
                XCHG A, 0D0h
                MOV er1, 0D2h
                ST A, 0D2h
                JBR off(012h).6, tps_delta_check1
tps_delta_alt_path:
                L A, er0
                MOV er1, 0D0h
tps_delta_check1:
                SUB A, er0
                MB PSWL.4, C
                JGE tps_delta_clamp2
                VCAL 7
tps_delta_clamp2:
                SLL A
                JLT tps_delta_clamp2_max
                SLL A
                LB A, ACCH
                JGE tps_delta_store2
tps_delta_clamp2_max:
                LB A, #0FFh
tps_delta_store2:
                STB A, r0
                MB C, PSWL.4
                RB off(01Bh).1
                MB off(01Bh).1, C
                XCHGB A, 0D5h
                JEQ tps_delta_sign_check
                XORB PSWH, #080h
tps_delta_sign_check:
                JLT tps_delta_flag_ram1b_b3
                CMPB A, r0
tps_delta_flag_ram1b_b3:
                MB off(01Bh).3, C
                L A, er1
                SUB A, 0D0h
                MB off(01Bh).2, C
                JGE tps_delta_clamp3
                VCAL 7
tps_delta_clamp3:
                SLL A
                JLT tps_delta_clamp3_max
                SLL A
                LB A, ACCH
                JGE tps_delta_store3
tps_delta_clamp3_max:
                LB A, #0FFh
tps_delta_store3:
                STB A, 0D6h
                L A, off(094h)
                ST A, er0
                LB A, r1
                JBR off(01Ah).1, tps_delta_compare_final
                LB A, r0
tps_delta_compare_final:
                CMPB A, off(036h)
                MB off(01Ah).1, C
                LB A, r1
                JBR off(02Bh).0, irq3_engine_irq_add_acc
                LB A, r0
irq3_engine_irq_add_acc:
                ADDB A, #00Dh
                JGE irq3_engine_irq_cmp_acc_ram36
                LB A, #0FFh
irq3_engine_irq_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(02Bh).0, C
                MOV DP, #00311h
                MOVB r4, [DP]
                LB A, #003h
                STB A, r2
                MOVB r3, #006h
                MB C, off(018h).2
                MB off(018h).3, C
                JLT tps_window_calc2
                LB A, r3
tps_window_calc2:
                ADDB A, r4
                CMPB A, 0D4h
                MB off(018h).2, C
                LB A, #004h
                JBS off(018h).4, tps_window_calc3
                LB A, #007h
tps_window_calc3:
                ADDB A, r4
                CMPB A, 0D4h
                MB off(018h).4, C
                LB A, r2
                MB C, off(018h).0
                MB off(018h).1, C
                JGE tps_window_calc4
                MOVB r0, r1
                LB A, r3
tps_window_calc4:
                ADDB A, r4
                CMPB 0D4h, A
                JGE tps_window_store2
                LB A, off(036h)
                CMPB A, r0
tps_window_store2:
                MB off(018h).0, C
                MOVB r1, off(035h)
                JBS off(012h).2, irq3_engine_irq_set_ram9b
                JBS off(012h).4, irq3_engine_irq_set_ram9b
                CMPB 0F3h, #032h
                JGE irq3_engine_irq_cmp_rambd_ram35
irq3_engine_irq_set_ram9b:
                MOVB off(09Bh), r1
                J tps_interp_exact_match
irq3_engine_irq_cmp_rambd_ram35:
                CMPB 0BDh, off(035h)
                JEQ irq3_engine_irq_clear_r0
                JBR off(0EDh).6, irq3_engine_irq_load_ram35
irq3_engine_irq_clear_r0:
                CLRB r0
                LB A, 0BDh
                STB A, off(09Bh)
                SJ irq3_engine_irq_if_ram1c_b0_set
irq3_engine_irq_load_ram35:
                LB A, off(035h)
                SUBB A, off(09Bh)
                MB PSWL.4, C
                JGE irq3_engine_irq_set_r0
                VCAL 6
irq3_engine_irq_set_r0:
                MOVB r0, #090h
                JBS off(01Bh).4, irq3_engine_irq_mul
                MOVB r0, #060h
irq3_engine_irq_mul:
                MULB
                MB C, PSWL.4
                JLT irq3_engine_irq_sub_ram9a
                ADD off(09Ah), A
                SJ irq3_engine_irq_load_ram9b
irq3_engine_irq_sub_ram9a:
                SUB off(09Ah), A
irq3_engine_irq_load_ram9b:
                LB A, off(09Bh)
                SUBB A, off(035h)
                MB off(0EDh).7, C
                JGE irq3_engine_irq_store_r0
                VCAL 6
irq3_engine_irq_store_r0:
                STB A, r0
irq3_engine_irq_if_ram1c_b0_set:
                JBS off(01Ch).0, tps_interp_exact_match
                JBR off(01Ah).1, tps_interp_exact_match
                MOVB r4, #0FFh
                LB A, 0BDh
                MOV DP, #ThrottleFilterLimit
                MOV X1, #ThrottleFilterRate
                CMPB A, #090h
                JGE tps_table_offset_check
                INC DP
                INC DP
                CMPB A, #040h
                JGE tps_table_offset_check
                INC DP
                INC DP
tps_table_offset_check:
                JBS off(0EDh).7, tps_table_lookup
                INC X1
                INC X1
                INC DP
tps_table_lookup:
                LC A, [X1]
                CMPB A, r0
                JLT tps_interp_clamp_check
tps_interp_exact_match:
                LB A, r1
                SJ tps_interp_store_rambf
tps_interp_clamp_check:
                LB A, ACCH
                CMPB A, r0
                JGE tps_interp_weight_calc
                STB A, r0
tps_interp_weight_calc:
                LCB A, [DP]
                MULB
                L A, ACC
                SRL A
                SRL A
                SRL A
                SRL A
                ST A, er1
                LB A, r3
                JNE tps_interp_zero_check
                LB A, r1
                JBR off(0EDh).7, tps_interp_sub_check
                ADDB A, r2
                JLT tps_interp_clamp_result
                SJ tps_interp_range_check
tps_interp_sub_check:
                SUBB A, r2
                JLT tps_interp_zero_check
tps_interp_range_check:
                CMPB A, r4
                JLE tps_interp_store_rambf
tps_interp_clamp_result:
                LB A, r4
                SJ tps_interp_store_rambf
tps_interp_zero_check:
                CLRB A
                JBS off(0EDh).7, tps_interp_clamp_result
tps_interp_store_rambf:
                STB A, 0BFh
                L A, 0C4h
                SUB A, off(05Ah)
                MB off(01Ah).4, C
                MOV er0, #00300h
                JGE irq3_engine_irq_cmp_acc_er0
                VCAL 7
                MOV er0, #00300h
irq3_engine_irq_cmp_acc_er0:
                CMP A, er0
                JLT rpm_avg_range_check_store_ramca
                L A, er0
rpm_avg_range_check_store_ramca:
                ST A, 0CAh
                LB A, #0C2h
                JBS off(018h).5, threshold_bank_cmp_acc_ram36
                LB A, #0C6h
threshold_bank_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(018h).5, C
                LB A, #03Ah
                JBS off(017h).0, rpm_load_axis_scan
                LB A, #040h
; RPM / load axis scan: compares the RPM byte 036h against the rpm axes (0x07C68h 20-row log axis,
; 0x07C7C/0x07C8B 15-row, 0x07C4A/0x07C54/0x07C5E load axes) to find the map row/column for the
; fuel and ignition lookups; 0B8h.4/PSWL.4 flag management.
rpm_load_axis_scan:
                CMPB A, off(036h)
                MB off(017h).0, C
                MOV X1, #RpmScalerLow
                MOVB r3, 103[USP]
                MOVB r2, off(036h)
                MOVB r6, #012h
                MB C, 0B8h.4
                MB PSWL.4, C
                CAL newval_table3_clear_acc
                STB A, 106[USP]
                LB A, r6
                STB A, 103[USP]
                MOV X1, #RpmScalerHigh
                MOVB r3, 104[USP]
                MOVB r2, 0C2h
                MOVB r6, #00Dh
                MB C, 0B8h.3
                MB PSWL.4, C
                CAL newval_table3_clear_acc
                STB A, 108[USP]
                LB A, r6
                STB A, 104[USP]
                MOV X1, #RpmScalerVE
                MOVB r3, 105[USP]
                MOVB r2, 0C2h
                MOVB r6, #00Dh
                MB C, 0B8h.3
                MB PSWL.4, C
                CAL newval_table3_clear_acc
                STB A, 110[USP]
                LB A, r6
                STB A, 105[USP]
                LB A, 0BCh
                JBS off(012h).2, newval_table3_store_r2
                JBS off(012h).4, newval_table3_store_r2
                LB A, 0BFh
newval_table3_store_r2:
                STB A, r2
                MOV X1, #MapScaler
                MOVB r3, 94[USP]
                MOVB r6, #008h
                RB PSWL.4
                CAL newval_table3_clear_acc
                STB A, 96[USP]
                LB A, r6
                STB A, 94[USP]
                LB A, 0BFh
                STB A, r2
                MOV X1, #MapScalerFuel
                MOVB r3, 95[USP]
                MOVB r6, #008h
                RB PSWL.4
                CAL newval_table3_clear_acc
                STB A, 98[USP]
                LB A, r6
                STB A, 95[USP]
                LB A, 0BFh
                STB A, r2
                MOV X1, #MapScalerVE
                MOVB r3, 102[USP]
                MOVB r6, #008h
                RB PSWL.4
                CAL newval_table3_clear_acc
                STB A, 100[USP]
                LB A, r6
                STB A, 102[USP]
                CLR er2
                SC
                JBR off(027h).6, mode_flags_pack4
                LB A, 94[USP]
                ADDB A, #001h
                CMPB 0BFh, #000h
                JNE mode_flags_pack_start
                CLRB A
mode_flags_pack_start:
                MOV er0, off(012h)
                AND er0, #0C3BCh
                JNE mode_flags_pack_alt
                JBR off(014h).5, mode_flags_pack_store_r1
mode_flags_pack_alt:
                LB A, #00Fh
mode_flags_pack_store_r1:
                STB A, r1
                RC
                JBS off(014h).5, mode_flags_pack2
                MB C, off(011h).1
mode_flags_pack2:
                MB off(033h).3, C
                MB C, off(01Ch).2
                MB off(033h).4, C
                SC
                LB A, 36[USP]
                JNE mode_flags_pack3
                NOP
                NOP
                NOP
                NOP
                MB C, off(020h).1
mode_flags_pack3:
                MB off(033h).5, C
                LB A, off(033h)
                MOVB r0, #010h
                MULB
                ORB A, r1
                L A, ACC
                ST A, er2
                MOV er0, #00101h
                MOVB r2, #005h
scale_div32_loop:
                SRL A
                ADCB r0, #000h
                SRL A
                ADCB r1, #000h
                DECB r2
                JNE scale_div32_loop
                SRLB r0
                MB r5.2, C
                SRLB r1
                MB r5.3, C
                LB A, 83[USP]
                CMPB A, #007h
                JLT mode_flags_pack4
                LB A, 91[USP]
                CMPB A, #019h
                JLT mode_flags_pack4
                MB C, off(01Dh).7
mode_flags_pack4:
                MB off(033h).6, C
                L A, er2
                ST A, 0EAh
                MOV DP, #003CAh
                LB A, ADCR0H
                STB A, [DP]
                STB A, 0DAh
                MOV DP, #003D2h
                LB A, ADCR1H
                STB A, [DP]
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                RB ADSCAN.4
                ORB P2, off(057h)
                RB IRQH.4
                SB ADSCAN.4
                MOV off(058h), TM2
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                J ign_dispatch
; Ignition advance, warm path: uses the USP-stashed engine words (94[USP], 96[USP], 103[USP],
; 106[USP] stashed by inj_words_stash) and the ignition correction tables (0x05BA7, 0x05F6B), the 0x034h
; (52) / 0x2Dh (45) constants, then ign_advance_scale.
ign_warm_path:
                MOVB r0, #00Ah
                MOVB r1, #014h
                MOVB r2, 94[USP]
                MOV X2, 96[USP]
                MOVB r3, 103[USP]
                MOV er3, 106[USP]
                J ign_dispatch_warm_set_er2
ign_warm_path_if_ram14_b5_clr:
                JBR off(014h).5, ign_warm_path_if_ram1f_b1_clr
                JBS off(018h).5, ign_warm_path_goto_next
ign_warm_path_if_ram1f_b1_clr:
                JBR off(01Fh).1, ign_warm_path_goto_next
                MOVB r1, #00Fh
                MOVB r3, 104[USP]
                MOV er3, 108[USP]
                J ign_dispatch_warm_set_er2_2
ign_warm_path_goto_next:
                J tipin_decay_check_if_ramee_b3_set
                DB  000h,000h
ign_warm_path_set_r0:
                MOVB r0, A
                LB A, off(045h)
                JEQ ign_warm_path_load_r0
                MULB
                MOVB r0, ACCH
ign_warm_path_load_r0:
                LB A, r0
                SJ ign_cold_path
ignmap_alt_path:
                LB A, 0C2h
                MOV X1, #05ABBh
                JBS off(01Fh).1, ign_warm_path_call_interp_word
                LB A, off(036h)
                MOV X1, #05AE7h
ign_warm_path_call_interp_word:
                CAL interp_word
; Ignition advance, cold path: ECT 0D9h < 0x54 (84) selects the cold-cam tables (0x05F6B base,
; 0x05ABB/0x05AE7 ignition maps via ign_dispatch); 0CAh (ECT word) and 010h.7/018h.0 fault flags gate
; the path.
ign_cold_path:
                STB A, off(046h)
                CLRB A
                CMPB 0D9h, #054h
                JGE idleign_result_store_ram41
                JBR off(018h).0, idleign_result_store_ram41
                JBS off(010h).7, idleign_result_store_ram41
                L A, 0CAh
                MOV X1, #LowIdleIgnitionTbl
                JBS off(01Ah).4, idleign_table_lookup
                MOV X1, #HighIdleIgnitionTbl
idleign_table_lookup:
                CAL interp_table
                MOVB r0, #00Eh
                LB A, r6
                CMPB A, r0
                JLT idleign_vcal6_check
                LB A, r0
idleign_vcal6_check:
                JBR off(01Ah).4, idleign_result_store_ram41
                VCAL 6
idleign_result_store_ram41:
                STB A, off(041h)
                LB A, #01Eh
                JBS off(021h).3, rpm_threshold_cmp_ramc5_acc
                LB A, #00Ch
rpm_threshold_cmp_ramc5_acc:
                CMPB 0C5h, A
                MB off(021h).3, C
                LB A, #001h
                JBS off(021h).4, rpm_threshold_cmp_acc_ram36
                LB A, #002h
rpm_threshold_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(021h).4, C
                CLRB A
                MOV X1, #KnockSteps
                JBS off(021h).2, knockretard_table_gate
                INC X1
                INC X1
                MB C, off(021h).3
knockretard_table_gate:
                JGE knockretard_store_ram40
                L A, off(052h)
                ST A, er3
                LB A, off(035h)
                CAL clamp_table
                JBR off(021h).2, knockretard_store_ram40
                STB A, r5
                LB A, off(036h)
                MOV X1, #05F3Dh
                CAL interp_word
                MOVB r0, r5
                MULB
                SLLB A
                LB A, ACCH
                ROLB A
                MB C, ACC.7
                JGE ign_cold_path_vcal6
                LB A, #07Fh
ign_cold_path_vcal6:
                VCAL 6
knockretard_store_ram40:
                STB A, off(040h)
                LB A, #01Ah
                JBS off(022h).5, rpm_threshold_cmp_acc_ram36_2
                LB A, #027h
rpm_threshold_cmp_acc_ram36_2:
                CMPB A, off(036h)
                MB off(022h).5, C
                CLRB A
                JBR off(027h).7, knockretard2_clamp_store_ram38
                JBS off(013h).1, knockretard2_clamp_store_ram38
                JGE knockretard2_clamp_store_ram38
                CMPB 0D8h, #0A1h
                JGE knockretard2_clamp_store_ram38
                JBS off(01Dh).5, knockretard2_clamp_store_ram38
                JBS off(01Ah).3, knockretard2_clamp_store_ram38
                JBR off(01Ah).2, knockretard2_clamp_store_ram38
                CLR A
                LB A, off(054h)
                MOV er3, A
                LB A, off(035h)
                MOV X1, #KnockRetardLimit
                CAL clamp_table
                LB A, off(038h)
                ADDB A, #001h
                JLT knockretard2_clamp
                CMPB A, r6
                JLT knockretard2_clamp_store_ram38
knockretard2_clamp:
                LB A, r6
knockretard2_clamp_store_ram38:
                STB A, off(038h)
                CLRB A
                RC
                JBS off(033h).6, flags_pack_flag_ram33_b7
                JBS off(012h).3, flags_pack_flag_ram33_b7
                JBS off(013h).0, flags_pack_flag_ram33_b7
                L A, 0ECh
                ST A, er2
                CLR er0
                MOVB r2, #005h
scale_shift_loop:
                SLL A
                ADCB r1, #000h
                SLL A
                ADCB r0, #000h
                DECB r2
                JNE scale_shift_loop
                SLL A
                JGE scale_direction_toggle
                SLL A
                JGE scale_direction_toggle
                L A, er0
                AND A, #00101h
                JNE scale_result_common
scale_direction_toggle:
                XORB PSWH, #080h
scale_result_common:
                LB A, r5
flags_pack_flag_ram33_b7:
                MB off(033h).7, C
                SRLB A
                MB off(032h).7, C
                STB A, r5
                CLRB A
                JBR off(027h).6, knock_store_ram44
                CMPB 0C5h, #00Dh
                JGT knock_store_ram44
                LB A, 0EAh
                ANDB A, #00Fh
                CMPB A, #00Fh
                JEQ ign_cold_path_load_ind
                JBS off(014h).7, ign_cold_path_load_ind
                JBS off(033h).6, flags_pack_sj
                JBS off(033h).7, flags_pack_sj
                LB A, r5
                SJ knock_store_ram44
ign_cold_path_load_ind:
                LB A, 104[USP]
                MOV er0, 108[USP]
                MOV DP, #KnockWindowHigh
                JBS off(01Fh).1, knock_call_interp_scale_b
                LB A, 103[USP]
                MOV er0, 106[USP]
                MOV DP, #KnockWindowLow
knock_call_interp_scale_b:
                CAL interp_scale_b
knock_store_ram44:
                STB A, off(044h)
flags_pack_sj:
                LB A, #0FFh
                JBS off(021h).6, flags_pack_sj_cmp_acc_ram44
                LB A, #0FFh
flags_pack_sj_cmp_acc_ram44:
                CMPB A, off(044h)
                MB off(021h).6, C
                CLRB A
                CMPB 36[USP], #001h
                JNE ign_cold_path_cmp_ind_imm
                MOV X1, #059F0h
                MB C, 0B8h.6
                JGE ign_cold_path_if_ram21_b6_clr
                MOV X1, #05A48h
ign_cold_path_if_ram21_b6_clr:
                JBR off(021h).6, ign_cold_path_load_ram36
                ADD X1, #0002Ch
ign_cold_path_load_ram36:
                LB A, off(036h)
                CAL interp_word
                SJ ign_cold_path_store_ram3b
ign_cold_path_cmp_ind_imm:
                CMPB 36[USP], #003h
                JNE ign_cold_path_store_ram3b
                LB A, #000h
                CMPB 0D9h, #000h
                JGE ign_cold_path_store_ram3b
                LB A, #000h
ign_cold_path_store_ram3b:
                STB A, off(03Bh)
                SJ ign_cold_path_load_imm
ign_cold_path_clear_pswl_b4:
                RB PSWL.4
                CLR A
                ST A, er3
                JBS off(012h).5, ign_cold_path_goto_ign_sum_stage4
                J ign_cold_path_if_ram20_b1_clr
ign_cold_path_goto_ign_sum_stage4:
                J ign_sum_stage4
ign_cold_path_load_ram3d:
                LB A, off(03Dh)
                ADD er3, A
                CLR A
                ST A, er2
                LB A, off(03Ah)
                ADD er2, A
                LB A, off(03Eh)
                ADD er2, A
                MOV er1, er2
                JBR off(040h).7, ign_cold_path_load_ram44
                CLRB A
                SUBB A, off(040h)
                ADD er2, A
ign_cold_path_load_ram44:
                LB A, off(044h)
                ADD er2, A
                L A, er2
                CMP A, er3
                MB PSWL.4, C
                JLT ign_cold_path_load_ram38
                MOV er3, er1
ign_cold_path_load_ram38:
                LB A, off(038h)
                ADD er3, A
                J ign_cold_path_nop
ign_cold_path_store_er3:
                ST A, er3
                JBR off(040h).7, ign_cold_path_load_ram40
                MB C, PSWL.4
                JLT ign_cold_path_goto_next
ign_cold_path_load_ram40:
                LB A, off(040h)
                J ign_cold_path_extnd
ign_cold_path_goto_next:
                J ign_cold_path_load_ram41
                DB  000h,000h,000h,000h,000h,000h
ign_cold_path_load_imm:
                LB A, #0FFh
                JBS off(022h).3, callhelper_table_interp_lookup
                LB A, #0FFh
callhelper_table_interp_lookup:
                CMPB 0BEh, A
                MB off(022h).3, C
                CLRB A
                JLT callhelper_table_interp_lookup_store_ram3d
                CMPB 0D9h, #000h
                JGE callhelper_table_interp_lookup_store_ram3d
                JBS off(01Dh).5, callhelper_table_interp_lookup_store_ram3d
                LB A, off(036h)
                MOV X1, #05FF8h
                CAL interp_word
callhelper_table_interp_lookup_store_ram3d:
                STB A, off(03Dh)
                MOV X1, #05FCBh
                LB A, off(036h)
                CAL interp_word
                CMPB A, 0D3h
                MB off(031h).6, C
                L A, off(012h)
                AND A, #08074h
                JNE tipin_gate_fail
                JBS off(014h).0, tipin_gate_fail
                JBS off(01Dh).4, tipin_gate_fail
                JBS off(016h).3, tipin_gate_fail
                CMPB 0D9h, #034h
                JGE tipin_gate_fail
                LB A, 0CCh
                CMPB A, #00Ah
                JLT tipin_gate_fail
                CMPB A, #08Ch
                JGE tipin_gate_fail
                LB A, off(036h)
                CMPB A, #040h
                JLT tipin_gate_fail
                CMPB A, #0C8h
                JGE tipin_gate_fail
                JBS off(020h).0, tipin_gate_pass
                JBR off(031h).6, tipin_gate2
                LB A, off(037h)
                JNE tipin_decay_check
tipin_gate_fail:
                RB off(020h).0
                RB off(020h).2
                SJ tipin_decay_zero
tipin_gate2:
                JBR off(01Bh).1, tipin_decay_zero
                CMPB 0D5h, #008h
                JLT tipin_decay_zero
tipin_gate_pass:
                SB off(020h).0
                JBS off(01Bh).6, ign_cold_path_load_ram4f
                CMP 0C6h, #0FFFFh
                JGE tipin_decay_zero
ign_cold_path_load_ram4f:
                LB A, off(04Fh)
                EXTND
                LCB A, 05FE6h[ACC]
                MOVB off(04Eh), A
                MOV X1, #05FD9h
                LB A, off(036h)
                CAL interp_word
                MOVB r0, off(050h)
                MULB
                L A, ACC
                SLL A
                JGE tipin_enrich_clamp
                L A, #0FFFFh
tipin_enrich_clamp:
                LB A, ACCH
                RB off(020h).0
tipin_decay_check:
                CMPB off(04Eh), #000h
                JEQ ign_cold_path_if_ram1b_b6_set
                DECB off(04Eh)
                MOVB r0, #002h
                SJ tipin_decay_sub
ign_cold_path_if_ram1b_b6_set:
                JBS off(01Bh).6, ign_cold_path_cmp_ramc6_imm
                CMP 0C6h, #00010h
                JLT ign_cold_path_if_ram20_b2_set
                RB off(020h).2
ign_cold_path_rc:
                RC
                SJ tipin_decay_common_flag_ram20_b3
ign_cold_path_cmp_ramc6_imm:
                CMP 0C6h, #00003h
                JGE ign_cold_path_set_ram20_b2
ign_cold_path_if_ram20_b2_set:
                JBS off(020h).2, ign_cold_path_rc
                SJ ign_cold_path_sc
ign_cold_path_set_ram20_b2:
                SB off(020h).2
ign_cold_path_sc:
                SC
tipin_decay_common_flag_ram20_b3:
                MB off(020h).3, C
                JGE tipin_decay_rc
                MOVB r0, #005h
tipin_decay_sub:
                SUBB A, r0
                JLT tipin_decay_zero
                SC
                SJ tipin_decay_store_ram37
tipin_decay_zero:
                CLRB A
tipin_decay_rc:
                RC
tipin_decay_store_ram37:
                STB A, off(037h)
                MB off(020h).1, C
                LB A, #041h
                JBS off(0EEh).0, ign_cold_path_cmp_acc_ramcc
                LB A, #046h
ign_cold_path_cmp_acc_ramcc:
                CMPB A, 0CCh
                MB off(0EEh).0, C
                LB A, #000h
                JBS off(022h).4, ign_cold_path_cmp_acc_ram44
                LB A, #00Bh
ign_cold_path_cmp_acc_ram44:
                CMPB A, off(044h)
                MB off(022h).4, C
                MOVB r0, #03Fh
                MOVB r1, #003h
                MOVB r2, #02Ah
                MOVB r3, #00Ch
                JGE ign_cold_path_if_ram12_b6_set
                MOVB r0, #03Fh
                MOVB r1, #006h
                MOVB r2, #033h
                MOVB r3, #00Ch
ign_cold_path_if_ram12_b6_set:
                JBS off(012h).6, ign_cold_path_load_r2
                JBS off(01Dh).4, ign_cold_path_load_r2
                CMPB 0D9h, #034h
                JGE ign_cold_path_load_r2
                JBS off(0EEh).0, ign_cold_path_load_r2
                LB A, r0
                CMPB A, off(036h)
                JLT ign_cold_path_load_r2
                JBS off(031h).6, ign_cold_path_load_r2
                CLRB A
                JBR off(01Bh).1, ign_cold_path_store_ram55
                CMPB 0D5h, #010h
                JLT ign_cold_path_store_ram55
                LB A, r1
                ADDB A, #001h
ign_cold_path_store_ram55:
                STB A, off(055h)
ign_cold_path_load_r2:
                LB A, r2
                CMPB off(055h), #000h
                JEQ ign_cold_path_load_ram3e
                DECB off(055h)
                SJ ign_cold_path_store_ram3e
ign_cold_path_load_ram3e:
                LB A, off(03Eh)
                SUBB A, r3
                JGE ign_cold_path_store_ram3e
                CLRB A
ign_cold_path_store_ram3e:
                STB A, off(03Eh)
                LB A, 0C2h
                MOV X1, #05EE9h
                CAL interp_word
                STB A, off(047h)
                LB A, 0C2h
                MOV X1, #05EC5h
                CAL interp_word
                MOV DP, #0035Ah
                STB A, [DP]
                STB A, r0
                LB A, off(04Bh)
                MULB
                L A, ACC
                ST A, er1
                CAL alu_4
                ST A, off(04Ch)
                LB A, #0FFh
                JBS off(021h).5, vss_threshold_cmp_acc_ram36
                LB A, #0FFh
vss_threshold_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(021h).5, C
                L A, er1
                JLT dwell_scale_shift
                SRL A
dwell_scale_shift:
                SRL A
                CAL alu_4
                ST A, off(04Dh)
                MOV DP, #DwellMapHigh
                MOV er0, 108[USP]
                LB A, 104[USP]
                JBS off(01Fh).1, ign_cold_path_if_ram1d_b4_clr
                MOV DP, #DwellMapLow
                MOV er0, 106[USP]
                LB A, 103[USP]
ign_cold_path_if_ram1d_b4_clr:
                JBR off(01Dh).4, ign_cold_path_call_interp_scale_b
                ADD DP, #00014h
ign_cold_path_call_interp_scale_b:
                CAL interp_scale_b
                STB A, off(04Ah)
                J ign_cold_path_clear_pswl_b4
                DB  000h,000h
ign_cold_path_if_ram20_b1_clr:
                JBR off(020h).1, ign_cold_path_goto_next_2
                LB A, 0D1h
                MOV X1, #05FECh
                CAL interp_word
                MOVB r0, off(037h)
                MULB
                L A, ACC
                SLL A
                MOVB r6, ACCH
                CLRB r7
                CLR A
ign_cold_path_goto_next_2:
                J ign_cold_path_load_ram3d
                DB  000h
ign_cold_path_nop:
                NOP
                NOP
                NOP
                NOP
                LB A, off(03Bh)
                ADD er3, A
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
                CMPB 0D9h, #000h
                JGE ign_cold_path_clear_acc
                JBR off(018h).0, ign_cold_path_clear_acc
                LB A, #000h
                ADD er3, A
ign_cold_path_clear_acc:
                CLR A
                SUB A, er3
                J ign_cold_path_store_er3
ign_cold_path_extnd:
                EXTND
                ADD er3, A
ign_cold_path_load_ram41:
                LB A, off(041h)
                EXTND
                ADD er3, A
                LB A, off(042h)
                EXTND
                ADD er3, A
ign_sum_stage4:
                LB A, off(043h)
                EXTND
                J timer_state_reinit_add_er3
ign_cold_path_load_ram44_2:
                LB A, off(044h)
                SUB er3, A
ign_cold_path_clear_acc_2:
                CLR A
                LB A, off(046h)
                STB A, r0
                L A, ACC
                ADD A, er3
                JBR off(007h).7, ign_sum_clamp_check
                JLT ign_sum_result
                CLRB A
                SJ ign_sum_result
ign_sum_clamp_check:
                CMP A, #000FFh
                JLT ign_sum_result
                LB A, #0FFh
ign_sum_result:
                LB A, ACC
                STB A, r4
                LB A, #040h
                JBS off(0ECh).0, ign_cold_path_cmp_acc_ram36
                LB A, #045h
ign_cold_path_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(0ECh).0, C
                LB A, #040h
                SC
                JBS off(012h).5, ign_p40_flag_ram21_b7
                CMPB 0D9h, #0CFh
                JLT ign_p40_flag_ram21_b7
                MB C, P4.0
                JLT ign_p40_store_ram49
                JBS off(021h).7, ign_result_clamp249
                LB A, #000h
                MB C, off(01Eh).0
                JLT ign_p40_store_ram49
                JBS off(0ECh).0, ign_p40_toggle
                LB A, off(049h)
                ADDB A, #002h
                JGE ign_p40_clamp
                LB A, #0FFh
ign_p40_clamp:
                CMPB A, r4
                JGE ign_p40_toggle
                STB A, r4
ign_p40_store_ram49:
                STB A, off(049h)
ign_p40_toggle:
                XORB PSWH, #080h
ign_p40_flag_ram21_b7:
                MB off(021h).7, C
ign_result_clamp249:
                MOVB r3, off(04Ah)
                LB A, r4
                CMPB A, r3
                JGE ign_result_clamp_common
                LB A, r3
ign_result_clamp_common:
                RC
                JBS off(017h).0, ign_flag_ram17_b1
                LB A, ACC
                JNE ign_flag_ram17_b1
                SC
ign_flag_ram17_b1:
                MB off(017h).1, C
                MOV DP, #0035Bh
                JBS off(01Eh).0, ign_result_zero
                JBR off(017h).1, ign_result_add_store_ind
ign_result_zero:
                CLRB A
                STB A, [DP]
                STB A, off(048h)
                SJ gearcorrect_set_r2
ign_result_add_store_ind:
                STB A, [DP]
                ADDB A, off(047h)
                JGE gearcorrect_store_ram48
                LB A, #0FFh
gearcorrect_store_ram48:
                STB A, off(048h)
gearcorrect_set_r2:
                MOVB r2, off(048h)
                MOVB r4, off(04Ch)
                CAL speed_ratio_scale
                MOV DP, #00357h
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                MB 0B8h.0, C
                STB A, [DP]
                INC DP
                L A, er0
                ST A, [DP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                MOVB r4, off(04Dh)
                CAL speed_ratio_scale
                MOV DP, #0035Dh
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                MB 0B8h.1, C
                ST A, [DP]
                INC DP
                L A, er0
                ST A, [DP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                MOV LRB, #00020h
                MOV USP, #00280h
                CAL inj_words_stash
                SC
                JBR off(01Eh).6, igntiming_enable_pin_drive
                JBR off(021h).2, igntiming_enable_pin_drive
                MB C, 0B8h.2
                XORB PSWH, #080h
igntiming_enable_pin_drive:
                MB P1.2, C
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                LB A, P1
                MOV DP, #02F00h
                STB A, [DP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                L A, #01D4Ch
                JBS off(029h).1, vtec_rawperiod_threshold_check
                L A, #00B03h
vtec_rawperiod_threshold_check:
                CMP 0C4h, A
                MB off(029h).1, C
                JBR off(01Eh).5, vtec_state_reset_low_rpm
                LB A, ADCR5H
                STB A, 0D7h
                LB A, #0FFh
                JBS off(026h).2, vtec_rawperiod_threshold_check_cmp_acc_ram32
                LB A, #0FFh
vtec_rawperiod_threshold_check_cmp_acc_ram32:
                CMPB A, off(032h)
                MB off(026h).2, C
                LB A, #0FFh
                JBS off(031h).6, ign_cold_path_cmp_acc_ram33
                LB A, #0FFh
ign_cold_path_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(031h).6, C
                LB A, #0FFh
                JBS off(031h).7, ign_cold_path_cmp_acc_ram32
                LB A, #0FFh
ign_cold_path_cmp_acc_ram32:
                CMPB A, off(032h)
                MB off(031h).7, C
                LB A, #000h
                JBS off(01Fh).5, vtec_state_reset_low_rpm
                JBR off(022h).6, vtec_state_reset_low_rpm
                JBS off(022h).7, vtec_state_reset_low_rpm
                JBR off(026h).2, vtec_state_reset_low_rpm
                JBS off(020h).2, ign_cold_path_if_ram1d_b1_clr
vtec_state_reset_low_rpm:
                MOVB off(0BDh), #000h
                J ign_cold_path_clear_r1
ign_cold_path_if_ram1d_b1_clr:
                JBR off(01Dh).1, ign_cold_path_cmp_ramd7_imm
                J ign_cold_path_test_p4_b6
ign_cold_path_cmp_ramd7_imm:
                CMPB 0D7h, #0FFh
                JGT ign_cold_path_test_p4_b6
                CMPB 0D7h, #000h
                JLT ign_cold_path_test_p4_b6
                STB A, off(0BDh)
                MOVB r1, off(0A4h)
                LB A, off(0A2h)
                JNE vtec_debounce_step_calc
                CLRB r0
                JBR off(031h).6, ign_cold_path_if_ram31_b7_clr
                INCB r0
                INCB r0
ign_cold_path_if_ram31_b7_clr:
                JBR off(031h).7, to_vtec_debounce_clear_r1
                INCB r0
to_vtec_debounce_clear_r1:
                CLRB r1
                CMPB 0D7h, #0FFh
                JLE to_vtec_debounce_load_imm
                LB A, r0
                EXTND
                ADD A, #059D4h
                MOV DP, A
                INCB r1
                LB A, 0D7h
                RB 0B8h.6
                CMPCB A, [DP]
                JLE to_vtec_debounce_load_imm
                SB 0B8h.6
                ADD DP, #00004h
                CMPCB A, [DP]
                JLE to_vtec_debounce_load_imm
                ADD DP, #00004h
                INCB r1
                JBS off(01Ah).3, to_vtec_debounce_load_imm
                JBS off(01Ah).7, to_vtec_debounce_load_imm
to_vtec_debounce_cmp_acc_ind:
                CMPCB A, [DP]
                JLE to_vtec_debounce_load_imm
ign_cold_path_add_dp:
                ADD DP, #00004h
                INCB r1
                CMPB r1, #004h
                JNE ign_cold_path_cmp_r1_imm
                CMPB 0D9h, #000h
                JGE ign_cold_path_add_dp
ign_cold_path_cmp_r1_imm:
                CMPB r1, #007h
                JLT to_vtec_debounce_cmp_acc_ind
to_vtec_debounce_load_imm:
                LB A, #000h
                SJ vtec_debounce_store_rama2
vtec_debounce_step_calc:
                SUBB A, #001h
                JBR off(024h).0, vtec_debounce_store_rama2
                SUBB A, #001h
                JLT vtec_debounce_zero
                JBR off(024h).1, vtec_debounce_store_rama2
                SUBB A, #002h
                JGE vtec_debounce_store_rama2
vtec_debounce_zero:
                CLRB A
vtec_debounce_store_rama2:
                STB A, off(0A2h)
                SJ vtec_rpm_valid_check
ign_cold_path_test_p4_b6:
                MB C, P4.6
                JGE ign_cold_path_load_rambd
                STB A, off(0BDh)
ign_cold_path_set_rambe:
                MOVB off(0BEh), #000h
                MOVB r1, #004h
                SJ vtec_rpm_valid_check
ign_cold_path_load_rambd:
                LB A, off(0BDh)
                JNE ign_cold_path_set_rambe
                LB A, off(0BEh)
                JEQ ign_cold_path_clear_r1
                MOVB r1, #002h
vtec_rpm_valid_check:
                CMPB off(033h), #0FFh
                JLT vtec_state_hold_check
                LB A, r1
                CMPB A, #001h
                JLE vtec_state_active_check
                MOVB off(0CFh), #000h
                SJ vtec_state_load_r1
vtec_state_hold_check:
                JBS off(025h).4, vtec_state_confirm
                SJ ign_cold_path_clear_r1
vtec_state_active_check:
                JBR off(025h).4, vtec_state_finalize
vtec_state_confirm:
                LB A, off(0CFh)
                JEQ vtec_state_finalize
                MOVB r1, #002h
                CLRB off(0A2h)
vtec_state_load_r1:
                LB A, r1
                STB A, off(0A4h)
                SB off(025h).4
                JNE vtec_retard_timer_check
                MOVB off(0A6h), #00Ch
                CLRB off(0A5h)
vtec_retard_timer_check:
                CMPB off(0A6h), #008h
                JGT vtec_retard_lookup_done
                CLR A
                LB A, r1
                SUBB A, #002h
                MOV DP, #VTECTransition
                ADD DP, A
                LCB A, [DP]
                STB A, off(0A5h)
vtec_retard_lookup_done:
                SJ ign_cold_path_if_ram1e_b4_clr
ign_cold_path_clear_r1:
                CLRB r1
vtec_state_finalize:
                RB off(025h).4
                CLRB A
                STB A, off(0A2h)
                CMPB r1, #001h
                JNE vtec_state_store2
                LB A, r1
vtec_state_store2:
                STB A, off(0A4h)
ign_cold_path_if_ram1e_b4_clr:
                JBR off(01Eh).4, vtec_disengage_output
                LB A, #00Ah
                MOVB r0, #00Ah
                JBS off(031h).0, vtec_state_store2_if_ram1e_b3_set
                LB A, #00Fh
                MOVB r0, #00Fh
vtec_state_store2_if_ram1e_b3_set:
                JBS off(01Eh).3, vtec_state_store2_cmp_acc_ramcc
                LB A, r0
vtec_state_store2_cmp_acc_ramcc:
                CMPB A, 0CCh
                MB off(031h).0, C
                J timer_state_reinit_load_imm_2
ign_cold_path_nop_2:
                NOP
                NOP
                JBS off(01Eh).3, vtec_rpm_vs_settings_check
                MOV DP, #VTECRpmLoadAuto
                LB A, r0
                NOP
vtec_rpm_vs_settings_check:
                CMPB A, off(033h)
                MB off(031h).1, C
                LC A, [DP]
                JBS off(031h).2, vtec_rpm_vs_settings_check_cmp_acc_ram33
                LB A, ACCH
vtec_rpm_vs_settings_check_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(031h).2, C
                L A, off(01Ah)
                AND A, #0C0BCh
                JNE vtec_disengage_output
                LB A, off(01Ch)
                ANDB A, #031h
                JEQ vtec_engage_conditions_start
vtec_disengage_output:
                RB P1.1
                SJ vtec_highcam_output
vtec_engage_conditions_start:
                SB P1.1
                CMPB 0F3h, #032h
                JLT vtec_highcam_output
                CMPB 0D9h, #044h
                JGE vtec_highcam_output
                LCB A, OptionVtecCoolantGate
                JNE vtec_engage_conditions_start_if_ram1e_b3_clr
                JBR off(031h).0, vtec_highcam_output
vtec_engage_conditions_start_if_ram1e_b3_clr:
                JBR off(01Eh).3, vtec_engage_conditions_start_if_ram31_b1_set
                JBS off(019h).5, vtec_engage_conditions_start_if_ram27_b1_set
vtec_engage_conditions_start_if_ram31_b1_set:
                JBS off(031h).1, ign_cold_path_goto_next_3
vtec_engage_conditions_start_if_ram27_b1_set:
                JBS off(027h).1, vtec_engage_conditions_start_clear_ramba
vtec_highcam_output:
                RB P1.0
                RB off(027h).2
                SJ vtec_highcam_output_set_ramcd
ign_cold_path_goto_next_3:
                J timer_state_reinit_if_ram31_b2_set
ign_cold_path_load_ramba:
                LB A, off(0BAh)
                JNE vtec_engage_conditions_start_set_p1_b0
vtec_engage_conditions_start_clear_ramba:
                CLRB off(0BAh)
                RB P1.0
                RB off(027h).2
                JBS off(019h).1, vtec_engage_conditions_start_load_ramcd
vtec_engage_conditions_start_load_ramce:
                LB A, off(0CEh)
                JNE vtec_engage_conditions_start_set_ram27_b1
vtec_highcam_output_set_ramcd:
                MOVB off(0CDh), #00Ah
vtec_highcam_output_clear_ram27_b1:
                RB off(027h).1
                SJ fuel_map_lookup_a
vtec_engage_conditions_start_set_ramba:
                MOVB off(0BAh), #014h
vtec_engage_conditions_start_set_p1_b0:
                SB P1.0
                SB off(027h).2
                JBR off(019h).1, vtec_engage_conditions_start_load_ramce
vtec_engage_conditions_start_load_ramcd:
                LB A, off(0CDh)
                JNE vtec_highcam_output_clear_ram27_b1
                MOVB off(0CEh), #00Ah
vtec_engage_conditions_start_set_ram27_b1:
                SB off(027h).1
; Fuel map lookup A: the 0x07D6C map (15x10, honda_fuel formula) via the interp helpers, 0x05465h
; constants, result scaled into the fuel pulse-width words.
fuel_map_lookup_a:
                MOVB r0, #00Ah
                MOVB r1, #00Fh
                MOVB r2, off(0DFh)
                MOV X2, off(0E2h)
                MOVB r3, off(0E8h)
                MOV er3, off(0ECh)
                MOV X1, #FuelHigh
                JBR off(01Ch).5, fuel_map_lookup_b
                JBS off(020h).5, fuel_base_lookup_done
; Fuel map lookup B: the 0x07C9A map (20x10, honda_fuel formula) via the interp helpers, 0x05465h
; constants; the second fuel map (selected by engine state).
fuel_map_lookup_b:
                JBS off(027h).1, fuel_base_lookup_done
                MOVB r1, #014h
                MOVB r3, off(0E7h)
                MOV er3, off(0EAh)
                MOV X1, #FuelLow
fuel_base_lookup_done:
                SB PSWL.5
                CAL table2d_lookup_interp
                LCB A, IdleControlScale
                MOV A, er2
                JEQ fuel_map_lookup_b_store_ram40
                CAL state_03F
fuel_map_lookup_b_store_ram40:
                ST A, off(040h)
                LB A, off(080h)
                JBS off(01Fh).5, accel_iac_calc
                JBS off(02Ch).4, fuel_timer_scale
                SJ accel_iac_clamp_min
accel_iac_calc:
                LB A, off(069h)
                STB A, r0
                LB A, off(0F4h)
                MULB
                LB A, ACCH
                CMPB A, #040h
                JGE accel_iac_store_ram80
accel_iac_clamp_min:
                LB A, #040h
accel_iac_store_ram80:
                STB A, off(080h)
fuel_timer_scale:
                MOVB r0, off(081h)
                MULB
                MOVB r1, off(07Fh)
                CLRB r0
                MUL
                MOV er0, er1
                L A, off(05Ch)
                MUL
                MOV off(082h), er1
                J timer_state_reinit_set_x1
fuel_map_lookup_b_load_ram33:
                LB A, off(033h)
                CAL interp_word
                SUBB A, off(090h)
                JGE fuel_map_lookup_b_cmp_acc_ram32
                CLRB A
fuel_map_lookup_b_cmp_acc_ram32:
                CMPB A, off(032h)
                MB off(030h).5, C
                JBR off(024h).2, fuel_map_lookup_b_flag_ram2e_b0
                J timer_state_reinit_set_x1_2
fuel_map_lookup_b_load_ram33_2:
                LB A, off(033h)
                CAL interp_word
                SUBB A, off(090h)
                JGE fuel_map_lookup_b_cmp_acc_ram32_2
                CLRB A
fuel_map_lookup_b_cmp_acc_ram32_2:
                CMPB A, off(032h)
fuel_map_lookup_b_flag_ram2e_b0:
                MB off(02Eh).0, C
                LB A, #003h
                JBS off(0F8h).0, fuel_map_lookup_b_cmp_acc_ramcc
                LB A, #005h
fuel_map_lookup_b_cmp_acc_ramcc:
                CMPB A, 0CCh
                MB off(0F8h).0, C
                CMPB off(033h), #0A0h
                RB PSWH.7
                MOVB r0, 0D6h
                MB C, off(023h).2
                JEQ accelenrich_rpm_mode_check
                MOVB r0, 0D5h
                MB C, off(023h).1
accelenrich_rpm_mode_check:
                JLT accelenrich_flags_clear_ram2c_b1
                MOVB r2, #008h
                MOVB r3, #00Ah
                JBR off(0F8h).0, fuel_map_lookup_b_load_r2
                LB A, off(0C1h)
                JEQ fuel_map_lookup_b_load_r2
                MOVB r2, #020h
                MOVB r3, #020h
fuel_map_lookup_b_load_r2:
                LB A, r2
                CMPB A, r0
                MB off(02Ch).1, C
                LB A, r3
                CMPB A, r0
                MB off(02Ch).2, C
                RC
                SJ fuel_map_lookup_b_goto_next
accelenrich_flags_clear_ram2c_b1:
                RB off(02Ch).1
                RB off(02Ch).2
                LB A, #004h
                CMPB A, r0
fuel_map_lookup_b_goto_next:
                J timer_state_reinit_flag_ram2c_b0
fuel_map_lookup_b_if_ram25_b4_set:
                JBS off(025h).4, accelenrich_jump_cranking_path
                JBS off(019h).0, accelenrich_jump_cranking_path
                JBR off(02Ch).0, accelenrich_if_ram2c_b2_clr
                JBR off(023h).3, accelenrich_jump_tipin_check
                LB A, off(088h)
                JBS off(02Ch).3, accelenrich_table_lookup
                CMPB 0BDh, #0F2h
                JGE accelenrich_jump_cranking_path
                CMPB 0D3h, #0B0h
                JLT accelenrich_base_calc
accelenrich_jump_cranking_path:
                J accelenrich_clear_acc
accelenrich_jump_tipin_check:
                J accelenrich_jump_tipin_check_if_ram20_b2_clr
accelenrich_base_calc:
                CLRB A
                JBR off(020h).1, accelenrich_base_adjust
                CMPB 0CCh, #005h
                JLT accelenrich_result_store_ram88
accelenrich_base_adjust:
                ADDB A, #06Ch
                JBR off(02Eh).4, fuel_map_lookup_b_goto_next_2
                ADDB A, #00Ch
fuel_map_lookup_b_goto_next_2:
                J ign_dispatch_warm_cmp_ram33_imm
                DB  000h
fuel_map_lookup_b_branch:
                JGE accelenrich_result_store_ram88
                SUBB A, #018h
                CMPB off(033h), #0A0h
                JGE accelenrich_result_store_ram88
                SUBB A, #018h
                CMPB off(033h), #074h
                JGE accelenrich_result_store_ram88
                SUBB A, #018h
accelenrich_result_store_ram88:
                STB A, off(088h)
accelenrich_table_lookup:
                CLRB ACCH
                MOV X1, A
                ADD X1, #06648h
                LB A, r0
                VCAL 0
                MOV er0, off(082h)
                MUL
                SRL er1
                RORB A
                SRL er1
                RORB A
                LB A, r2
                L A, ACC
                SWAP
                J ign_dispatch_warm_cmp_acc_ram42
fuel_map_lookup_b_branch_2:
                JEQ fuel_map_lookup_b_set_ramc1
                L A, #0FFFFh
fuel_map_lookup_b_set_ramc1:
                MOVB off(0C1h), #00Ah
                J cranking_flag_check
accelenrich_if_ram2c_b2_clr:
                JBR off(02Ch).2, tipin_rpm_gate
                CLR off(042h)
tipin_rpm_gate:
                CMPB off(033h), #07Ah
                JLT accelenrich_jump_tipin_check_if_ram20_b2_clr
                JBR off(02Ch).1, tipin_gate_common
                JBR off(023h).3, tipin_gate_common
                CMPB off(0C1h), #000h
                JEQ fuel_map_lookup_b_set_x1
                MOV X1, #057DFh
                SJ tipin_table_lookup
fuel_map_lookup_b_set_x1:
                MOV X1, #057D3h
                CMPB -49[USP], #003h
                JGE tipin_table_gear_adjust
                ADD X1, #00006h
tipin_table_gear_adjust:
                CMPB off(033h), #08Dh
                JGE tipin_table_lookup
                SUB X1, #0000Ch
tipin_table_lookup:
                LB A, r0
                VCAL 2
                LB A, ACC
                SJ accelenrich_store_ram65
tipin_gate_common:
                LB A, off(065h)
                JEQ accelenrich_jump_tipin_check_if_ram20_b2_clr
                ADDB A, #002h
                JGE accelenrich_store_ram65
accelenrich_jump_tipin_check_if_ram20_b2_clr:
                JBR off(020h).2, accelenrich_clear_acc
                L A, off(042h)
                JEQ accelenrich_clear_acc
                ST A, er3
                LB A, off(088h)
                EXTND
                MOV DP, #TipInEnrich
                ADD DP, A
                LC A, [DP]
                ST A, er2
                CMP A, er3
                LC A, 00004h[DP]
                JLT tipin_table_result_alt
                LC A, 00002h[DP]
                ST A, er2
                CMP A, er3
                JLT tipin_table_row2
                MOV er0, off(086h)
                LC A, 00008h[DP]
                MUL
                LB A, r2
                L A, ACC
                SWAP
                CMPB r3, #000h
                JEQ fuel_map_lookup_b_xchg_acc
                L A, #0FFFFh
fuel_map_lookup_b_xchg_acc:
                XCHG A, er3
                SUB A, er3
                SJ tipin_table_final
tipin_table_row2:
                MOV er0, off(084h)
                LC A, 00006h[DP]
                MUL
                LB A, r2
                L A, ACC
                SWAP
                CMPB r3, #000h
                JEQ tipin_table_result_alt
                L A, #0FFFFh
tipin_table_result_alt:
                XCHG A, er3
                SUB A, er3
                JLT tipin_table_result_common
                CMP A, er2
                JGE tipin_table_final
tipin_table_result_common:
                L A, er2
                RC
tipin_table_final:
                JGE cranking_flag_check
accelenrich_clear_acc:
                CLRB A
accelenrich_store_ram65:
                STB A, off(065h)
fuel_map_lookup_b_clear_ram2c_b3:
                RB off(02Ch).3
                CLR A
                SJ fuel_map_lookup_b_store_ram42
cranking_flag_check:
                CLRB off(065h)
                J timer_state_reinit_if_ram30_b5_set
fuel_map_lookup_b_set_ram2c_b3:
                SB off(02Ch).3
fuel_map_lookup_b_store_ram42:
                ST A, off(042h)
                JBS off(01Fh).5, Cranking
                J notcranking_entry
Cranking:
                MOV X1, #05861h
                LB A, 0D9h
                VCAL 0
                STB A, off(040h)
                MOV X1, #0587Ch
                LB A, 0C5h
                VCAL 1
                STB A, off(062h)
                MOV X1, #05880h
                LB A, 0BCh
                VCAL 1
                STB A, off(063h)
                MOVB r0, off(062h)
                MULB
                MOV er0, off(040h)
                MUL
                L A, ACC
                SLL A
                ROL er1
                JLT crankfuel_clamp_max
                SLL A
                L A, er1
                ROL A
                JLT crankfuel_clamp_max
                ADD A, off(042h)
                JGE crankfuel_halve_check
crankfuel_clamp_max:
                L A, #0FFFFh
crankfuel_halve_check:
                MB C, 0B7h.0
                JGE crankfuel_halve_check_add_acc
                SRL A
                SRL A
crankfuel_halve_check_add_acc:
                ADD A, off(044h)
                JGE fuel_map_lookup_b_if_ram2a_b1_clr
                L A, #0FFFFh
fuel_map_lookup_b_if_ram2a_b1_clr:
                JBR off(02Ah).1, fuel_map_lookup_b_set_dp
                CLR A
fuel_map_lookup_b_set_dp:
                MOV DP, #003A6h
                ST A, [DP]
                MOV DP, #003B8h
                ST A, [DP]
                CLR X1
                CAL mul_shift_b
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                ST A, 003BAh[X1]
                ST A, 003BCh[X1]
                ST A, 003BEh[X1]
                ST A, 003C0h[X1]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                MB C, 0B7h.0
                JLT crankfuel_output_apply_start
                CMPB off(03Dh), #004h
                JNE postfuel_calc_start
                CMPB 0D9h, #0ECh
                JGE postfuel_calc_start
crankfuel_output_apply_start:
                L A, 003BAh[X1]
                ST A, off(09Eh)
                ST A, off(09Ch)
                ST A, off(09Ah)
                ST A, off(098h)
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                L A, TM0
                SUB A, TMR0
                MB C, IRQ.5
                JLT crankfuel_timer_sync_done
                ADD A, #00005h
                JLT crankfuel_timer_sync_done
                ADD TMR0, A
crankfuel_timer_sync_done:
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                MOV DP, #00010h
crankfuel_timer_wait_loop:
                L A, off(09Eh)
                JRNZ DP, crankfuel_timer_wait_loop
                CAL inj_pulse_engine_b
                JBS off(01Fh).3, cylinder_index_advance
                JBS off(01Bh).7, cylinder_index_advance
                MULB
                RB off(02Ah).0
                JEQ cylinder_index_advance
                RB TRNSIT.2
                JNE cylinder_index_advance
                SB 0B4h.6
cylinder_index_advance:
                LB A, off(03Ch)
                ADDB A, #001h
                ANDB A, #003h
                STB A, off(03Ch)
postfuel_calc_start:
                SB off(02Ch).4
                LB A, 0D9h
                CMPB A, #0CFh
                MB PSWL.5, C
                MOV X1, #0557Fh
                VCAL 0
                STB A, r0
                STB A, r1
                JBS off(01Ah).5, postfuel_scale_apply
                JBS off(01Bh).1, postfuel_scale_apply
                CMPB 0D9h, #0C5h
                JLT postfuel_scale_apply
                MOV DP, #0031Ah
                LB A, [DP]
                SUBB A, 0D9h
                JGE postfuel_ect_rate_check
                VCAL 6
postfuel_ect_rate_check:
                CMPB A, #00Ah
                JGE postfuel_scale_apply
                LB A, 0D8h
                CMPB A, #0C5h
                JLT postfuel_scale_apply
                SUBB A, 0D9h
                JLT postfuel_scale_apply
                CMPB A, #005h
                JLT postfuel_scale_apply
                L A, #0E666h
                MUL
postfuel_scale_apply:
                L A, er1
                ST A, off(070h)
                CLRB off(06Fh)
                MOV er2, #02000h
                SUB A, er2
                ST A, er3
                CLRB r0
                MOVB r1, #070h
                MB C, PSWL.5
                JLT postfuel_hyst_upper_calc
                MOVB r1, #04Dh
postfuel_hyst_upper_calc:
                MUL
                L A, er1
                ADD A, er2
                ST A, off(072h)
                L A, er3
                MOVB r1, #040h
                MB C, PSWL.5
                JLT postfuel_hyst_lower_calc
                MOVB r1, #033h
postfuel_hyst_lower_calc:
                MUL
                L A, er1
                ADD A, er2
                ST A, off(074h)
                CMPB 0D8h, #030h
                MB off(02Bh).3, C
                LB A, off(069h)
                SUBB A, off(06Dh)
                JGE fuel_map_lookup_b_store_ram6e
                CLRB A
fuel_map_lookup_b_store_ram6e:
                STB A, off(06Eh)
                J corr_map_lookup_load_imm_2
notcranking_entry:
                RB 0B7h.0
                JEQ postfuel_decay_table_select
                CLRB off(03Dh)
postfuel_decay_table_select:
                JBR off(02Ch).4, fuel_map_lookup_b_load_imm
                MOV DP, #PostFuelDecay
                JBR off(01Eh).3, postfuel_decay_table_index_adjust
                MOV DP, #PostFuelDecay2
                JBS off(019h).5, postfuel_decay_table_index_adjust
                MOV DP, #PostFuelDecay3
postfuel_decay_table_index_adjust:
                CMPB off(071h), #02Bh
                JLE postfuel_decay_table_index_adjust2
                CMP off(070h), off(072h)
                JGT postfuel_decay_apply
postfuel_decay_table_index_adjust2:
                INC DP
                INC DP
                CMP off(070h), off(074h)
                JGT postfuel_decay_apply
                INC DP
                INC DP
                CMPB 0D8h, #030h
                JGE postfuel_decay_apply
                INC DP
                INC DP
postfuel_decay_apply:
                LC A, [DP]
                SUBB off(06Fh), A
                CLRB A
                L A, ACC
                SWAP
                ST A, er0
                L A, off(070h)
                SBC A, er0
                CMP A, #02000h
                JLE postfuel_decay_zero_reset
                ST A, off(070h)
                CMPB 0D9h, #02Eh
                JLT postfuel_final_store_ram5a
                JBR off(019h).2, postfuel_final_store_ram5a
                CLRB r0
                MOVB r1, #08Dh
                MUL
                SLL A
                L A, er1
                ROL A
                JGE postfuel_final_store_ram5a
                L A, #0FFFFh
                SJ postfuel_final_store_ram5a
postfuel_decay_zero_reset:
                RB off(02Ch).4
                L A, #02000h
                ST A, off(070h)
postfuel_final_store_ram5a:
                ST A, off(05Ah)
fuel_map_lookup_b_load_imm:
                LB A, #0BAh
                JBS off(02Fh).0, postfuel_final_cmp_acc_ram33
                LB A, #0C0h
postfuel_final_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(02Fh).0, C
                LB A, #0DAh
                JBS off(02Fh).5, to_flag_cmp_acc_ram33
                LB A, #0DDh
to_flag_cmp_acc_ram33:
                CMPB A, off(033h)
                J ign_dispatch_warm_flag_ram2f_b5
fuel_map_lookup_b_load_imm_2:
                LB A, #017h
                JBS off(02Fh).1, to_flag_cmp_ramd9_acc
                LB A, #014h
to_flag_cmp_ramd9_acc:
                CMPB 0D9h, A
                MB off(02Fh).1, C
                LB A, off(033h)
                MOV X1, #05632h
                JBS off(02Fh).6, fuel_map_lookup_b_call_interp_word
                MOV X1, #0563Eh
fuel_map_lookup_b_call_interp_word:
                CAL interp_word
                CMPB A, 0D1h
                MB off(02Fh).6, C
                J timer_state_reinit_load_imm
                DB  000h,000h
fuel_map_lookup_b_cmp_acc_ind:
                CMPCB A, 0000Ch[X1]
                MB off(02Fh).3, C
                CAL interp_word
                CLRB r0
                JBS off(02Fh).3, ve_adjust_sub
                MOVB r0, #025h
                JBS off(02Fh).1, ve_adjust_sub
                MOVB r0, #025h
                JBS off(020h).7, ve_adjust_add
                CLRB r0
ve_adjust_add:
                ADDB r0, off(07Eh)
                JLT ve_adjust_clamp_zero
ve_adjust_sub:
                SUBB A, r0
                JGE fuel_map_lookup_b_set_r0
ve_adjust_clamp_zero:
                CLRB A
fuel_map_lookup_b_set_r0:
                MOVB r0, #008h
                JBR off(030h).0, ve_result_flag_cmp_acc_ram32
                SUBB A, r0
                JGE ve_result_flag_cmp_acc_ram32
                CLRB A
ve_result_flag_cmp_acc_ram32:
                CMPB A, off(032h)
                MB off(030h).0, C
                SJ corr_map_lookup
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
; Correction map lookup: the 0x07F6A map (15x7) via the interp helpers, 0x0564A/0x05656h tables;
; called from sensor_fault_check - the sensor/correction compensation map.
corr_map_lookup:
                MOVB r0, #00Ah
                MOVB r1, #00Fh
                MOVB r2, off(0E6h)
                MOV X2, off(0E4h)
                MOVB r3, off(0E9h)
                MOV er3, off(0EEh)
                MOV X1, #VEHigh
                RB PSWL.5
                CAL table2d_lookup_interp
                LB A, r4
                STB A, r0
                JBS off(025h).4, corr_map_lookup_set_ramb7
                JBS off(01Ah).6, ve_accel_gate1
                JBS off(02Fh).6, ve_accel_tps_threshold_check
ve_accel_gate1:
                JBS off(02Fh).3, ve_accel_gate1_if_ram30_b0_clr
                JBS off(02Fh).1, ve_accel_gate1_if_ram30_b0_clr
                JBS off(020h).7, ve_accel_gate1_if_ram30_b0_clr
                JBS off(030h).0, corr_map_lookup_cmp_ramcc_imm
corr_map_lookup_set_ramb7:
                MOVB off(0B7h), #009h
                SJ corr_map_lookup_goto_next
ve_accel_gate1_if_ram30_b0_clr:
                JBR off(030h).0, corr_map_lookup_clear_acc
                JBS off(029h).3, ve_accel_check_tps_rate
corr_map_lookup_clear_acc:
                CLRB A
                SJ corr_map_lookup_store_ramb7
corr_map_lookup_cmp_ramcc_imm:
                CMPB 0CCh, #005h
                JLT ve_accel_tps_threshold_check
                LB A, off(0B7h)
                JEQ ve_accel_tps_threshold_check
                SJ corr_map_lookup_goto_next
corr_map_lookup_store_ramb7:
                STB A, off(0B7h)
corr_map_lookup_goto_next:
                J ign_dispatch_warm_set_ramc5
corr_map_lookup_clear_ram2f_b4:
                RB off(02Fh).4
ve_accel_common:
                RB off(02Fh).7
                LB A, #080h
                SJ tpsaccel_result_common_store_ram62
ve_accel_check_tps_rate:
                JBS off(021h).5, ve_accel_next_stage
ve_accel_tps_threshold_check:
                J timer_state_reinit_load_r0
corr_map_lookup_branch:
                JGE ve_accel_next_stage
                SB off(025h).5
                CLRB off(0B7h)
                SJ ve_accel_common
ve_accel_next_stage:
                MOVB r0, off(07Dh)
                MULB
                SLLB A
                LB A, ACCH
                ROLB A
                JGE corr_map_lookup_store_r2
                LB A, #0FFh
corr_map_lookup_store_r2:
                STB A, r2
                LB A, -60[USP]
                CMPB A, #017h
                JBS off(02Fh).4, tpsaccel_hyst_check
                JLT tpsaccel_hyst_check
                SB off(02Fh).4
                SJ tpsaccel_table_select
tpsaccel_hyst_check:
                CMPB A, #015h
                JGE tpsaccel_table_select
                LB A, r2
                RB off(02Fh).4
                SJ tpsaccel_clamp_0xa0
tpsaccel_table_select:
                LB A, off(033h)
                MOV X1, #0564Ah
                JBR off(027h).1, corr_map_lookup_call_interp_word
                LB A, 0C2h
                MOV X1, #05656h
corr_map_lookup_call_interp_word:
                CAL interp_word
                MOVB r0, r2
                MULB
                SLLB A
                LB A, ACCH
                ROLB A
                JGE tpsaccel_clamp_0xa0
                LB A, #0FFh
tpsaccel_clamp_0xa0:
                MOVB r0, #0A0h
                CMPB A, r0
                JLT corr_map_lookup_goto_next_2
                LB A, r0
corr_map_lookup_goto_next_2:
                J ign_dispatch_warm_if_ram30_b1_clr
                DB  000h
corr_map_lookup_branch_2:
                JNE tpsaccel_result_common
                JBR off(02Fh).5, tpsaccel_result_common
corr_map_lookup_if_ram2c_b4_set:
                JBS off(02Ch).4, tpsaccel_result_common
                MOVB r0, #0A7h
                CMPB A, r0
                JGE tpsaccel_result_common
                LB A, r0
tpsaccel_result_common:
                SB off(025h).5
                SB off(02Fh).7
                CLRB off(0B7h)
tpsaccel_result_common_store_ram62:
                STB A, off(062h)
                JBS off(02Fh).5, corr_map_lookup_test_ram24_b4
                CLRB A
                CMPB 0D9h, #03Bh
                JGE corr_map_lookup_store_ramb0
                LB A, #036h
corr_map_lookup_store_ramb0:
                STB A, off(0B0h)
corr_map_lookup_test_ram24_b4:
                MB C, off(024h).4
                MB off(02Eh).4, C
                LB A, off(08Fh)
                MOVB r0, #05Ah
                MOVB r1, #073h
                JBR off(024h).2, corr_map_lookup_if_ram23_b0_clr
                LB A, off(08Eh)
                MOVB r0, #04Dh
                MOVB r1, #060h
corr_map_lookup_if_ram23_b0_clr:
                JBR off(023h).0, tps_hysteresis_check
                CMPB 0D8h, #030h
                JGE corr_map_lookup_cmp_acc_r0
                MOVB r0, r1
corr_map_lookup_cmp_acc_r0:
                CMPB A, r0
                JGE tps_hysteresis_check
                LB A, r0
tps_hysteresis_check:
                JBR off(01Fh).6, rpm_threshold_adjust
                CMPB 0DCh, #082h
                JBS off(02Eh).7, corr_map_lookup_flag_ram2e_b7
                CMPB 0DCh, #07Ah
corr_map_lookup_flag_ram2e_b7:
                MB off(02Eh).7, C
                STB A, r0
                LB A, #046h
                JBS off(02Bh).6, corr_map_lookup_cmp_acc_r0_2
                LB A, #047h
corr_map_lookup_cmp_acc_r0_2:
                CMPB A, r0
                MB off(02Bh).6, C
                LB A, r0
                JLT rpm_threshold_adjust
                JBS off(02Eh).7, rpm_threshold_adjust
                SUBB A, #00Ah
                JGE rpm_threshold_adjust
                CLRB A
rpm_threshold_adjust:
                CMPB 0CCh, #000h
                JBR off(01Eh).3, rpm_threshold_adjust_branch
                CMPB 0CCh, #000h
rpm_threshold_adjust_branch:
                JLT rpm_secondary_threshold_check
                JBR off(02Eh).1, rpm_secondary_threshold_check
                JBS off(024h).2, rpm_secondary_threshold_check
                ADDB A, #020h
                JGE rpm_secondary_threshold_check
                LB A, #0FFh
rpm_secondary_threshold_check:
                CMPB A, off(033h)
                MB off(02Eh).3, C
                LB A, #073h
                JBS off(02Eh).2, vss_threshold_cmp_acc_ram33
                LB A, #080h
vss_threshold_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(02Eh).2, C
                RB PSWL.4
                RB PSWL.5
                J ign_dispatch_warm_clear_ram2b_b7
corr_map_lookup_if_ram1b_b5_set:
                JBS off(01Bh).5, vss_threshold_if_ram1a_b6_set
                MB C, 0B1h.3
                JLT vss_threshold_if_ram1a_b6_set
                LB A, 09Dh
                CMPB A, #010h
                JGE doubleup_limiter_gate
vss_threshold_if_ram1a_b6_set:
                JBS off(01Ah).6, vaccut_rpm_check
                MB C, 0B0h.2
                JLT vaccut_rpm_check
                CMPB 0D1h, #024h
                JGE doubleup_limiter_gate
                MOV X1, #06033h
                LB A, 0D1h
                VCAL 1
                SJ vaccut_rpm_check_cmp_acc_ram33
vaccut_rpm_check:
                LB A, #090h
vaccut_rpm_check_cmp_acc_ram33:
                CMPB A, off(033h)
                JGE ofc_enable_check_if_ram2e_b0_set
                SJ revlimiter_fuelcut_set_pswl_b5
doubleup_limiter_gate:
                MOV DP, #00228h
                L A, #00218h
                MB C, P4.0
                JLT doubleup_limiter_cont
                JBS off(01Bh).7, doubleup_limiter_cont
                MOV DP, off(094h)
                L A, off(092h)
doubleup_limiter_cont:
                JBR off(024h).5, ignition_cut_mode_check
                L A, DP
ignition_cut_mode_check:
                CMP 0C4h, A
                JLT revlimiter_fuelcut_set_pswl_b5
                JBS off(021h).7, fuelcuttrack_goto_next
                JBS off(01Eh).2, corr_map_lookup_load_imm
                LCB A, 05470h
                JEQ fuelcut_extra_gate
corr_map_lookup_load_imm:
                LB A, #0C4h
                CMPB A, off(033h)
                JGE ignition_cut_mode_check_load_imm
                CMPB 0CCh, #0B4h
                JGE ignition_cut_mode_check_load_ramb8
                LB A, off(0B9h)
                JNE revlimiter_fuelcut_set_pswl_b5
ignition_cut_mode_check_load_imm:
                LB A, #028h
                STB A, off(0B8h)
                SJ fuelcut_extra_gate
ignition_cut_mode_check_load_ramb8:
                LB A, off(0B8h)
                JNE fuelcut_extra_gate
                LB A, #002h
                STB A, off(0B9h)
revlimiter_fuelcut_set_pswl_b5:
                SB PSWL.5
                SJ fuelcut_result_common
fuelcut_extra_gate:
                JBS off(024h).2, ofc_enable_check
                J timer_state_reinit_load_ramb3
ofc_enable_check:
                JBR off(020h).2, fuelcut_tps_recheck
                RB off(02Eh).1
ofc_enable_check_if_ram2e_b0_set:
                JBS off(02Eh).0, fuelcuttrack_goto_next
                JBS off(02Eh).2, fuelcut_tps_recheck_if_ram24_b2_set
fuelcuttrack_goto_next:
                J ign_dispatch_warm_load_imm_2
                DB  000h
fuelcut_clear_ram24_b2:
                RB off(024h).2
                SJ fuelcut_output_flags
fuelcut_tps_recheck:
                JBS off(02Eh).3, fuelcut_tps_recheck_if_ram24_b2_set
                SB off(02Eh).1
                SJ fuelcuttrack_goto_next
fuelcut_tps_recheck_if_ram24_b2_set:
                JBS off(024h).2, fuelcut_finalize_ign_flag
                LB A, 0C1h
                CMPB A, #010h
                JBS off(01Eh).3, to_fuelcut_branch
                CMPB A, #010h
to_fuelcut_branch:
                JGE fuelcuttrack_goto_next
                LB A, off(0CCh)
                JEQ fuelcut_finalize_ign_flag
                SB off(02Bh).7
                SJ fuelcut_clear_ram24_b2
fuelcut_finalize_ign_flag:
                JBR off(01Eh).3, fuelcut_finalize_ign_flag_if_ram2e_b5_set
                LB A, 0CCh
                CMPB A, #000h
                JGE fuelcut_finalize_ign_flag_if_ram2e_b5_set
                LB A, 0CDh
                SUBB A, 0CCh
                JLT fuelcut_finalize_ign_flag_if_ram19_b5_set
                CMPB A, #0FFh
                JGE fuelcut_finalize_ign_flag_set_ram2e_b5
fuelcut_finalize_ign_flag_if_ram19_b5_set:
                JBS off(019h).5, fuelcut_finalize_ign_flag_if_ram2e_b5_set
                JBS off(023h).7, fuelcut_finalize_ign_flag_if_ram2e_b5_set
                L A, 0C8h
                CMP A, #0FFFFh
                JLT fuelcut_finalize_ign_flag_if_ram2e_b5_set
                SB off(02Eh).6
                SJ fuelcut_finalize_ign_flag_if_ram2e_b5_set
fuelcut_finalize_ign_flag_set_ram2e_b5:
                SB off(02Eh).5
fuelcut_finalize_ign_flag_if_ram2e_b5_set:
                JBS off(02Eh).5, fuelcut_clear_ram24_b2
                JBS off(02Eh).6, fuelcut_clear_ram24_b2
                JBS off(02Ch).3, fuelcut_clear_ram24_b2
                SB PSWL.4
fuelcut_result_common:
                SB off(024h).2
fuelcut_output_flags:
                MB C, PSWL.5
                MB off(024h).5, C
                MB C, PSWL.4
                MB off(024h).4, C
                LB A, 0DCh
                CMPB A, #082h
                JBS off(02Bh).4, corr_map_lookup_flag_ram2b_b4
                CMPB A, #07Ah
corr_map_lookup_flag_ram2b_b4:
                MB off(02Bh).4, C
                ANDB PSWL, #0CFh
                MOVB r2, #000h
                JBS off(021h).7, ignmap2_result_check_clear_acc
                JBS off(025h).4, corr_map_lookup_load_ram32
                JBS off(02Ch).3, ignmap2_result_check_clear_acc
                JBS off(025h).5, ignmap2_result_check_clear_acc
                JBR off(022h).2, postig_result_default
                JBS off(022h).0, postig_result_default
                JBR off(01Eh).3, postig_gate_chain2
                JBS off(019h).5, postig_result_default
postig_gate_chain2:
                JBS off(020h).4, postig_result_default
                LB A, off(08Ch)
                MOVB r0, #04Bh
                JBS off(02Bh).5, postig_threshold_check1
                LB A, off(08Dh)
                MOVB r0, #05Ah
postig_threshold_check1:
                JBR off(023h).0, postig_threshold_check2
                CMPB A, r0
                JGE postig_threshold_check2
                LB A, r0
postig_threshold_check2:
                JBR off(01Fh).6, corr_map_lookup_cmp_acc_ram33
                MOVB r0, #045h
                JBS off(02Bh).5, corr_map_lookup_cmp_acc_r0_3
                MOVB r0, #046h
corr_map_lookup_cmp_acc_r0_3:
                CMPB A, r0
                JGE corr_map_lookup_cmp_acc_ram33
                JBS off(02Bh).4, corr_map_lookup_cmp_acc_ram33
                SUBB A, #00Ah
                JGE corr_map_lookup_cmp_acc_ram33
                CLRB A
corr_map_lookup_cmp_acc_ram33:
                CMPB A, off(033h)
                JGT ignmap2_result_check_clear_acc
                CMPB 0D9h, #034h
                JGE postig_result_high
                JBR off(01Eh).3, postig_result_high
                LB A, off(0CBh)
                STB A, r2
                JNE ignmap2_result_check_clear_acc
postig_result_high:
                LB A, #0E6h
                JBS off(01Eh).3, to_set_pswl_b5
                LB A, #0E6h
to_set_pswl_b5:
                SB PSWL.5
                SJ corr_map_lookup_set_pswl_b4
corr_map_lookup_load_ram32:
                LB A, off(032h)
                MOV X1, #059C6h
                CAL interp_word
                SJ corr_map_lookup_set_pswl_b4
ignmap2_result_check_clear_acc:
                CLRB A
                SJ ignmap2_flags_store_ram64
postig_result_default:
                LB A, #080h
                J timer_state_reinit_set_x1_3
corr_map_lookup_if_ram2b_b5_clr:
                JBR off(02Bh).5, ignmap2_rpm_gate
                LB A, #073h
                J timer_state_reinit_set_x1_4
ignmap2_rpm_gate:
                CMPB A, off(033h)
                JGE ignmap2_result_check_clear_acc
                LB A, off(033h)
                CAL interp_word
                ADDB A, #002h
                JGE ignmap2_result_check
                LB A, #0FFh
ignmap2_result_check:
                SUBB A, off(090h)
                JLT ignmap2_result_check_clear_acc
                CMPB A, off(032h)
                JLE ignmap2_result_check_clear_acc
                LB A, #0E6h
corr_map_lookup_set_pswl_b4:
                SB PSWL.4
ignmap2_flags_store_ram64:
                STB A, off(064h)
                MB C, PSWL.4
                MB off(02Bh).5, C
                MB C, PSWL.5
                MB off(026h).1, C
                MOVB off(0CBh), r2
                LB A, #0CDh
                JBS off(02Dh).0, ignmap2_flags_cmp_acc_ram33
                LB A, #0D0h
ignmap2_flags_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(02Dh).0, C
                LB A, #011h
                JBS off(024h).6, knock_window_check
                LB A, #00Eh
knock_window_check:
                CMPB 0C5h, A
                MB off(024h).6, C
                JGE knock_window_gate_common
                RC
                JBS off(025h).5, knock_window_gate_common
                JBS off(02Dh).0, knock_window_gate_common
                JBS off(02Bh).5, knock_window_gate_common
                JBS off(024h).2, knock_window_gate_common
                SC
knock_window_gate_common:
                MB off(025h).2, C
                LB A, #032h
                JBS off(02Ah).6, corr_map_lookup_cmp_acc_ramcc
                LB A, #034h
corr_map_lookup_cmp_acc_ramcc:
                CMPB A, 0CCh
                MB off(02Ah).6, C
                LB A, #0BAh
                JBS off(025h).3, rpm_gate_final_check
                LB A, #0C0h
rpm_gate_final_check:
                CMPB A, off(033h)
                MB off(025h).3, C
                JBR off(020h).0, o2_closedloop_read_and_select
                MOVB off(0B6h), #019h
o2_closedloop_read_and_select:
                LB A, #01Fh
                MOVB r0, #01Fh
                CMPB 0BCh, #0DBh
                JLT o2_closedloop_read_and_select_if_ram1e_b0_set
                LB A, #01Fh
                MOVB r0, #01Fh
o2_closedloop_read_and_select_if_ram1e_b0_set:
                JBS off(01Eh).0, o2_closedloop_read_and_select_cmp_acc_ramda
                LB A, r0
o2_closedloop_read_and_select_cmp_acc_ramda:
                CMPB A, 0DAh
                RB off(02Dh).2
                MB off(02Dh).2, C
                JEQ o2_closedloop_delay_dec
                XORB PSWH, #080h
o2_closedloop_delay_dec:
                MB off(02Dh).1, C
                L A, off(0DCh)
                JEQ o2_closedloop_gate1
                DEC off(0DCh)
o2_closedloop_gate1:
                JBR off(021h).3, o2_trim_gate_common
                JBS off(025h).4, o2_trim_gate_common
                MOV DP, #003AFh
                LB A, [DP]
                CMPB A, #031h
                JEQ o2_trim_gate_common
                CMPB 0F2h, #00Ch
                JLT o2_trim_gate_common
                MB C, 109[USP].3
                JLT o2_trim_gate_common
                MB C, 110[USP].4
                JLT o2_trim_gate_common
                L A, off(01Ah)
                AND A, #08075h
                JNE o2_trim_gate_common
                L A, off(01Ch)
                AND A, #01420h
                JNE o2_trim_gate_common
                CMPB 0D9h, #025h
                JGE o2_trim_gate_common
                LB A, 0DAh
                STB A, r0
                JBS off(024h).4, o2_if_ram2e_b4_set
                CMPB off(033h), #062h
                JGE o2_gate_tps_check
                MOVB off(0BBh), #032h
o2_gate_tps_check:
                LB A, off(0BBh)
                JNE o2_gate_dp_rc
                SB off(02Dh).3
o2_gate_dp_rc:
                RC
                JBS off(024h).5, dtc01_o2_latch
                JBR off(025h).5, dtc01_o2_latch
                LB A, #092h
                CMPB A, off(062h)
                JGE dtc01_o2_latch
                CMPB r0, #003h
                SJ dtc01_o2_latch
o2_if_ram2e_b4_set:
                JBS off(02Eh).4, o2_narrowband_check
                LB A, r0
                STB A, off(091h)
o2_narrowband_check:
                JBR off(02Dh).3, o2_trim_gate_reset_dp
                LB A, #09Ah
                CMPB A, r0
                JGE o2_trim_gate_common
                JBS off(020h).2, o2_trim_gate_common
                LB A, off(091h)
                SUBB A, r0
                JGE o2_delta_magnitude_check
                VCAL 6
o2_delta_magnitude_check:
                CMPB A, #002h
                JLT dtc01_o2_latch
o2_trim_gate_common:
                RB off(02Dh).3
o2_trim_gate_reset_dp:
                MOVB off(0BBh), #032h
                RC
dtc01_o2_latch:
                MB 0B0h.4, C
                MOVB r0, #064h
                JBR off(021h).3, o2_trim_tps_mode_check_goto_next
                JBS off(025h).4, o2_trim_tps_mode_check_goto_next
                MOV er1, #0828Fh
                JBR off(01Eh).2, o2_trim_table_ptr_load_imm
                MB C, 0B8h.5
                JGE o2_trim_table_ptr_load_imm
                JBR off(02Dh).1, o2_trim_table_ptr_alt
                RB 0B8h.5
o2_trim_table_ptr_load_imm:
                L A, #0828Fh
                JBS off(01Ah).2, o2_trim_clear_ram25_b1
                JBS off(01Ah).4, o2_trim_clear_ram25_b1
                MB C, 109[USP].3
                JLT o2_trim_table_ptr_alt
                MB C, 110[USP].4
                JLT o2_trim_table_ptr_alt
                L A, off(01Ah)
                AND A, #08061h
                JNE o2_trim_table_ptr_alt
                JBS off(01Dh).2, o2_trim_table_ptr_alt
                JBR off(01Dh).4, o2_trim_gate3
o2_trim_table_ptr_alt:
                L A, er1
                SJ o2_trim_clear_ram25_b1
o2_trim_gate3:
                JBR off(021h).1, o2_trim_tps_mode_check_goto_next
                JBS off(025h).5, o2_trim_tps_mode_check_goto_next
                JBS off(021h).0, o2_trim_tps_mode_check
                J ign_dispatch_warm_set_ramf8_b5
corr_map_lookup_set_ramc8:
                MOVB off(0C8h), r0
                MOV DP, #00304h
                JBR off(020h).0, o2_trim_dp_table_read
                MOV DP, #00300h
o2_trim_dp_table_read:
                L A, [DP]
                SJ o2_trim_clear_ram25_b1
o2_trim_tps_mode_check:
                JBS off(02Dh).0, o2_trim_tps_mode_check_goto_next
                JBR off(024h).6, corr_map_lookup_clear_ramf8_b5
                JBR off(024h).2, corr_map_lookup_if_ram2b_b5_clr_2
                MOVB off(0BFh), #00Ah
                SJ corr_map_lookup_clear_ramf8_b5
corr_map_lookup_if_ram2b_b5_clr_2:
                JBR off(02Bh).5, corr_map_lookup_set_ind_b2
corr_map_lookup_clear_ramf8_b5:
                RB off(0F8h).5
                NOP
                LB A, off(0C8h)
                JEQ o2_trim_default_target
                L A, off(058h)
                SB 109[USP].2
                SB off(025h).1
                SJ o2_trim_clear_ram25_b0
o2_trim_tps_mode_check_goto_next:
                J ign_dispatch_warm_set_ramf8_b5_2
corr_map_lookup_set_ramc8_2:
                MOVB off(0C8h), r0
o2_trim_default_target:
                L A, #08000h
o2_trim_clear_ram25_b1:
                RB off(025h).1
o2_trim_clear_ram25_b0:
                RB off(025h).0
                J injtimer_finalize_start
corr_map_lookup_set_ind_b2:
                SB 109[USP].2
                SB off(025h).1
                MOVB off(0C8h), r0
                MB C, off(02Dh).5
                MB PSWL.4, C
                LB A, #037h
                JLT o2_trim_step_threshold
                LB A, #04Ch
o2_trim_step_threshold:
                CMPB A, off(032h)
                MB off(02Dh).5, C
                MOVB r6, #004h
                MOVB r7, #004h
                L A, er3
                SB off(025h).0
                JEQ o2_trim_dp300_read
                JBS off(020h).3, o2_trim_alt_gate
                JBR off(020h).2, o2_trim_alt_gate
                ST A, off(07Ah)
                JBR off(020h).1, o2_trim_dp304_calc
                MOV DP, #00308h
                MOV er1, [DP]
                SJ o2_trim_step_finalize2
o2_trim_dp300_read:
                ST A, off(07Ah)
                MOV DP, #00300h
                MOV er1, [DP]
                JBS off(020h).0, o2_trim_step_finalize2
o2_trim_dp304_calc:
                MOV DP, #00304h
                MOV er0, [DP]
                L A, #08000h
                MOV er1, #08000h
                JBS off(01Eh).3, corr_map_lookup_cmp_ramd9_imm
                L A, #08000h
                MOV er1, #08000h
corr_map_lookup_cmp_ramd9_imm:
                CMPB 0D9h, #040h
                JLT o2_trim_mul_apply
                L A, er1
o2_trim_mul_apply:
                MUL
                SLL A
                ROL er1
                JGE o2_trim_step_finalize2
                MOV er1, #0FFFFh
o2_trim_step_finalize2:
                SB PSWL.5
                SJ o2_trim_result_check
o2_trim_alt_gate:
                MB C, PSWL.4
                JLT o2_trim_alt_gate_set_er1
                JBR off(02Dh).5, o2_trim_alt_gate_set_er1
                MOV DP, #00304h
                CMP [DP], off(058h)
                JGT o2_trim_dp304_calc
o2_trim_alt_gate_set_er1:
                MOV er1, off(058h)
                RB PSWL.5
                JBR off(02Dh).1, o2_trim_result_check
                ST A, off(07Ah)
o2_trim_result_check:
                MB C, PSWL.5
                JLT corr_map_lookup_load_er3
                JBS off(02Dh).1, corr_map_lookup_if_ram20_b0_set
corr_map_lookup_load_er3:
                L A, er3
                LB A, ACC
                MOV DP, #0017Ah
                JBR off(02Dh).2, o2_trim_decrement_apply
                LB A, ACCH
                INC DP
o2_trim_decrement_apply:
                DECB [DP]
                JEQ o2_trim_decrement_store_ind
                J o2trim_gate_common2
o2_trim_decrement_store_ind:
                STB A, [DP]
corr_map_lookup_if_ram20_b0_set:
                JBS off(020h).0, o2_trim_bank_index_alt
                LB A, 20[USP]
                CMPB A, off(033h)
                J ign_dispatch_warm_branch
                DB  000h,000h,000h,000h
o2_trim_bank_index_calc:
                CLR X1
                JBS off(02Fh).0, o2_trim_rate_table_select
                INC X1
                LB A, off(033h)
                CMPB A, #086h
                JGE o2_trim_rate_table_select
                INC X1
                CMPB A, #04Dh
                JGE o2_trim_rate_table_select
                INC X1
                SJ o2_trim_rate_table_select
o2_trim_bank_index_alt:
                MOV X1, #00004h
                JBS off(0F8h).5, corr_map_lookup_goto_next_3
                JBR off(02Dh).1, o2_trim_bank_index_calc
                J ign_dispatch_warm_load_imm
corr_map_lookup_goto_next_3:
                J to_injtimer_sub_common_load_ramc6
o2_trim_rate_table_select:
                SLL X1
                MOV DP, #ClosedLoopRate
                MB C, PSWL.5
                JLT o2_trim_table_offset_calc
                JBR off(02Dh).1, o2_trim_table_offset_calc
                MOV DP, #ClosedLoopStep
                JBS off(02Dh).2, o2_trim_table_offset_calc
                LB A, off(0C9h)
                JEQ o2trim_apply_start
o2_trim_table_offset_calc:
                L A, X1
                JBR off(01Eh).3, o2_trim_table_offset_calc2
                ADD A, #0000Ch
o2_trim_table_offset_calc2:
                JBS off(01Eh).0, o2_trim_rate_table_read
                ADD A, #00030h
o2_trim_rate_table_read:
                ADD DP, A
                LC A, [DP]
                JBS off(02Dh).2, o2trim_sub_clamp
                SJ o2trim_add_clamp
o2trim_apply_start:
                MOVB off(0C9h), #014h
                L A, #00B00h
                JBS off(02Fh).0, o2trim_add_clamp
                L A, #00000h
                JBS off(01Eh).3, cmp_x1_bound8_dispatch
                L A, #00000h
cmp_x1_bound8_dispatch:
                CMP X1, #00008h
                JEQ o2trim_add_clamp
                MOVB r0, #08Dh
                LB A, #04Dh
                JBS off(01Eh).3, to_o2trim_add_clamp
                MOVB r0, #08Dh
                LB A, #04Dh
to_o2trim_add_clamp:
                CMPB A, off(032h)
                JGT to_o2trim_add_clamp_load_ram76
                L A, off(0F2h)
                CMPB r0, off(033h)
                JGT to_o2trim_add_clamp_load_ram76
                JBR off(02Ah).6, corr_map_lookup_load_ram78
                SJ o2trim_add_clamp
to_o2trim_add_clamp_load_ram76:
                L A, off(076h)
                CMPB off(032h), #051h
                JBS off(01Eh).3, corr_map_lookup_branch_3
                CMPB off(032h), #051h
corr_map_lookup_branch_3:
                JLT o2trim_add_clamp
corr_map_lookup_load_ram78:
                L A, off(078h)
o2trim_add_clamp:
                ADD er1, A
                JGE o2trim_speed_flag_clear_pswl_b4
                MOV er1, #0FFFFh
                SJ o2trim_speed_flag_clear_pswl_b4
o2trim_sub_clamp:
                SUB er1, A
                JGE o2trim_speed_flag_clear_pswl_b4
                CLR er1
o2trim_speed_flag_clear_pswl_b4:
                RB PSWL.4
                RB PSWL.5
                L A, #0BC15h
                CMP A, er1
                JLE corr_map_lookup_set_pswl_b5
                L A, #05A00h
                CMP A, er1
                JLT corr_map_lookup_test_pswl_b4
                JBS off(01Fh).3, corr_map_lookup_set_pswl_b5
                CMPB 0D9h, #028h
                JGE corr_map_lookup_set_pswl_b5
                CMPB 0D8h, #02Eh
                JGE corr_map_lookup_set_pswl_b5
                CMPB 0DAh, #04Dh
                JGT corr_map_lookup_set_pswl_b5
                SB PSWL.4
                L A, #05A00h
                CMP A, er1
                JLT corr_map_lookup_test_pswl_b4
corr_map_lookup_set_pswl_b5:
                SB PSWL.5
                ST A, er1
corr_map_lookup_test_pswl_b4:
                MB C, PSWL.4
                MB off(026h).4, C
                MB C, PSWL.5
                MB off(0F8h).1, C
                MOV DP, #003AFh
                LB A, [DP]
                CMPB A, #031h
                JEQ o2trim_gate_common2
                LB A, off(0BFh)
                JNE o2trim_gate_common2
                JBS off(0F8h).1, o2trim_gate_common2
                JBR off(021h).1, o2trim_gate_common2
                JBS off(02Ch).4, o2trim_gate_common2
                CMPB 0D8h, #030h
                JLT o2trim_gate_common2
                CLR A
                CLRB A
                MB C, PSWL.5
                JLT o2trim_bank_select_check
                JBR off(02Dh).1, o2trim_bank_select_check
                JBS off(025h).3, o2trim_gate_common2
                MOV X1, #00300h
                JBS off(020h).0, o2trim_ect_offset_lookup
                MOV X1, #00304h
                LB A, #004h
                SJ o2trim_ect_offset_lookup
o2trim_bank_select_check:
                JBS off(020h).0, o2trim_gate_common2
                LB A, off(0B6h)
                JEQ o2trim_gate_common2
                MOV X1, #00308h
                LB A, #008h
o2trim_ect_offset_lookup:
                CMPB 0D9h, #02Eh
                JGE o2trim_ect_offset_lookup_rom_load_ind
                ADDB A, #002h
o2trim_ect_offset_lookup_rom_load_ind:
                LC A, ClosedLoopOffsets[ACC]
                L A, ACC
                ST A, er0
                L A, er1
                ST A, er3
                CAL alu_1
                CAL const_table_b
                MOV er1, er3
o2trim_gate_common2:
                L A, er1
injtimer_finalize_start:
                ST A, off(058h)
                LB A, #073h
                JBS off(030h).3, corr_map_lookup_cmp_acc_ram33_2
                LB A, #080h
corr_map_lookup_cmp_acc_ram33_2:
                CMPB A, off(033h)
                MB off(030h).3, C
                LB A, #0F2h
                JBS off(030h).4, corr_map_lookup_cmp_acc_ram32
                LB A, #0F9h
corr_map_lookup_cmp_acc_ram32:
                CMPB A, off(032h)
                MB off(030h).4, C
                LB A, off(06Ch)
                JBS off(025h).4, to_injtimer_sub_common_store_ram63
                LB A, #080h
                JBS off(02Fh).7, to_injtimer_sub_common_store_ram63
                JBS off(02Bh).5, to_injtimer_sub_common_store_ram63
                MOV X1, #InjectorCorrectionLimits
                MOV X2, #00168h
                JBR off(025h).1, corr_map_lookup_goto_next_4
                ADD X1, #00004h
                INC X2
                INC X2
corr_map_lookup_goto_next_4:
                J timer_state_reinit_if_ram1e_b3_set
                DB  000h
corr_map_lookup_load_ind:
                L A, 00000h[X2]
                ST A, er3
                JBS off(025h).1, corr_map_lookup_load_ram32_2
                CMP off(05Ah), #03000h
                JGE corr_map_lookup_load_ram69
                JBR off(030h).3, corr_map_lookup_load_ram69
                JBS off(030h).4, corr_map_lookup_load_ram69
                LB A, 0C0h
                JBR off(023h).4, corr_map_lookup_if_ram23_b1_clr
                CMPB A, #006h
                JGE corr_map_lookup_load_ram69
corr_map_lookup_if_ram23_b1_clr:
                JBR off(023h).1, corr_map_lookup_load_ram6e
                LB A, #005h
                JBS off(01Eh).3, corr_map_lookup_cmp_acc_ramd5
                LB A, #005h
corr_map_lookup_cmp_acc_ramd5:
                CMPB A, 0D5h
                JGE corr_map_lookup_load_ram6e
corr_map_lookup_load_ram69:
                LB A, off(069h)
                SUBB A, off(06Dh)
                JGE corr_map_lookup_store_ram6e
                CLRB A
corr_map_lookup_store_ram6e:
                STB A, off(06Eh)
                SJ corr_map_lookup_load_ram32_2
corr_map_lookup_load_ram6e:
                LB A, off(06Eh)
                MOVB r0, #0FAh
                MULB
                LB A, ACCH
                STB A, off(06Eh)
                ADDB A, off(06Dh)
                STB A, r7
corr_map_lookup_load_ram32_2:
                LB A, off(032h)
                CAL clamp_table
to_injtimer_sub_common_store_ram63:
                STB A, off(063h)
                LB A, off(032h)
                MOV X1, #056AAh
                CAL interp_word
                CLRB ACCH
                L A, ACC
                ADD A, #00040h
                CLRB r0
                MOVB r1, off(067h)
                MUL
                J timer_state_reinit_sll_acc_2
corr_map_lookup_add_acc:
                ADD A, #00200h
                ST A, off(05Eh)
                MOV DP, #003EEh
                MOV er3, [DP]
                LB A, off(032h)
                STB A, r0
                MOVB r4, #0E6h
                CMPB A, r4
                JGE corr_map_lookup_set_ram5c
                MOV DP, #003EAh
                MOV er3, [DP]
                MOVB r2, #019h
                LB A, r0
                CMPB A, r2
                JLT corr_map_lookup_set_ram5c
                LB A, #064h
                CMPB A, r0
                JLT corr_map_lookup_inc_dp
                STB A, r4
                LB A, r2
                SJ corr_map_lookup_sub_r0
corr_map_lookup_inc_dp:
                INC DP
                INC DP
corr_map_lookup_sub_r0:
                SUBB r0, A
                CLRB r1
                SUBB r4, A
                CLRB r5
                L A, [DP]
                ST A, er3
                INC DP
                INC DP
                L A, [DP]
                CAL scale_div
corr_map_lookup_set_ram5c:
                MOV off(05Ch), er3
                LB A, #0FFh
                JBS off(02Dh).6, to_injtimer_sub_common_cmp_acc_ram33
                LB A, #0FFh
to_injtimer_sub_common_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(02Dh).6, C
                LB A, #0FFh
                JBS off(02Dh).7, to_injtimer_cmp_acc_ramd1
                LB A, #0FFh
to_injtimer_cmp_acc_ramd1:
                CMPB A, 0D1h
                MB off(02Dh).7, C
                JBR off(021h).3, injtimer_gate_common
                MB C, 109[USP].3
                JLT injtimer_gate_common
                MB C, 110[USP].4
                JLT injtimer_gate_common
                JBS off(020h).6, injtimer_gate_common
                CMPB 0D9h, #000h
                JGE injtimer_gate_common
                CMPB 0D9h, #000h
                JLT injtimer_gate_common
                JBR off(02Dh).6, injtimer_gate_common
                JBR off(02Dh).7, injtimer_gate_common
                JBR off(021h).0, injtimer_gate_common
                JBS off(02Bh).5, injtimer_gate_common
                JBS off(025h).1, injtimer_gate_common
                JBS off(02Dh).2, injtimer_gate_common
                LB A, #000h
                SJ injtimer_store_ram66
injtimer_gate_common:
                LB A, off(066h)
                SUBB A, #000h
                JGE injtimer_store_ram66
                CLRB A
injtimer_store_ram66:
                STB A, off(066h)
                LB A, off(062h)
                JBS off(02Fh).7, injtimer_store_r1
                LB A, off(063h)
injtimer_store_r1:
                STB A, r1
                CLRB r0
                SRL er0
                SRL er0
                LB A, off(064h)
                JEQ injtimer_load_ram65
                STB A, ACCH
                CLRB A
                MUL
                MOV er0, er1
injtimer_load_ram65:
                LB A, off(065h)
                JEQ injtimer_mul_chain1
                STB A, ACCH
                CLRB A
                MUL
                MOV er0, er1
injtimer_mul_chain1:
                MOVB ACCH, #001h
                LB A, off(066h)
                MUL
                MOVB r1, r2
                MOVB r0, ACCH
                L A, off(060h)
                MUL
                MOV er0, er1
                L A, off(05Eh)
                MUL
                SRL er1
                ROR A
                SRL er1
                ROR A
                MOVB r1, r2
                MOVB r0, ACCH
                LB A, r3
                JEQ injtimer_mul_chain2
                MOV er0, #0FFFFh
injtimer_mul_chain2:
                L A, off(05Ch)
                MUL
                MOV er0, er1
                JBR off(02Ch).4, injtimer_mul_final
                SLL A
                ROL er0
                JLT injtimer_mul_clamp
                SLL A
                ROL er0
                JLT injtimer_mul_clamp
                SLL A
                ROL er0
                JGE injtimer_mul_chain3
injtimer_mul_clamp:
                MOV er0, #0FFFFh
injtimer_mul_chain3:
                L A, off(05Ah)
                MUL
                MOV er0, er1
injtimer_mul_final:
                L A, off(058h)
                MUL
                MOV off(056h), er1
                LB A, #040h
                JBS off(030h).6, corr_map_lookup_cmp_acc_ram33_3
                LB A, #04Dh
corr_map_lookup_cmp_acc_ram33_3:
                CMPB A, off(033h)
                MB off(030h).6, C
                JBS off(025h).4, dwell_zero_result
                LB A, off(033h)
                CMPB A, #0A0h
                JGE dwell_zero_result
                JBR off(029h).0, dwell_zero_result
                LB A, #004h
                JBS off(023h).4, dwell_rpm_gate2
                LB A, #004h
                CMPB 0F3h, #096h
                JLT dwell_zero_result
dwell_rpm_gate2:
                CMPB off(033h), #002h
                JBS off(023h).4, dwell_rpm_gate3
                MB C, off(030h).6
                XORB PSWH, #080h
dwell_rpm_gate3:
                JLT dwell_zero_result
                CMPB A, 0C0h
                JGE dwell_zero_result
                MOVB r0, off(08Bh)
                CMPB off(033h), #074h
                JGE dwell_value_select
                MOVB r0, off(089h)
dwell_value_select:
                MOVB r1, #014h
                JBS off(023h).4, dwell_clamp_check
                MOVB r0, off(08Ah)
                MOVB r1, #010h
dwell_clamp_check:
                LB A, 0C0h
                CMPB A, r1
                JLE dwell_mul_apply
                LB A, r1
dwell_mul_apply:
                MULB
                L A, ACC
                SRL A
                JBS off(023h).4, dwell_store_ram46
                VCAL 7
                SJ dwell_store_ram46
dwell_zero_result:
                CLR A
dwell_store_ram46:
                ST A, off(046h)
                CLRB r4
                RC
                JBS off(025h).4, rpm_accel_skip
                JBR off(022h).3, rpm_accel_skip
                JBS off(02Ch).7, rpm_accel_track_calc
                JBS off(022h).4, rpm_accel_alt_path
                L A, -38[USP]
                CLRB r5
                SJ rpm_accel_track_store_ram38
rpm_accel_track_calc:
                MOV er3, off(038h)
                MOVB r5, off(03Ah)
                CLRB r0
                MOVB r1, #080h
                L A, 0C4h
                CAL mul8_shift
rpm_accel_track_store_ram38:
                ST A, off(038h)
                MOVB off(03Ah), r5
                CLRB r4
                SUB A, 0C4h
                MB off(02Ch).6, C
                MOV DP, #003E8h
                JLT rpm_accel_fault_path
                ST A, [DP]
                JBS off(023h).6, rpm_accel_secondary_calc
                CMP 0C6h, #0001Ah
                SJ rpm_accel_gate_result
rpm_accel_fault_path:
                VCAL 7
                ST A, [DP]
                JBR off(023h).6, rpm_accel_secondary_calc
                CMP 0C6h, #0001Ah
rpm_accel_gate_result:
                JGE rpm_accel_clamp
rpm_accel_secondary_calc:
                CLRB r0
                MOVB r1, #01Eh
                CMPB 0D9h, #034h
                JGE rpm_accel_mul_apply
                JBS off(01Eh).3, rpm_accel_mul_apply
                CMPB 0CCh, #005h
                JLT rpm_accel_mul_apply
                MOVB r1, #01Eh
rpm_accel_mul_apply:
                MUL
                MOVB r4, #02Ah
                SLL A
                ROL er1
                JLT rpm_accel_clamp
                SLL A
                ROL er1
                JLT rpm_accel_clamp
                LB A, r3
                JNE rpm_accel_clamp
                LB A, r2
                CMPB A, r4
                JGE rpm_accel_clamp
                STB A, r4
rpm_accel_clamp:
                SC
rpm_accel_skip:
                MB off(02Ch).7, C
rpm_accel_alt_path:
                LB A, r4
                JEQ rpm_accel_store_ram48
                JBS off(02Ch).6, rpm_accel_store_ram48
                VCAL 6
rpm_accel_store_ram48:
                STB A, off(048h)
                JBR off(01Eh).3, corr_map_lookup_clear_acc_2
                JBR off(019h).5, corr_map_lookup_cmp_ramd9_imm_2
                RB off(030h).7
                SJ corr_map_lookup_clear_acc_2
corr_map_lookup_cmp_ramd9_imm_2:
                CMPB 0D9h, #0FFh
                JLT corr_map_lookup_clear_acc_2
                MOVB r0, #000h
                MOV er1, #0FFFFh
                CMPB 0D9h, #0FFh
                JLT corr_map_lookup_set_dp
                MOVB r0, #000h
                MOV er1, #0FFFFh
corr_map_lookup_set_dp:
                MOV DP, #00311h
                LB A, [DP]
                ADDB A, #000h
                CMPB A, 0D4h
                JLT corr_map_lookup_load_ramf0
                JBS off(023h).6, corr_map_lookup_load_ramf0
                CMP 0C6h, #0FFFFh
                LB A, #000h
                JLT corr_map_lookup_if_ram30_b7_set
                LB A, #000h
corr_map_lookup_if_ram30_b7_set:
                JBS off(030h).7, corr_map_lookup_cmp_ramc0_imm
                MOVB off(0C0h), #001h
                SB off(030h).7
corr_map_lookup_cmp_ramc0_imm:
                CMPB off(0C0h), #000h
                JNE corr_map_lookup_clear_r1
corr_map_lookup_load_ramf0:
                L A, off(0F0h)
                SUB A, er1
                JGE corr_map_lookup_store_ramf0
corr_map_lookup_clear_acc_2:
                CLR A
                SJ corr_map_lookup_store_ramf0
corr_map_lookup_clear_r1:
                CLRB r1
                MULB
                MOV er0, 0C6h
                MUL
                MOV er0, #00000h
                L A, ACC
                SLL A
                ROL er1
                CMPB r3, #000h
                JNE corr_map_lookup_load_er0
                LB A, r2
                L A, ACC
                SWAP
                CMP A, er0
                JLT corr_map_lookup_store_ramf0
corr_map_lookup_load_er0:
                L A, er0
corr_map_lookup_store_ramf0:
                ST A, off(0F0h)
                CLR A
                CLRB r0
                JBS off(025h).4, rpm_decel_flags_clear_ram2e_b5
                JBS off(024h).0, rpm_decel_flags_clear_ram2e_b5
                MOVB r0, #004h
                JBS off(024h).2, rpm_decel_flags_clear_ram2e_b5
                MOVB r0, off(054h)
                CMPB r0, #000h
                JNE rpm_decel_table_lookup
                JBR off(023h).1, corr_map_lookup_set_r1
                CMPB 0D5h, #003h
                JGE rpm_decel_flags_clear_ram2e_b5
corr_map_lookup_set_r1:
                MOVB r1, off(055h)
                CMPB r1, #000h
                JEQ rpm_decel_diff_check2
                DECB r1
                JNE rpm_decel_store_ram4a
rpm_decel_diff_check2:
                L A, off(050h)
                JEQ rpm_decel_flags_clear_ram2e_b5
                SUB A, off(052h)
                JGE rpm_decel_flags_clear_ram2e_b5
                CLR A
                SJ rpm_decel_flags_clear_ram2e_b5
rpm_decel_table_lookup:
                LB A, off(033h)
                MOV X1, #057E9h
                VCAL 0
                DB  0B5h,0C8h,0C2h,0F9h,0C4h,054h,048h,0B8h
                DB  0EFh,023h,036h,0CDh,034h,067h,07Dh,000h
                DB  0EDh,02Eh,00Fh,067h,07Dh,000h,0EEh,02Eh
                DB  009h,067h,07Dh,000h,0DBh,01Eh,003h,067h
                DB  07Dh,000h,0B4h,082h,048h,090h,035h,045h
                DB  0E7h,043h,045h,0E7h,043h,07Ah,0E5h,006h
                DB  083h,023h,0C0h,000h,0C9h,003h,067h,0FFh
                DB  0FFh,020h,015h
rpm_decel_flags_clear_ram2e_b5:
                RB off(02Eh).5
                RB off(02Eh).6
                ST A, off(050h)
                MOVB r1, #004h
rpm_decel_store_ram4a:
                ST A, off(04Ah)
                MOVB off(054h), r0
                MOVB off(055h), r1
                JBR off(024h).4, tipin_time_calc
                CLR A
                MOV X1, A
                ST A, 003B8h[X1]
                ST A, 003BAh[X1]
                ST A, 003BCh[X1]
                ST A, 003BEh[X1]
                ST A, 003C0h[X1]
                ST A, 003A6h[X1]
                J corr_map_lookup_load_imm_2
tipin_time_calc:
                L A, off(042h)
                JBR off(02Bh).3, corr_map_lookup_add_acc_2
                CMPB 0F2h, #004h
                MB off(02Bh).3, C
                ADD A, #00064h
                JLT tipin_time_clamp
corr_map_lookup_add_acc_2:
                ADD A, off(044h)
                JLT tipin_time_clamp
                ADD A, off(0F0h)
                JLT tipin_time_clamp
                ADD A, off(04Ah)
                JGE tipin_time_finalize
tipin_time_clamp:
                L A, #0FFFFh
tipin_time_finalize:
                ST A, er0
                LB A, off(048h)
                EXTND
                MOV er3, off(046h)
                CAL accum_loop
                LB A, off(049h)
                EXTND
                CAL accum_loop
                CMP A, #08000h
                JGE tipin_overflow_check1
                ADD A, er0
                JGE tipin_overflow_check2
                SJ tipin_overflow_clamp
tipin_overflow_check1:
                ADD A, er0
                JGE tipin_result_store_er3
tipin_overflow_check2:
                CMP A, #08000h
                JLT tipin_result_store_er3
tipin_overflow_clamp:
                L A, #07FFFh
tipin_result_store_er3:
                ST A, er3
                MOV X2, A
                L A, off(040h)
                MOV er0, off(056h)
                MUL
                SRL er1
                ROR A
                LB A, r2
                L A, ACC
                SWAP
                CMPB r3, #000h
                JEQ injtimer_bank_a_calc
                L A, #0FFFFh
injtimer_bank_a_calc:
                ST A, er2
                XCHG A, er3
                VCAL 4
                JBR off(024h).5, corr_map_lookup_set_dp_2
                CLR A
corr_map_lookup_set_dp_2:
                MOV DP, #003A6h
                ST A, [DP]
                L A, er3
                MOV DP, #003B8h
                MOV er0, [DP]
                ST A, [DP]
                JBS off(025h).4, injtimer_bank_b_zero
                CMPB off(033h), #074h
                JGE injtimer_bank_b_zero
                J ign_dispatch_warm_cmp_ram4a_imm
corr_map_lookup_if_ram2c_b3_clr:
                JBR off(02Ch).3, injtimer_bank_b_zero
                CLRB r0
                MOVB r1, #080h
                L A, off(042h)
                SJ corr_map_lookup_mul
corr_map_lookup_nop:
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                SUB A, er0
                JLT injtimer_bank_b_zero
                CMP A, #000FAh
                JGE injtimer_bank_b_clamp
injtimer_bank_b_zero:
                CLR A
                SJ injtimer_bank_b_store_ram4e
injtimer_bank_b_clamp:
                MOV er0, #007D0h
                CMP A, er0
                JGE injtimer_bank_b_default
                ST A, er0
injtimer_bank_b_default:
                CLR A
                MOVB ACCH, #080h
corr_map_lookup_mul:
                MUL
                SLL A
                L A, er1
                ROL A
                JGE injtimer_bank_b_store_ram4e
                L A, #0FFFFh
injtimer_bank_b_store_ram4e:
                ST A, off(04Eh)
                L A, off(04Ah)
                CMP A, off(04Eh)
                MB off(02Ch).5, C
                JGE injtimer_bank_c_check
                L A, off(04Eh)
injtimer_bank_c_check:
                L A, ACC
                JEQ injtimer_bank_c_set_x1
                ADD A, off(044h)
                JGE injtimer_bank_c_scale
                L A, #0FFFFh
injtimer_bank_c_scale:
                CAL mul_shift_b
injtimer_bank_c_set_x1:
                MOV X1, A
                JBR off(02Ch).5, injtimer_critsection_start
                CLR A
injtimer_critsection_start:
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                MOV off(09Ch), X1
                ST A, off(098h)
                ST A, off(09Ah)
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                LCB A, 0547Bh
                JEQ corr_map_lookup_load_ind_2
                MOV X1, #0569Ah
cylinder_ign_correct_loop:
                INC DP
                INC DP
                L A, er2
                JBR off(025h).1, cylinder_ign_correct_apply
                ST A, er0
                CLR A
                LCB A, [X1]
                SWAP
                MUL
                SLL A
                L A, er1
                ROL A
                JGE cylinder_ign_correct_apply
                L A, #0FFFFh
cylinder_ign_correct_apply:
                MOV er3, X2
                XCHG A, er3
                VCAL 4
                CAL mul_shift_b
                ST A, [DP]
                INC X1
                CMP DP, #003C0h
                JLT cylinder_ign_correct_loop
                SJ corr_map_lookup_load_imm_2
corr_map_lookup_load_ind_2:
                L A, [DP]
                CAL mul_shift_b
                CLR X1
                ST A, 003BAh[X1]
                ST A, 003BCh[X1]
                ST A, 003BEh[X1]
                ST A, 003C0h[X1]
corr_map_lookup_load_imm_2:
                LB A, #0C5h
                JBS off(02Bh).2, corr_map_lookup_cmp_acc_ram33_4
                LB A, #0C8h
corr_map_lookup_cmp_acc_ram33_4:
                CMPB A, off(033h)
                MB off(02Bh).2, C
                L A, #0186Ah
                JBR off(0F8h).2, corr_map_lookup_cmp_ramc4_acc
                L A, #030D4h
corr_map_lookup_cmp_ramc4_acc:
                CMP 0C4h, A
                MB off(0F8h).2, C
                LB A, off(03Dh)
                JNE deadtime_retry_check
                LB A, #005h
                JBS off(025h).4, deadtime_retry_goto_next
                MOVB r6, #00Ah
                RB PSWL.4
                L A, off(01Ah)
                AND A, #01034h
                JNE to_gio_mode_dispatch
                SB PSWL.4
                MOVB r6, #005h
                JBR off(0F8h).2, to_gio_mode_dispatch
                MOVB r6, #007h
                JBS off(02Ch).5, to_gio_mode_dispatch
                RB PSWL.4
                CMPB 0D9h, #0FFh
                JGE deadtime_ect_offset
                MOVB r6, #009h
                JBS off(020h).0, to_gio_mode_dispatch
deadtime_ect_offset:
                CLR DP
                LB A, 0D9h
                CMPB A, #0A1h
                JLT deadtime_ect_offset_load_imm
                ADD DP, #00003h
deadtime_ect_offset_load_imm:
                LB A, #086h
                JBS off(02Bh).1, deadtime_ect_offset_cmp_rambe_acc
                LB A, #074h
deadtime_ect_offset_cmp_rambe_acc:
                CMPB 0BEh, A
                MB off(02Bh).1, C
                LB A, #0A8h
                JBS off(02Bh).0, deadtime_voltage_flag_cmp_rambe_acc
                LB A, #095h
deadtime_voltage_flag_cmp_rambe_acc:
                CMPB 0BEh, A
                MB off(02Bh).0, C
                JGE deadtime_voltage_flag_rom_load_ind
                INC DP
                JBR off(02Bh).1, deadtime_voltage_flag_rom_load_ind
                INC DP
deadtime_voltage_flag_rom_load_ind:
                LCB A, InjectorTimerSelect[DP]
                STB A, r6
                NOP
                NOP
                NOP
                NOP
                NOP
                SJ to_gio_mode_dispatch
deadtime_retry_check:
                MB C, 0B7h.0
                JGE deadtime_retry_sub_acc
                LB A, #005h
deadtime_retry_sub_acc:
                SUBB A, #001h
                STB A, off(03Dh)
                LB A, #00Bh
deadtime_retry_goto_next:
                SJ injector_effective_pw_store_ram3b
to_gio_mode_dispatch:
                J timer_state_reinit_load_r6
corr_map_lookup_load_ind_3:
                L A, [DP]
                CAL mul_shift_b
                CLR er0
                MOV er2, off(036h)
                DIV
                JLT injector_effective_pw_skip
                CMP A, #0000Bh
                JGT injector_effective_pw_skip
                LB A, ACC
                XCHGB A, r6
                SUBB A, r6
                JLT injector_effective_pw_skip
                JBS off(02Bh).2, corr_map_lookup_goto_next_5
                MOVB r6, off(03Bh)
                SUBB r6, #001h
                JLT corr_map_lookup_goto_next_5
                CMPB A, r6
                JNE corr_map_lookup_goto_next_5
                MOV X1, er1
                STB A, r6
                L A, #08000h
                MOV er0, er2
                MUL
                L A, er1
                CMP A, X1
                LB A, r6
                JLT corr_map_lookup_goto_next_5
                CMPB A, #00Bh
                JGE corr_map_lookup_goto_next_5
                ADDB A, #001h
corr_map_lookup_goto_next_5:
                SJ injector_effective_pw_store_ram3b
injector_effective_pw_skip:
                CLRB A
injector_effective_pw_store_ram3b:
                STB A, off(03Bh)
                LB A, #0C2h
                JBS off(024h).0, rpm_hyst_flag_cmp_acc_ram33
                LB A, #0C5h
rpm_hyst_flag_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(024h).0, C
                LB A, #0EDh
                JBS off(024h).1, rpm_hyst_flag_cmp_acc_ram33_2
                LB A, #0F0h
rpm_hyst_flag_cmp_acc_ram33_2:
                CMPB A, off(033h)
                MB off(024h).1, C
                JBR off(021h).3, crank_edge_carry_rc
                JBR off(01Eh).6, crank_edge_carry_rc
                LB A, off(0BCh)
                JNE crank_edge_carry_rc
                JBR off(021h).2, crank_edge_carry_rc
                MOV DP, #00F00h
                LB A, [DP]
                ANDB A, #040h
                MB C, 0B8h.2
                JLT crank_edge_sync_check
                JNE crank_edge_carry_sc
                RB P1.2
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                LB A, P1
                MOV DP, #02F00h
                STB A, [DP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                SJ crank_edge_direction_toggle
crank_edge_sync_check:
                JEQ crank_edge_carry_sc
crank_edge_direction_toggle:
                XORB PSWH, #080h
                MB 0B8h.2, C
                JGE crank_edge_carry_rc
                MOVB off(0BCh), #019h
crank_edge_carry_rc:
                RC
                SJ dtc27_code27_latch
crank_edge_carry_sc:
                SC
dtc27_code27_latch:
                MB 0B3h.2, C
                CAL flag_pair
                SB 0B6h.4
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                J int1_rti_epilogue
; Spurious-IRQ trap (code 0x45): every overflow/ADC/IRQ14 vector points here; SJ trap_retry_check.
spurious_irq_trap:
                MOVB 0F5h, #045h
                SJ trap_retry_check
; WDT timeout trap (code 0x44): falls into trap_retry_check (code 0x44).
wdt_trap:
                MOVB 0F5h, #044h
; Retry trampoline: while the countdown 0F6h is non-zero, decrement and BRK again with the same trap
; code; when it hits 0, latch 0B7h.1 (boot_trap_handler then skips resetting 0F6h) and BRK again.
trap_retry_check:
                LB A, 0F6h
                JEQ fault_giveup_latch
                DECB 0F6h
                JNE fault_trigger_brk
fault_giveup_latch:
                SB 0B7h.1
fault_trigger_brk:
                BRK
; Power-on boot entry (trap code 0x46 = 'first boot'): clears the retry latch 0B7h.1, reloads the
; WDT (#0x3C), then falls into boot_trap_handler below.
boot_main:
                MOVB 0F5h, #046h
                RB 0B7h.1
; BRK / trap dispatch: reloads WDT, sets up stack 0x47E / LRB 0x10, copies the trap code 0F5h to 0AFh.
; Code 0x46/0x47 = first boot: runs the register self-test then ram_defaults and the
; rest of boot. Other codes (0x44 WDT, 0x45 spurious IRQ, 0x4B timer drift, 0x4F IE-mask mismatch,
; 0x50 state corruption): re-runs selftest_registers when 02Ch.1 (self-test armed) is set, otherwise
; tail-jumps to nmi_period_sync to re-initialise. The retry countdown 0F6h (0x20) and latch 0B7h.1 are
; managed by trap_retry_check.
boot_trap_handler:
                MOVB WDT, #03Ch
                MOV SSP, #0047Eh
                MOV LRB, #00010h
                CLR off(004h)
                LB A, off(0F5h)
                STB A, off(0AFh)
                JNE breset_check_reason_cmp_acc_imm
                MOVB off(0F5h), #04Eh
                SJ trap_retry_check
breset_check_reason_cmp_acc_imm:
                CMPB A, #046h
                JEQ breset_reason_clear_ramaf
                CMPB A, #047h
                JNE breset_check_p4_1
breset_reason_clear_ramaf:
                CLRB off(0AFh)
                MOV DP, #04700h
                LB A, [DP]
                SRLB A
                MB off(0B7h).0, C
                JBS off(0B7h).1, breset_check_p4_1
                MOVB off(0F6h), #020h
breset_check_p4_1:
                JBR off(02Ch).1, selftest_registers
                J nmi_period_sync
; Register self-test (first boot only): SSP 0x5555 read/write, IE read/write, LRB 0x1555/0x0AAA, SSP
; 0xAAAA, IE/PSW sign-bit tricks (PSWL 0x55/0xAA, PSWH.0 JGE/JLT). Any mismatch -> trap 0x41.
selftest_registers:
                L A, #05555h
                XCHG A, SSP
                XCHG A, SSP
                CMP A, #05555h
                JNE selftest_fail_set_ramf5
                ST A, IE
                CMP A, IE
                JNE selftest_fail_set_ramf5
                L A, #01555h
                MOV LRB, A
                CMP A, LRB
                JNE selftest_fail_set_ramf5
                L A, #0AAAAh
                XCHG A, SSP
                XCHG A, SSP
                CMP A, #0AAAAh
                JNE selftest_fail_set_ramf5
                ST A, IE
                CMP A, IE
                JNE selftest_fail_set_ramf5
                L A, #00AAAh
                MOV LRB, A
                CMP A, LRB
                JNE selftest_fail_set_ramf5
                CLR A
                ST A, IE
                ST A, 0F8h
                ST A, 0FAh
                MOV LRB, #00010h
                LB A, #055h
                XCHGB A, PSWL
                XCHGB A, PSWL
                CMPB A, #0DDh
                JNE selftest_fail_set_ramf5
                LB A, #0AAh
                XCHGB A, PSWL
                XCHGB A, PSWL
                CMPB A, #0EAh
                JNE selftest_fail_set_ramf5
                SB PSWH.0
                MB C, PSWH.0
                MB PSWH.6, C
                JGE selftest_fail_set_ramf5
                JNE selftest_fail_set_ramf5
                RB PSWH.0
                MB C, PSWH.0
                MB PSWH.6, C
                JLT selftest_fail_set_ramf5
                JNE ram_defaults
selftest_fail_set_ramf5:
                MOVB 0F5h, #041h
                BRK
; First-boot RAM defaults: injector/timing words 020h-043h (020h=0xEB..043h=0x8F), 029h=0xB1,
; 02Ah=0xFF, 02Ch=0xF7 (self-test armed bit 02Ch.1), 070h-07Ah = 0xFF00 pairs, 072h/076h = 0xFFFF,
; 078h=0x3E, 07Ah=0x7E, 02Dh=0x0D, 02Eh=0xF0, TCON bits 040h.4/041h.4/042h.4/043h.4 set, 018h=0.
ram_defaults:
                CLRB off(012h)
                LB A, #0FFh
                MOVB off(020h), #0EBh
                STB A, off(021h)
                MOVB off(022h), #044h
                STB A, off(023h)
                MOVB off(024h), #01Fh
                STB A, off(025h)
                CLRB off(026h)
                MOVB off(028h), #0EFh
                MOVB off(040h), #08Bh
                CLR A
                ST A, off(030h)
                ST A, off(032h)
                MOVB off(041h), #04Fh
                ST A, off(034h)
                ST A, off(036h)
                MOVB off(042h), #082h
                ST A, off(038h)
                ST A, off(03Ah)
                MOVB off(043h), #08Fh
                MOV off(03Ch), #00001h
                ST A, off(03Eh)
                MOVB off(029h), #0B1h
                MOVB off(02Ah), #0FFh
                CLRB off(01Ch)
                SB off(040h).2
                RB off(040h).2
                MOVB off(02Ch), #0F7h
                L A, #0FF00h
                MOVB off(078h), #03Eh
                ST A, off(070h)
                ST A, off(072h)
                MOVB off(07Ah), #07Eh
                ST A, off(074h)
                ST A, off(076h)
                MOVB off(02Dh), #00Dh
                MOVB off(02Eh), #0F0h
                SB off(040h).4
                SB off(041h).4
                SB off(042h).4
                XCHG A, ACC
                SB off(043h).4
                CLR off(018h)
                MOV DP, #002E8h
periph_init_delay_loop:
                DEC DP
                JNE periph_init_delay_loop
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
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                RB off(019h).5
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                L A, #0FFFFh
                ST A, off(072h)
                ST A, off(076h)
                NOP
                NOP
                NOP
                L A, #05555h
                MOV X1, A
                CMP A, X1
                JNE selftest_fail_set_ramf5_2
                MOV X2, A
                CMP A, X2
                JNE selftest_fail_set_ramf5_2
                SLL A
                MOV X1, A
                CMP A, X1
                JNE selftest_fail_set_ramf5_2
                MOV X2, A
                CMP A, X2
                JEQ selftest_ram
selftest_fail_set_ramf5_2:
                MOVB off(0F5h), #042h
                BRK
; RAM read/write test: the test window comes from ROM 0x03FA (start word); each word is written via
; ram_readback_test (ram_readback_test, write/readback/X2 compare -> BRK 0x42 on mismatch), X1 walks down by 2.
selftest_ram:
                MOV LRB, #00040h
                MOV X1, #003FAh
ram_set_dp:
                MOV DP, 00084h[X1]
                L A, #05555h
                CAL ram_readback_test
                SLL A
                CAL ram_readback_test
                SUB X1, #00002h
                JGE ram_set_dp
                MOV LRB, #00041h
                CMPB 0F5h, #047h
                JNE restore_trapstate_after_set_lrb
                MOV DP, #0031Dh
                LCB A, OptionUnused216Bit1
                JNE selftest_ram_test_ind_b0
                CLRB [DP]
                SJ selftest_ram_if_ram32_b4_clr
selftest_ram_test_ind_b0:
                MB C, [DP].0
                JGE selftest_ram_test_ramed_b3
                JBR off(0EDh).1, selftest_ram_test_ind_b1
                JBR off(0EDh).2, selftest_ram_test_ind_b1
selftest_ram_test_ramed_b3:
                MB C, off(0EDh).3
                MB [DP].0, C
selftest_ram_test_ind_b1:
                MB C, [DP].1
                JGE selftest_ram_test_ramee_b4
                JBR off(0EDh).1, selftest_ram_if_ram32_b4_clr
                JBR off(0EDh).2, selftest_ram_if_ram32_b4_clr
selftest_ram_test_ramee_b4:
                MB C, off(0EEh).4
                MB [DP].1, C
selftest_ram_if_ram32_b4_clr:
                JBR off(032h).4, cfgvariant_check_320h_bit7
                JBR off(032h).5, cfgvariant_check_320h_bit7
                CLR A
                LB A, r6
                CAL boot_quotient
                CMPB r6, #018h
                JEQ cfgvariant_index_lookup
                CAL fuel_state_init
                CAL engine_state_init
                CAL boot_lookup_c
                INC DP
                L A, er0
                ST A, [DP]
cfgvariant_index_lookup:
                CLR A
                LB A, r7
                LCB A, TroubleCodeNumbers[ACC]
                CMPB A, r6
                JEQ cfgvariant_and_ram32
                MOVB 0F5h, #043h
                BRK
cfgvariant_and_ram32:
                ANDB off(032h), #0CFh
cfgvariant_check_320h_bit7:
                MOV DP, #00320h
                RB [DP].7
                CAL boot_lookup
                JBR off(032h).2, cfgvariant_check_232h_bits01
                JBR off(032h).3, cfgvariant_check_232h_bits01
                CAL boot_lookup_b
                ANDB off(032h), #0F3h
cfgvariant_check_232h_bits01:
                JBR off(032h).0, restore_trapstate_after_set_lrb
                JBR off(032h).1, restore_trapstate_after_set_lrb
                CAL state_table_refresh
                ANDB off(032h), #0FCh
restore_trapstate_after_set_lrb:
                MOV LRB, #00010h
                MB C, off(0B7h).0
                MB r0.0, C
                MB C, off(0B7h).1
                MB r0.1, C
                MOVB r1, off(0AFh)
                MOVB r2, off(0F6h)
                MOVB r3, off(0F5h)
                CLR A
                MOV USP, #00356h
                MOV DP, #00480h
ram_dec_dp:
                DEC DP
                DEC DP
                ST A, [DP]
                CMP DP, off(086h)
                JGT ram_dec_dp
                CMP DP, #00098h
                JLE clear_0x324_high_nibble
                MOV USP, #00098h
                CMPB r3, #047h
                JNE ram_dec_dp
                MOV DP, #00300h
                SJ ram_dec_dp
clear_0x324_high_nibble:
                MOV DP, #00324h
                LB A, [DP]
                ANDB A, #0F0h
                STB A, [DP]
                MB C, r0.0
                MB off(0B7h).0, C
                MB C, r0.1
                MB off(0B7h).1, C
                MOVB off(0AFh), r1
                MOVB off(0F6h), r2
                MOVB off(0F5h), r3
                MOV LRB, #00041h
                SC
                LB A, 0AFh
                JNE fuelpump_prime_check
                MOVB off(0C6h), #014h
                RC
fuelpump_prime_check:
                MB off(030h).5, C
                MOV USP, #00180h
                CLR A
                ST A, IE
                MOV DP, A
                CLRB ADSEL
                MOVB ADSCAN, #010h
                RB IRQH.4
; Boot sensor scan: loops adc_channel_scan - each pass advances the analog mux (P2.5-7 +=
; 0x20), reads the A/D (ADCR0H/ADCR1H -> RAM 0x03CA/0x03D2 table) with a TM2 timeout (BRK 0x4A); the
; loop ends when the channel counter (P2.5-7) wraps to 0 (8 channels scanned).
boot_adc_scan:
                MB r0.0, C
                JRNZ DP, boot_adc_scan
                CAL adc_channel_scan
                LB A, P2
                ANDB A, #0E0h
                JNE boot_adc_scan
                MOVB 0F7h, #001h
                CAL adc_default_write
                L A, ADCR4
                ST A, 09Ch
                LB A, ADCR2H
                STB A, 0E1h
                MOV DP, #0037Bh
                STB A, [DP]
                MOV DP, #003CAh
                LB A, [DP]
                STB A, 0DAh
                MOV DP, #003D1h
                LB A, [DP]
                STB A, 0DBh
                MOVB 0D8h, #057h
                MOVB 0D9h, #03Bh
                MOVB 0BCh, #0F9h
                LB A, #01Fh
                STB A, 0DCh
                STB A, 0DDh
                STB A, 0DFh
                L A, ADCR6
                ST A, 0BAh
                LB A, ACCH
                MOV DP, #00376h
                STB A, [DP]
                LB A, #0A0h
                STB A, off(035h)
                STB A, -78[USP]
                STB A, 0BDh
                MOV DP, #00374h
                STB A, [DP]
                INC DP
                STB A, [DP]
                L A, #04D00h
                ST A, 0D0h
                ST A, 0D2h
                ST A, er0
                SLL A
                JLT clamp_load_imm
                SLL A
                LB A, ACCH
                JGE clamp_result_store_ramd4
clamp_load_imm:
                LB A, #0FFh
clamp_result_store_ramd4:
                STB A, 0D4h
                CAL timer_state_reinit
                CLR X1
                SB off(031h).5
                MOV 0CEh, #0FFFFh
                SB off(031h).3
                MOV 098h, #000E1h
                MOV 09Ah, #0091Fh
                L A, #00001h
                ST A, -108[USP]
                ST A, -110[USP]
                ST A, -112[USP]
                LB A, #00Fh
                STB A, -105[USP]
                STB A, 23[USP]
                LB A, 003D4h[X1]
                STB A, 00377h[X1]
                CAL fuel_table_init
                CLRB A
                MOV DP, #001D1h
clamp_result_rom_load_ind:
                LCB A, RamInitValues[DP]
                STB A, [DP]
                INC DP
                CMP DP, #001DEh
                JNE clamp_result_rom_load_ind
                MOVB 00397h[X1], #0FFh
                MOVB off(0FAh), #0F9h
                MOVB off(0BCh), #002h
                MOVB off(0BDh), #002h
                MOVB 00379h[X1], #053h
                LB A, 00310h[X1]
                MOVB ACC, #07Bh
                JNE boot_adc_scan_store_ind
                STB A, 00311h[X1]
boot_adc_scan_store_ind:
                STB A, 0037Ah[X1]
                SB off(025h).1
                CMPB 0F5h, #047h
                JEQ boot_adc_scan_set_ramc1
                MOVB 0031Ah[X1], #03Bh
boot_adc_scan_set_ramc1:
                MOVB off(0C1h), #032h
                MOVB r0, #01Ch
                MOVB r1, #08Ch
                LB A, #0DFh
                MOV DP, #00356h
                MB C, [DP].1
                JLT serial_baud_apply
                MOVB r0, #031h
                MOVB r1, #0A1h
                LB A, #0FBh
serial_baud_apply:
                STB A, STTM
                STB A, STTMR
                MOVB STTMC, #012h
                LB A, r0
                STB A, STCON
                LB A, r1
                STB A, SRCON
                MOV DP, #04700h
                LB A, [DP]
                XORB A, #01Ah
                STB A, off(011h)
                STB A, -103[USP]
                CLR A
                MOV DP, #003FCh
                LC A, 00038h
                ST A, [DP]
                INC DP
                INC DP
                LC A, 0003Ah
                ST A, [DP]
                CLRB 0F5h
                J state_verify
; (see the banner at the main-loop definition) - VCAL 3 periodic background task.
housekeeping_tick:
                MOV DP, #00356h
                MB C, [DP].1
                JLT vcal_4_set_dp
                J housekeeping_exit
vcal_4_set_dp:
                MOV DP, #00356h
                RB [DP].7
                JNE vcal_4_set_dp_2
housekeeping_tick_goto_housekeeping_exit:
                J housekeeping_exit
vcal_4_set_dp_2:
                MOV DP, #003F1h
                LB A, [DP]
                CMPB A, #020h
                JNE vcal_4_cmp_acc_imm
                L A, 0C4h
                MOV DP, #003A0h
                ST A, [DP]
                MOV DP, #003A6h
                L A, [DP]
                MOV DP, #003A2h
                ST A, [DP]
                MOV DP, #003F4h
                LB A, [DP]
                ADDB A, #003h
                J vcal_4_set_dp_4
vcal_4_cmp_acc_imm:
                CMPB A, #030h
                JLT vcal_4_cmp_acc_imm_2
                CMPB A, #036h
                JGT vcal_4_cmp_acc_imm_2
                CMPB A, #030h
                JEQ vcal_4_clear_acc
                JBR off(010h).7, vcal_4_clear_acc
                MOV DP, #003F0h
                CMPB A, [DP]
                JNE housekeeping_tick_set_dp
                MOV DP, #003AFh
                STB A, [DP]
vcal_4_load_imm:
                LB A, #028h
                SJ housekeeping_tick_set_dp_2
housekeeping_tick_set_dp:
                MOV DP, #003FAh
                LB A, [DP]
                JNE vcal_4_load_imm
vcal_4_clear_acc:
                CLRB A
                MOV DP, #003AFh
                STB A, [DP]
housekeeping_tick_set_dp_2:
                MOV DP, #003FAh
                STB A, [DP]
                SJ vcal_4_load_imm_2
vcal_4_cmp_acc_imm_2:
                CMPB A, #021h
                JNE housekeeping_tick_goto_housekeeping_exit
                MOV DP, #003F3h
                LB A, [DP]
                SRLB A
                JGE vcal_4_set_dp_3
                CLR A
                ST A, -102[USP]
                ST A, -100[USP]
                ST A, off(012h)
                ST A, off(014h)
                ST A, 0B0h
                ST A, 0B2h
                ST A, 0B4h
                CLRB A
                STB A, 0F4h
                STB A, off(0B3h)
                MOV DP, #0039Dh
                STB A, [DP]
                MOV DP, #001D1h
vcal_4_rom_load_ind:
                LCB A, RamInitValues[DP]
                STB A, [DP]
                INC DP
                CMP DP, #001DEh
                JNE vcal_4_rom_load_ind
                RB off(018h).6
                RB off(018h).7
                RB off(02Bh).4
                RB off(025h).7
                RB off(0ECh).2
                SB off(032h).2
                SB off(032h).3
                RB off(0EDh).2
                RB off(0EDh).1
                RB off(0EDh).3
                RB off(0EEh).4
                CAL boot_lookup_b
                RB off(032h).2
                RB off(032h).3
vcal_4_set_dp_3:
                MOV DP, #003F3h
                LB A, [DP]
                SRLB A
                SRLB A
                JGE vcal_4_load_imm_2
                SB off(032h).0
                SB off(032h).1
                CAL state_table_refresh
                RB off(032h).0
                RB off(032h).1
vcal_4_load_imm_2:
                LB A, #003h
vcal_4_set_dp_4:
                MOV DP, #003F2h
                STB A, [DP]
                MOV DP, #00356h
                SB [DP].6
                MOV DP, #003F5h
                LB A, #002h
                STB A, [DP]
                MOV DP, #003F1h
                LB A, [DP]
                ANDB A, #01Fh
                MOV DP, #003F6h
                STB A, [DP]
                STB A, STBUF
; Housekeeping exit: restore IE from 0FAh, serial-rate countdown 09Eh (wrap at 5), 0B6h.4/02Bh.0/031h.0
; flag checks, then RT (return to the caller - the engine interrupt) or J inj_phase_rotate (0x2CA3)
; when 02Bh.0 is set.
housekeeping_exit:
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                LB A, 09Eh
                SUBB A, #005h
                JLT housekeeping_exit_or_pswh
                STB A, 09Eh
housekeeping_exit_or_pswh:
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                JGE sensor_tick
                RB -86[USP].2
                MB C, 0B6h.4
                JGE sensor_task_dispatch
                JBR off(02Bh).0, vcal3_task_a
                RB off(031h).0
                JNE vcal3_task_a
                RB 0B6h.4
                RT
vcal3_task_a:
                J inj_phase_rotate
; Dispatch at the loop tail: 031h.1 (set every 10th sensor_tick) -> fault_recovery_a (0x34F0); 031h.2
; (set by housekeeping) -> fault_recovery_b (0x35C9); otherwise clear 031h.2 and RT (skipped).
sensor_task_dispatch:
                RB off(031h).1
                JEQ vcal3_dispatch_check2
                J fault_recovery_a
vcal3_dispatch_check2:
                RB off(031h).2
                JNE vcal3_task_b
                RT
vcal3_task_b:
                J fault_recovery_b
; Work done on every housekeeping tick: wdt_kick + ADC channel advance, three atomic
; expected-state word updates (atomic_ram_update: RAM 0x09 <- 0x01C8, 0x0B <- 0x02F4, 0x04 <- 0x03F7),
; sample countdown 0B4h, RAM test pointer 03FAh management (window words from ROM 0x0038/0x003A),
; PSW-expected 0FAh defaulted to 0xFA, then divide-by-10: every 10th tick sets 031h.1 (sensor_task_
;dispatch) and runs the ECT -> fan output (P0.6, 0D9h signed zero test, 024h.7) and the VSS speed
;update (0CCh, cold path when 0D2h/0C5h say so, 0x72FA cold scale).
sensor_tick:
                CAL wdt_kick
                MOV DP, #00009h
                MOV X1, #001C8h
                CAL atomic_ram_update
                MOV DP, #0000Bh
                MOV X1, #002F4h
                CAL atomic_ram_update
                MOV DP, #00004h
                MOV X1, #003F7h
                CAL atomic_ram_update
                DECB off(0B4h)
                MOV DP, #003FAh
                LB A, [DP]
                JNE scheduler_slowflag_check
                MOV DP, #003AFh
                STB A, [DP]
scheduler_slowflag_check:
                CLR A
                LB A, off(0FAh)
                JNE scheduler_divider_check
                LB A, #0FAh
                STB A, off(0FAh)
                MB C, off(031h).7
                XORB PSWH, #080h
                MB off(031h).7, C
                JLT scheduler_divider_check
                SB off(031h).2
scheduler_divider_check:
                MOVB r0, #00Ah
                DIVB
                LB A, r1
                JNE scheduler_task_done
                SB off(031h).1
                JBR off(016h).5, scheduler_gate_common
                L A, off(014h)
                AND A, #00320h
                JNE scheduler_gate_common
                L A, off(012h)
                AND A, #001BCh
                JNE scheduler_gate_common
                JBR off(01Ah).6, scheduler_gate_common
                JBS off(01Ah).7, scheduler_gate_common
                LB A, 0D9h
                CMPB A, #000h
                JLE scheduler_ect_sign_check
                CMPB A, #000h
                JGE scheduler_ect_sign_check
                XORB P0, #040h
                RB off(024h).7
                SJ scheduler_task_done
scheduler_gate_common:
                SB P0.6
                SB off(024h).7
                SJ scheduler_task_done
scheduler_ect_sign_check:
                RB P0.6
                RB off(024h).7
scheduler_task_done:
                MOV DP, #000CEh
                JBS off(014h).0, vss_calc_skip
                RB 0B6h.2
                JEQ vss_calc_gate2
                JBS off(017h).5, vss_calc_gate3
                CMPB 0DBh, #044h
                JLE vss_calc_skip
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                MOVB r0, 0AAh
                L A, 0A8h
                SUB A, 0ACh
                ST A, er1
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                SBCB r0, #000h
                SRLB r0
                L A, er1
                ROR A
                CMPB r0, #000h
                JNE vss_calc_gate3
                RB off(031h).3
                JNE vss_calc_gate2_load_imm
                RB off(031h).4
                JNE vss_calc_gate2_load_imm
                CMP A, #00373h
                MB off(031h).4, C
                JLT vss_calc_gate2_load_imm
                CMP A, #0397Dh
                JGE vss_result_store_ind
                MOV er0, #01000h
                CMP A, #005C0h
                JLT vss_scale_apply
                MOV er0, #04000h
vss_scale_apply:
                CAL speed_scale
vss_result_store_ind:
                ST A, [DP]
                ST A, er2
                MOV er0, #00003h
                L A, #05E59h
                DIV
                ST A, er1
                L A, er0
                JNE vss_clamp_max
                LB A, r3
                JEQ vss_clamp_common
vss_clamp_max:
                MOVB r2, #0FFh
vss_clamp_common:
                LB A, r2
vss_final_store_r2:
                STB A, r2
                MOVB r3, 0CCh
                L A, er1
                ST A, 0CCh
                SJ vss_calc_gate2_load_imm
vss_calc_skip:
                L A, #072FAh
                RB off(031h).3
                SJ vss_result_store_ind
vss_calc_gate2:
                LB A, #003h
                CMPB 0ABh, A
                JLT vss_calc_gate2_load_imm
                STB A, 0ABh
vss_calc_gate3:
                RB off(031h).4
                SB off(031h).3
                MOV [DP], #0FFFFh
                CLRB A
                SJ vss_final_store_r2
vss_calc_gate2_load_imm:
                LB A, #005h
                JBS off(01Ah).2, sensor_tick_cmp_acc_ramcc
                LB A, #007h
sensor_tick_cmp_acc_ramcc:
                CMPB A, 0CCh
                MB off(01Ah).2, C
                JBR off(027h).6, idle_gate1_rc
                JBS off(014h).7, idle_gate1_rc
                MOV DP, #00F00h
                MB C, [DP].2
                RB off(032h).6
                MB off(032h).6, C
                JEQ idle_gate1
                XORB PSWH, #080h
idle_gate1:
                JGE idle_gate1_timer_check
                CMPB 0C5h, #00Dh
                JGT idle_gate1_trigger
                JBS off(033h).7, idle_gate1_timer_check
idle_gate1_trigger:
                MOVB off(0FCh), #00Ah
idle_gate1_rc:
                RC
                SJ dtc24_code24_latch
idle_gate1_timer_check:
                LB A, off(0FCh)
                JNE idle_gate1_rc
                SC
dtc24_code24_latch:
                MB 0B2h.3, C
                RB -86[USP].2
                CAL adc_channel_scan
                JBR off(027h).1, sensor_tick_clear_x2
                CAL serial_word_init
                CAL serial_word_set
sensor_tick_clear_x2:
                CLR X2
                MOV er0, 0039Ah[X2]
                CLR A
                LB A, #040h
                MUL
                MOV X1, A
                MOV DP, #00020h
                MOVB r0, 0039Ch[X2]
idle_init_start_rom_load_ind:
                LC A, [X1]
                ADDB A, ACCH
                ADDB r0, A
                INC X1
                INC X1
                JRNZ DP, idle_init_start_rom_load_ind
                LB A, r0
                STB A, 0039Ch[X2]
                INC 0039Ah[X2]
                CMP 0039Ah[X2], #00200h
                JNE idle_mode_gate2
                CLR 0039Ah[X2]
                LB A, r0
                JEQ idle_mode_gate2
                CLRB 0039Ch[X2]
                LCB A, OptionFlagsFromBytes
                JNE idle_mode_gate2
                MOVB 0F5h, #048h
                J fault_giveup_latch
idle_mode_gate2:
                JBR off(027h).1, sensor_tick_clear_r2
                CAL serial_word_init
                CAL serial_word_set
sensor_tick_clear_r2:
                CLRB r2
                JBR off(027h).1, sensor_tick_goto_next
                JBR off(016h).3, sensor_tick_goto_next
                JBR off(027h).2, sensor_tick_goto_next
                LB A, off(056h)
                JEQ sensor_tick_test_ram2c_b0
                CMPB A, #0FFh
                JEQ sensor_tick_test_ram2c_b0
                CMPB A, #0AAh
                JEQ sensor_tick_test_ram2c_b0
                CMPB A, #055h
                JNE sensor_tick_load_imm
sensor_tick_test_ram2c_b0:
                MB C, off(02Ch).0
                MB off(02Ch).1, C
                MB C, off(02Ch).2
                MB off(02Ch).3, C
                RORB A
                MB off(02Ch).0, C
                RORB A
                MB off(02Ch).2, C
sensor_tick_load_imm:
                LB A, #0FFh
                JBS off(02Ch).5, sensor_tick_cmp_acc_ram36
                LB A, #0FFh
sensor_tick_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(02Ch).5, C
                RB PSWL.4
                JBS off(02Ch).4, sensor_tick_if_ram2c_b2_set
                JBR off(0ECh).2, sensor_tick_cmp_ramd9_imm
                SB PSWL.4
                JBS off(015h).5, sensor_tick_set_ramfe
                JBS off(015h).6, sensor_tick_set_ramfe
                MOV DP, #003F8h
                LB A, off(0D1h)
                JEQ sensor_tick_load_ind
                MOVB [DP], #000h
                SJ sensor_tick_set_ramfe
sensor_tick_load_ind:
                LB A, [DP]
                JNE sensor_tick_clear_pswl_b4
                MOVB off(0D1h), #000h
                SJ sensor_tick_set_ramfe
sensor_tick_clear_pswl_b4:
                RB PSWL.4
                SJ sensor_tick_set_ramfe
sensor_tick_cmp_ramd9_imm:
                CMPB 0D9h, #000h
                JGE sensor_tick_set_ramfe
                JBR off(02Ch).5, sensor_tick_set_ramfe
sensor_tick_if_ram2c_b2_set:
                JBS off(02Ch).2, sensor_tick_if_ram2c_b0_set
                JBR off(02Ch).4, sensor_tick_set_ramfe
                JBR off(02Ch).0, sensor_tick_load_ramaa
                MOVB r2, #0FFh
                LB A, #0FFh
                SJ sensor_tick_store_ramaa
sensor_tick_goto_next:
                SJ sensor_tick_set_ram45
sensor_tick_set_pswl_b4:
                SB PSWL.4
sensor_tick_load_ramaa:
                LB A, off(0AAh)
                ADDB A, off(045h)
                JLT sensor_tick_clear_ram2c_b4
                STB A, r2
                SJ sensor_tick_test_pswl_b4
sensor_tick_set_ramfe:
                MOVB off(0FEh), #000h
sensor_tick_clear_ram2c_b4:
                RB off(02Ch).4
                SJ sensor_tick_test_pswl_b4
sensor_tick_if_ram2c_b0_set:
                JBS off(02Ch).0, sensor_tick_load_ram45
                JBR off(02Ch).4, sensor_tick_set_ramfe
                LB A, 0CCh
                MOV X1, #VTECRpmLoadAuto+2
                CAL interp_word
                STB A, r2
                LB A, 0CCh
                MOV X1, #059ACh
                CAL interp_word
                SJ sensor_tick_store_ramaa
sensor_tick_load_ram45:
                LB A, off(045h)
                JEQ sensor_tick_set_r2
                CMPB A, #0FFh
                JLT sensor_tick_set_pswl_b4
sensor_tick_set_r2:
                MOVB r2, #0FFh
                LB A, #0FFh
                SB off(02Ch).4
sensor_tick_store_ramaa:
                STB A, off(0AAh)
                SB PSWL.4
sensor_tick_test_pswl_b4:
                MB C, PSWL.4
                MB P0.4, C
                LB A, off(0FEh)
                JEQ sensor_tick_clear_ram2c_b4_2
                LB A, 36[USP]
                JNE sensor_tick_clear_r2_2
                SJ sensor_tick_set_ram45
sensor_tick_clear_ram2c_b4_2:
                RB off(02Ch).4
sensor_tick_clear_r2_2:
                CLRB r2
sensor_tick_set_ram45:
                MOVB off(045h), r2
                JBR off(027h).1, sensor_tick_set_ind
                JBR off(016h).3, sensor_tick_set_ind
                JBR off(027h).2, sensor_tick_set_ind
                JBS off(015h).5, sensor_tick_set_ind
                JBS off(015h).6, sensor_tick_set_ind
                JBS off(017h).5, sensor_tick_set_ind
                CMPB 0DBh, #0FFh
                JLT sensor_tick_set_ind
                JBS off(02Ch).0, sensor_tick_if_ram2c_b2_clr
                RB 0B2h.4
                JBR off(02Ch).2, sensor_tick_clear_ramb2_b5
                SB 0B2h.5
                JBS off(02Ch).3, idle_mode_gate2_2
                SB 0B4h.4
                SJ idle_mode_gate2_2
sensor_tick_if_ram2c_b2_clr:
                JBR off(02Ch).2, sensor_tick_set_ramb2_b4
sensor_tick_set_ind:
                MOVB 85[USP], #0FFh
                MOVB 86[USP], #0FFh
                RB 0B2h.4
sensor_tick_clear_ramb2_b5:
                RB 0B2h.5
                SJ idle_mode_gate2_2
sensor_tick_set_ramb2_b4:
                SB 0B2h.4
                RB 0B2h.5
                JBS off(02Ch).1, idle_mode_gate2_2
                SB 0B4h.5
idle_mode_gate2_2:
                JBR off(0B4h).0, idle_mode_gate2_load_ram98
                J transit_flag_check
idle_mode_gate2_load_ram98:
                L A, 098h
                MOV X1, #IdleDuty
                CAL interp_table
                MOV er0, 09Ch
                MUL
                SLL A
                L A, er1
                ROL A
                JGE idle_dc_result_set_dp
                L A, #0FFFFh
idle_dc_result_set_dp:
                MOV DP, #00382h
                ST A, [DP]
                MOV er3, off(090h)
                SUB A, off(05Ch)
                MB r4.0, C
                JEQ idle_delta_flag_sc
                RB off(025h).6
                MB off(025h).6, C
                JEQ idle_delta_flag_check
                XORB PSWH, #080h
idle_delta_flag_check:
                JGE idle_delta_flag_r4_b1
idle_delta_flag_sc:
                SC
idle_delta_flag_r4_b1:
                MB r4.1, C
                MOV X1, #000E1h
                MOV X2, #0091Fh
                JBR off(00Ch).0, idle_helper2_call1
                VCAL 7
idle_helper2_call1:
                ST A, er0
                L A, #005A0h
                CAL accum_loop_b
                MOV DP, A
                L A, #00118h
                CMPB 68[USP], #004h
                JGE sensor_tick_call_accum_loop_b
                L A, #015E0h
sensor_tick_call_accum_loop_b:
                CAL accum_loop_b
                XCHG A, 098h
                ST A, er0
                CLRB A
                JGE sensor_tick_load_dp
                JBR off(00Ch).1, sensor_tick_store_ind
                SJ idle_step_default
sensor_tick_load_dp:
                L A, DP
                ST A, off(090h)
                L A, er0
                CMP A, 098h
                JEQ idle_step_default
                JBR off(00Ch).1, idle_debounce_gate
idle_step_default:
                LB A, #00Ah
sensor_tick_store_ind:
                STB A, 68[USP]
idle_debounce_gate:
                MB C, 0B7h.1
                JLT idle_debounce_disabled
                JBR off(030h).2, idle_debounce_skip
                MOV DP, #01F00h
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                LB A, P0
                STB A, [DP]
                STB A, r0
                MOVB r1, [DP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                LB A, r1
                CMPB A, r0
                JNE idle_port_p1_check
                MOV DP, #02F00h
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                LB A, P1
                STB A, [DP]
                STB A, r0
                MOVB r1, [DP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                LB A, r1
                CMPB A, r0
                JEQ sensor_tick_set_dp
idle_port_p1_check:
                LB A, #04Dh
                STB A, 0AFh
                DECB 0F7h
                JNE idle_debounce_skip
                STB A, 0F5h
                CLRB 0F6h
                J trap_retry_check
idle_debounce_skip:
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                CAL inj_init_pattern
                ORB PSWH, #001h
                SJ idle_debounce_ie_restore
sensor_tick_set_dp:
                MOV DP, #00F00h
                LB A, [DP]
                XORB A, #038h
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                STB A, off(010h)
                STB A, -104[USP]
                ORB PSWH, #001h
idle_debounce_ie_restore:
                L A, 0F8h
                ST A, IE
idle_debounce_disabled:
                MOV DP, #04700h
                LB A, [DP]
                XORB A, #01Ah
                MB C, off(011h).4
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                STB A, off(011h)
                STB A, -103[USP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                JGE idle_debounce_return
                JBS off(011h).4, idle_debounce_return
                MOVB off(0D9h), #014h
idle_debounce_return:
                RT
transit_flag_check:
                LB A, #0FFh
                MOV DP, #00397h
                RB TRNSIT.3
                JNE transit_flag_common
                SC
                LB A, [DP]
                JEQ transit_flag_ram30_b6
                SUBB A, #001h
transit_flag_common:
                RC
transit_flag_ram30_b6:
                MB off(030h).6, C
                STB A, [DP]
                JBR off(0B4h).1, transit_gate_check
                RT
transit_gate_check:
                MOV DP, #000DEh
                LB A, 0DCh
                STB A, ACCH
                CLRB A
                JBS off(014h).3, idle_scratch_set_ind
                MB C, 0B1h.7
                JLT idle_task_done
                CMPB 0F3h, #032h
                JGE idle_scratch_scale
idle_scratch_set_ind:
                MOV [DP], A
                SJ idle_task_done
idle_scratch_scale:
                MOV er0, #02400h
                CAL speed_scale
idle_task_done:
                SB off(031h).0
                RT
; Injector bank phase rotation: shifts the sequencing bits 02Bh.2/.3, 01Ah.4, 010h.3, 011h.2/.5
; (the sequential-injection bank pattern used by inj_pulse_engine).
inj_phase_rotate:
                MB C, off(02Bh).2
                MB off(02Bh).3, C
                CLRB A
                MB C, off(01Ah).4
                ROLB A
                MB C, off(010h).3
                ROLB A
                MB C, off(011h).2
                ROLB A
                MB C, off(011h).5
                ROLB A
                STB A, r0
                XORB A, off(029h)
                ANDB A, #00Fh
                SWAPB
                ORB A, r0
                STB A, off(029h)
                LB A, 0DCh
                STB A, r0
                XCHGB A, 0DDh
                SUBB A, r0
                MB off(025h).2, C
                JGE inj_phase_rotate_store_rame0
                VCAL 6
inj_phase_rotate_store_rame0:
                STB A, 0E0h
                MOVB r0, 0DFh
                LB A, #03Ah
                JBS off(02Ah).4, inj_phase_rotate_cmp_r0_acc
                LB A, #023h
inj_phase_rotate_cmp_r0_acc:
                CMPB r0, A
                MB off(02Ah).4, C
                LB A, #064h
                JBS off(02Ah).5, inj_phase_rotate_cmp_r0_acc_2
                LB A, #04Ch
inj_phase_rotate_cmp_r0_acc_2:
                CMPB r0, A
                MB off(02Ah).5, C
                LB A, #044h
                JBS off(02Ah).6, inj_phase_rotate_cmp_r0_acc_3
                LB A, #030h
inj_phase_rotate_cmp_r0_acc_3:
                CMPB r0, A
                MB off(02Ah).6, C
                LB A, #0FFh
                JBS off(02Ah).0, battery_voltage_check_cmp_acc_rame1
                LB A, #0FFh
battery_voltage_check_cmp_acc_rame1:
                CMPB A, 0E1h
                MB off(02Ah).0, C
                LB A, #0B0h
                JBS off(02Ah).1, inj_phase_rotate_cmp_acc_rame1
                LB A, #0C0h
inj_phase_rotate_cmp_acc_rame1:
                CMPB A, 0E1h
                MB off(02Ah).1, C
                LB A, #060h
                JBS off(02Ah).2, inj_phase_rotate_cmp_acc_ram36
                LB A, #06Dh
inj_phase_rotate_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(02Ah).2, C
                LB A, #0CDh
                JBS off(02Ah).3, inj_phase_rotate_cmp_acc_ram36_2
                LB A, #0D0h
inj_phase_rotate_cmp_acc_ram36_2:
                CMPB A, off(036h)
                MB off(02Ah).3, C
                LB A, 0D9h
                STB A, r0
                MOVB r1, #03Ch
                CMPB A, r1
                JGE inj_phase_rotate_load_r0
                LB A, #050h
                CMPB 0D8h, #030h
                JGE inj_phase_rotate_cmp_acc_ramf3
                LB A, #096h
inj_phase_rotate_cmp_acc_ramf3:
                CMPB A, 0F3h
                JLT inj_phase_rotate_load_r0
                L A, #007F6h
                MOV er3, #00600h
                SJ ign_advance_corr
inj_phase_rotate_load_r0:
                LB A, r0
                MOV X1, #05BA7h
                J ign_dispatch_warm_set_r1
                DB  000h
; Ignition advance scaling: thresholds 0x16 (22) / r1 (0x34) selects the 0x08D3/0x0360 scale and
; ign_advance_corr; 017h.6 flag gates the correction path.
ign_advance_scale:
                CMPB A, #016h
                JGE ign_advance_scale_cmp_acc_r1
ign_advance_scale_load_imm:
                L A, #008D3h
                MOV er3, #00360h
                J ign_dispatch_warm_if_ram16_b3_set
ign_advance_scale_cmp_acc_r1:
                CMPB A, r1
                JGE idle_ectvs_result3
                JBS off(017h).6, freezeframe_flag_if_ram2a_b4_clr
                CMP off(072h), #08000h
                JGE ign_advance_scale_goto_next
                CMP off(072h), #00C00h
                JBS off(016h).3, ign_advance_scale_branch
                CMP off(072h), #00C00h
ign_advance_scale_branch:
                JGE ign_advance_scale_load_imm
ign_advance_scale_goto_next:
                J timer_state_reinit_set_r1
ign_advance_scale_load_imm_2:
                L A, #009C4h
                MOV er3, #00120h
                SJ ign_advance_corr
freezeframe_flag_if_ram2a_b4_clr:
                JBR off(02Ah).4, ign_advance_scale_if_ram25_b1_clr
                MOVB off(0DBh), #014h
                SJ ign_advance_scale_load_imm
ign_advance_scale_if_ram25_b1_clr:
                JBR off(025h).1, ign_advance_scale_nop
                CMPB off(0DBh), #000h
                JNE ign_advance_scale_load_imm
ign_advance_scale_nop:
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
                JBR off(016h).3, ign_advance_scale_set_r1
                MOVB r1, #02Dh
                LB A, r0
                CMPB A, r1
                JGE idle_ectvs_result3
                L A, #009C4h
                MOV er3, #00120h
                JBS off(011h).5, ign_advance_corr
ign_advance_scale_set_r1:
                MOVB r1, r2
                LB A, r0
                CMPB A, r1
                JGE idle_ectvs_result3
                J ign_dispatch_warm_load_ram7a
idle_ectvs_result3:
                LB A, r0
                VCAL 0
                CLR er3
; Ignition advance correction: the 0x05BA7 correction table (index + 0x0F) with r4/r0 offsets and the
; 0x08D3/0x0360 scale; result goes back to ign_dispatch_warm.
ign_advance_corr:
                MOV DP, A
                L A, er3
                JEQ to_idle_step_condition_dispatch
                MOV X1, #05BA7h
                LCB A, 0000Fh[X1]
                MOVB r4, A
                SUBB r0, A
                L A, er3
                JLE to_idle_step_condition_dispatch
                CLRB A
                STB A, r5
                XCHGB A, r1
                CMPB A, 0D9h
                JLE ign_advance_corr_clear_acc
                XCHGB A, r4
                SUBB r4, A
                JLE ign_advance_corr_clear_acc
                CLR A
                CAL scale_div
                SJ to_idle_step_condition_dispatch
ign_advance_corr_clear_acc:
                CLR A
to_idle_step_condition_dispatch:
                ST A, off(078h)
                L A, DP
                ST A, off(05Ah)
                MOV X1, #SelfTestValues+32
                CAL interp_table
                MOV X2, A
                MOV X1, #SelfTestValues+60
                L A, off(05Ah)
                CAL interp_table
                MOV er2, X2
                MOVB r5, r6
                MOV off(094h), er2
                MB C, off(01Ah).0
                MB off(0EEh).1, C
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
                MOV DP, #00386h
                JBR off(017h).5, to_idle_step_condition_dispatch_2
                CLR [DP]
ign_advance_corr_goto_next:
                J timer_state_reinit_set_ramd6
                DB  000h
ign_advance_corr_sc:
                SC
                SJ ign_advance_corr_flag_ram1a_b0
to_idle_step_condition_dispatch_2:
                J state_if_ram1a_b0_clr
idle_step_flag_load_ramd9:
                LB A, 0D9h
                MOV X1, #SelfTestValues+88
                VCAL 0
                L A, off(05Ah)
                SUB A, er3
                JGE ign_advance_corr_cmp_acc_ramc4
                CLR A
ign_advance_corr_cmp_acc_ramc4:
                CMP A, 0C4h
                J ve_result_flag_branch
ign_advance_corr_add_acc:
                ADD A, #00008h
                JGE ign_advance_corr_store_ind
                L A, #0FFFFh
ign_advance_corr_store_ind:
                ST A, [DP]
                SJ ign_advance_corr_goto_next
                DB  000h,000h,000h,000h
ign_advance_corr_rc:
                RC
ign_advance_corr_flag_ram1a_b0:
                MB off(01Ah).0, C
                L A, off(05Ah)
                MOV X1, #05CE0h
                MOV X2, #IdleIntegralGainHigh3
                CMP A, #00000h
                JLT idle_pid_table_select2
                MOV X1, #05CD4h
                MOV X2, #IdleIntegralGainHigh2
                CMP A, #00928h
                JLT idle_pid_table_select2
                MOV X1, #05CC8h
                MOV X2, #IdleIntegralGainHigh1
idle_pid_table_select2:
                JBS off(017h).6, idle_pid_table_lookup
                MOV X1, #05CF8h
                MOV X2, #IdleIntegralGainAutoD
                CMP A, #00928h
                JLT idle_pid_table_lookup
                MOV X1, #05CECh
                MOV X2, #IdleIntegralGainAutoC
idle_pid_table_lookup:
                LB A, off(036h)
                CAL interp_word
                MOVB r0, 0E1h
                MULB
                L A, ACC
                ROL A
                LB A, ACCH
                JGE idle_pid_mul_apply
                LB A, #0FFh
idle_pid_mul_apply:
                MOV X1, X2
                VCAL 0
                MOV DP, #0037Ch
                MOVB r1, [DP]
                CLRB r0
                MUL
                ROLB A
                L A, er1
                ROL A
                JGE ign_advance_corr_test_p0_b2
                L A, #0FFFFh
ign_advance_corr_test_p0_b2:
                MB C, P0.2
                JGE idle_pid_store_er3
                MOVB r1, #040h
                CLRB r0
                MUL
                L A, er1
idle_pid_store_er3:
                ST A, er3
                JBS off(02Bh).4, idle_pid_common
                MOVB r1, #021h
                JBS off(0EDh).0, ign_advance_corr_if_ram11_b2_set
                JBS off(025h).1, ign_advance_corr_load_ram99
ign_advance_corr_if_ram11_b2_set:
                JBS off(011h).2, idle_pid_common
                JBS off(02Ah).0, idle_pid_common
                LB A, #028h
                CLRB r1
                JBS off(02Bh).5, idle_pid_recheck2
                LB A, #028h
                MOVB r1, #021h
idle_pid_recheck2:
                MOVB r2, 0E2h
                MB C, off(02Bh).5
                JBR off(017h).6, ign_advance_corr_flag_pswl_b4
                LB A, #020h
                CLRB r1
                JBS off(025h).2, ign_advance_corr_set_r2
                LB A, #032h
                MOVB r1, #021h
ign_advance_corr_set_r2:
                MOVB r2, 0E0h
                MB C, off(025h).2
ign_advance_corr_flag_pswl_b4:
                MB PSWL.4, C
                CMPB A, r2
                JGE idle_pid_common
                MB C, PSWL.4
                JLT ign_advance_corr_test_p0_b2_2
ign_advance_corr_load_ram99:
                LB A, off(099h)
                JEQ ign_advance_corr_set_ram99
                SJ idle_pid_flag_clear_r5
ign_advance_corr_test_p0_b2_2:
                MB C, P0.2
                JLT idle_pid_flag_clear_r5
ign_advance_corr_set_ram99:
                MOVB off(099h), r1
idle_pid_flag_clear_r5:
                CLRB r5
                SJ idle_pid_diff_calc
idle_pid_common:
                L A, off(066h)
                XCHG A, er3
                MOVB r5, off(093h)
                CLRB r4
                MOVB r1, #040h
                JBS off(017h).6, idle_pid_track_clear_r0
                MOVB r1, #040h
idle_pid_track_clear_r0:
                CLRB r0
                CAL mul8_shift
                ST A, er3
idle_pid_diff_calc:
                L A, er3
                SUB A, off(066h)
                ST A, er0
                JGE idle_pid_diff_clamp
                VCAL 7
idle_pid_diff_clamp:
                CMP A, #00030h
                JBS off(017h).6, idle_pid_diff_zero
                CMP A, #00030h
idle_pid_diff_zero:
                CLR A
                JLT idle_pid_diff_store_ram68
                L A, er0
idle_pid_diff_store_ram68:
                ST A, off(068h)
                L A, off(076h)
                SUB A, #00030h
                JGE idle_pid_flag_recheck
                CLR A
idle_pid_flag_recheck:
                CMPB off(099h), #000h
                JEQ idle_pid_set_ram66
                L A, #00200h
                JBS off(017h).6, idle_pid_decrement
                L A, #00200h
idle_pid_decrement:
                DECB off(099h)
idle_pid_set_ram66:
                MOV off(066h), er3
                ST A, off(076h)
                MOVB off(093h), r5
                MB C, off(025h).1
                MB off(0EDh).0, C
                JBR off(026h).4, idle_integrator_check2
                MOV X1, #05D68h
                JBS off(016h).3, to_idle_integrator_load_ramd8
                MOV X1, #05D77h
to_idle_integrator_load_ramd8:
                LB A, 0D8h
                VCAL 0
                SLLB A
                MOV X2, A
                MOV X1, #05D86h
                LB A, off(036h)
                CAL interp_word
                L A, er3
                SWAP
                CLRB A
                MOV er0, X2
                MUL
                MOV DP, #00380h
                L A, off(080h)
                JEQ idle_integrator_reset
                JBS off(081h).7, idle_integrator_reset
                L A, [DP]
                SUB A, #00010h
                JGE idle_integrator_store_ind
                CLR A
                SJ idle_integrator_store_ind
idle_integrator_reset:
                L A, #00200h
idle_integrator_store_ind:
                ST A, [DP]
                ADD A, er1
                CMP A, #08000h
                JLT idle_integrator_final_store_ram80
                L A, #07FFFh
                SJ idle_integrator_final_store_ram80
idle_integrator_check2:
                L A, off(080h)
                JEQ idle_integrator_final_store_ram80
                JBR off(081h).7, idle_integrator_fault
                ADD A, #00010h
                JGE idle_integrator_final_store_ram80
                CLR A
                SJ idle_integrator_final_store_ram80
idle_integrator_fault:
                L A, #00280h
                VCAL 7
idle_integrator_final_store_ram80:
                ST A, off(080h)
                CLR A
                MOV DP, A
                JBR off(016h).3, to_idle_output_finalize
                JBR off(011h).5, idle_integrator_final_cmp_ramd9_imm
                CMPB 0D9h, #0FFh
                JLT ign_advance_corr_clear_acc_2
                L A, off(074h)
                SUB A, #03FFFh
                JGE idle_output_finalize
ign_advance_corr_clear_acc_2:
                CLR A
to_idle_output_finalize:
                MOVB off(0D7h), #0FFh
                SJ idle_output_finalize
idle_integrator_final_cmp_ramd9_imm:
                CMPB 0D9h, #0FFh
                JLT inc_dp_step_load_ramd9
                LB A, off(0D7h)
                JEQ inc_dp_step
                JBS off(01Bh).6, idle_integrator_final_load_ram74
                CMP 0C6h, #0FFFFh
                JGE inc_dp_step
idle_integrator_final_load_ram74:
                L A, off(074h)
                JEQ idle_output_finalize_srl_dp
inc_dp_step:
                INC DP
inc_dp_step_load_ramd9:
                LB A, 0D9h
                MOV X1, #05D90h
                VCAL 0
                MOV X2, A
                CMPB 0D9h, #000h
                JGE load_x2_result
                MOV X1, #IdleIntegratorTarget
                L A, off(05Ah)
                CAL interp_table
                CMP A, X2
                JGE idle_output_finalize
load_x2_result:
                L A, X2
idle_output_finalize:
                ST A, off(074h)
idle_output_finalize_srl_dp:
                SRL DP
                MB off(025h).3, C
                CLRB A
                RC
                JBS off(017h).5, idle_pid_result_flag_ram2b_b2
                JBR off(02Bh).2, idle_pid_gate4
                JBR off(010h).3, idle_pid_gate5
                MOV X1, #00680h
                LB A, off(097h)
                JEQ idle_pid_x1_select
                DECB off(097h)
                MOV X1, #00A00h
idle_pid_x1_select:
                L A, X1
                SJ idle_pid_output_store_ram7a
idle_pid_gate4:
                JBS off(010h).3, idle_pid_zero_flag
idle_pid_gate5:
                SC
                LB A, #008h
idle_pid_result_flag_ram2b_b2:
                MB off(02Bh).2, C
                STB A, off(097h)
idle_pid_zero_flag:
                CLR A
idle_pid_output_store_ram7a:
                ST A, off(07Ah)
                MOV X1, #05DD0h
                LB A, off(036h)
                VCAL 0
                MOV DP, A
                MOV X1, #IdleElectricalLoadCorrection
                JBS off(016h).3, vcal2_scale_multiply
                MOV X1, #IdleElectricalLoadCorrectionAuto
vcal2_scale_multiply:
                LB A, 0D5h
                VCAL 2
                STB A, r0
                CLR A
                LB A, #080h
                JBS off(016h).3, ign_advance_corr_load_acc
                LB A, off(04Fh)
                LCB A, IdleElectricalLoadCorrectionAuto+5[ACC]
ign_advance_corr_load_acc:
                L A, ACC
                SWAP
                MUL
                SLL A
                L A, er1
                ROL A
                JGE ign_advance_corr_store_er3
                L A, #0FFFFh
ign_advance_corr_store_er3:
                ST A, er3
                LB A, off(0F5h)
                MOV A, off(06Ah)
                JNE idle_sub_gate2
                MOVB off(0F5h), #003h
                JBR off(01Ah).2, idle_sub_common
                JBS off(01Bh).1, idle_sub_diff_calc
                ADD A, er3
                JLT idle_sub_alt_path
                SJ idle_sub_range_check1
idle_sub_diff_calc:
                SUB A, er3
                JLT idle_sub_common
idle_sub_range_check1:
                MOV X2, #00400h
                CMP A, #00A00h
                JGE idle_sub_range_result
                MOV X2, #00300h
                CMP A, #00400h
                JGE idle_sub_range_result
                MOV X2, #00200h
idle_sub_range_result:
                SUB A, X2
                JGE idle_sub_gate2
idle_sub_common:
                CLR A
idle_sub_gate2:
                JBS off(016h).3, ign_advance_corr_cmp_acc_dp
                JBR off(01Ah).2, ign_advance_corr_cmp_acc_dp
                JBR off(018h).2, ign_advance_corr_cmp_acc_dp
                MOV X2, A
                MOV X1, #05DDFh
                JBR off(011h).2, ign_advance_corr_load_ram36
                MOV X1, #05DEEh
ign_advance_corr_load_ram36:
                LB A, off(036h)
                VCAL 0
                L A, X2
                CMP A, er3
                JGE ign_advance_corr_cmp_acc_dp
                L A, er3
ign_advance_corr_cmp_acc_dp:
                CMP A, DP
                JLT idle_sub_alt_path_store_ram6a
idle_sub_alt_path:
                L A, DP
idle_sub_alt_path_store_ram6a:
                ST A, off(06Ah)
                MB C, off(02Bh).6
                MB off(02Bh).7, C
                MOV DP, #0037Dh
                LB A, [DP]
                MOV X2, #05CACh
                JBR off(01Bh).0, ign_advance_corr_cmp_acc_ram36
                MOV X2, #05CBAh
                CMPB A, #056h
                JGE ign_advance_corr_cmp_acc_ram36
                LB A, #056h
ign_advance_corr_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(02Bh).6, C
                JBS off(01Ah).0, idle_gate6_result
                JLT idle_gate6_result
                JBR off(02Bh).7, idle_gate7
                JBS off(01Bh).7, idle_gate6_result
                MOV X1, #05C89h
                LB A, 0D9h
                VCAL 0
                DB  0B5h,0C8h,0C2h,0CAh,00Fh
idle_gate6_result:
                MOVB off(0F4h), off(096h)
                SJ idle_flag_zero
idle_gate7:
                L A, off(06Ch)
                SUB A, #00080h
                JLT idle_flag_zero
                SJ idle_flag_check3
                DB  091h,078h,0F5h,0D9h,032h,00Ch,04Dh,088h
                DB  021h,015h,0E5h,0C8h,090h,035h,044h,098h
                DB  000h,020h,045h,0C0h,000h,000h,0CEh,003h
                DB  048h,0CAh,001h,034h
idle_flag_check3:
                CMPB off(0F4h), #000h
                JNE idle_flag_store_ram6c
idle_flag_zero:
                CLR A
idle_flag_store_ram6c:
                ST A, off(06Ch)
                JBR off(019h).7, idle_mode_dispatch
                MOV DP, #003AFh
                MOVB r0, [DP]
                L A, #01480h
                CMPB r0, #033h
                JEQ idle_gear_select_done
                L A, #02300h
                CMPB r0, #034h
                JEQ idle_gear_select_done
                L A, #02D00h
                CMPB r0, #035h
                JEQ idle_gear_select_done
                L A, #03FFFh
idle_gear_select_done:
                L A, ACC
                J idle_gear_target_check
idle_mode_dispatch:
                JBR off(01Ah).0, idle_mode_dispatch2
                SB off(028h).4
                MOV X1, #05B64h
                JBS off(016h).3, to_idle_vcal5_load_ramd9
                MOV X1, #05B49h
to_idle_vcal5_load_ramd9:
                LB A, 0D9h
                VCAL 0
                STB A, off(06Eh)
                JBS off(017h).5, ign_advance_corr_store_ram60
                MOV DP, #00386h
                SJ ign_advance_corr_load_ind
idle_mode_dispatch2:
                JBR off(018h).2, ign_advance_corr_if_ram1a_b1_clr
                JBR off(02Ah).3, idle_gear_calc_start
                L A, #011EBh
                J idle_gear_target_final
ign_advance_corr_if_ram1a_b1_clr:
                JBR off(01Ah).1, ign_advance_corr_clear_ram6a
                L A, off(06Ch)
                JNE ign_advance_corr_clear_ram6a
                JBR off(01Ch).4, idle_gear_calc_start
                CMPB 0D9h, #02Eh
                JGE idle_gear_calc_start
                CMPB 0CCh, #00Fh
                JLT idle_gear_calc_start
                JBR off(02Ah).2, idle_gear_calc_start
                J ign_dispatch_warm_set_x1
ign_advance_corr_load_ramc2:
                LB A, 0C2h
                VCAL 0
                STB A, off(070h)
                JEQ idle_gear_calc_start
                SB off(028h).6
                MOV DP, #0030Ch
ign_advance_corr_load_ind:
                L A, [DP]
ign_advance_corr_vcal5:
                VCAL 5
ign_advance_corr_store_ram60:
                ST A, off(060h)
                J idle_stall_check2_load_ram74
ign_advance_corr_clear_ram6a:
                CLR off(06Ah)
                JBR off(016h).3, carry_sc
                JBS off(011h).5, carry_sc
                JBR off(025h).3, carry_sc
                SB off(028h).7
                MOV er3, off(06Ch)
                L A, off(062h)
                VCAL 5
                MOV DP, #00384h
                L A, [DP]
                SJ ign_advance_corr_vcal5
carry_sc:
                SC
                JBS off(02Bh).4, idle_direction_toggle
                JBS off(012h).5, idle_direction_toggle
                MB C, 0B0h.1
idle_direction_toggle:
                XORB PSWH, #080h
                MB off(028h).5, C
idle_gear_calc_start:
                CLR A
                ST A, er2
                MOV DP, #0030Ch
                J timer_state_reinit_set_er0
ign_advance_corr_set_acch:
                MOVB ACCH, #026h
                MOVB r5, #0A6h
                JBR off(028h).5, idle_gear_mul_apply
                JBR off(01Ah).2, idle_gear_mul_apply
                CMPB 0D9h, #04Ah
                JGE idle_gear_mul_apply
                L A, [DP]
                ADD A, off(066h)
                JGE idle_gear_result_store_ram8e
                L A, #0FFFFh
                SJ idle_gear_result_store_ram8e
idle_gear_mul_apply:
                MUL
                SLL A
                L A, er1
                ROL A
                JLT idle_gear_clamp
                ADD A, off(066h)
                JLT idle_gear_clamp
                ADD A, [DP]
                JGE idle_gear_clamp_max
idle_gear_clamp:
                L A, #0FFFFh
idle_gear_clamp_max:
                SUB A, #00500h
                JGE idle_gear_result_store_ram8e
                CLR A
idle_gear_result_store_ram8e:
                ST A, off(08Eh)
                L A, er2
                MUL
                SLL A
                L A, er1
                ROL A
                JLT idle_gear2_clamp
                ADD A, off(066h)
                JLT idle_gear2_clamp
                ADD A, #01000h
                JGE idle_gear2_store_ram8c
idle_gear2_clamp:
                L A, #0FFFFh
idle_gear2_store_ram8c:
                ST A, off(08Ch)
                MOVB r0, #020h
                MOV DP, #IdleStepGear
                JBR off(028h).5, ign_advance_corr_if_ram18_b2_clr
                JBS off(01Ah).3, idle_timer_gate_common
                MOVB off(098h), #028h
                SJ idle_timer_gate_common
ign_advance_corr_if_ram18_b2_clr:
                JBR off(018h).2, idle_timer_gate_common
                CLRB off(0D9h)
                MOVB r0, #028h
                JBS off(01Ah).4, idle_table_select2
                SJ idle_timer_set_ram98
idle_timer_gate_common:
                JBS off(01Ah).2, idle_table_select2
                LB A, off(0D9h)
                JEQ idle_table_select1
                MOV DP, #IdleTimer
                SJ idle_flag_gate
idle_table_select1:
                LB A, off(0D6h)
                JEQ idle_table_select_default
                JBR off(01Ah).4, idle_table_select_default
                MOV DP, #IdleStep2
                SJ idle_flag_gate
idle_table_select_default:
                MOV DP, #IdleStepDefault
                MOV X1, #IdleAirTarget1
                JBR off(01Ah).4, ign_advance_corr_load_ram5a
                MOV X1, #IdleAirTarget2
ign_advance_corr_load_ram5a:
                L A, off(05Ah)
                CAL interp_table
                CMP A, 0CAh
                JLT ign_advance_corr_set_x1
                MOV DP, #IdleStep1
ign_advance_corr_set_x1:
                MOV X1, #05C09h
                L A, off(05Ah)
                CAL interp_table
                JBR off(01Ah).4, idle_flag_gate
                CMP A, 0CAh
                JGE idle_flag_gate
                LB A, off(098h)
                JEQ idle_flag_gate
                SUBB A, #001h
                STB A, r0
idle_table_select2:
                MOV DP, #IdleStep2
idle_timer_set_ram98:
                MOVB off(098h), r0
idle_flag_gate:
                LB A, off(0DAh)
                JNE ign_advance_corr_set_ram88
                RB off(025h).5
ign_advance_corr_set_ram88:
                MOV off(088h), off(086h)
                MOVB off(08Bh), off(08Ah)
                SB off(02Bh).1
                JBS off(028h).5, ign_advance_corr_if_ram1a_b3_clr
                JBS off(01Ah).3, ign_advance_corr_load_ram62
                L A, off(062h)
                JBS off(0EEh).1, idle_mode_gate6_store_er3
                J idle_pi_mul1
ign_advance_corr_if_ram1a_b3_clr:
                JBR off(01Ah).3, ign_advance_corr_load_ram62
                JBR off(016h).3, ign_advance_corr_if_ram29_b5_set
                JBS off(029h).4, ign_advance_corr_load_ram62
ign_advance_corr_if_ram29_b5_set:
                JBS off(029h).5, ign_advance_corr_load_ram62
                JBR off(02Bh).3, idle_pi_mul1
                CMPB 0D9h, #0D0h
                JLT ign_advance_corr_if_ram29_b6_clr
                CMPB 0F3h, #0FAh
                JLT idle_pi_mul1
ign_advance_corr_if_ram29_b6_clr:
                JBR off(029h).6, idle_pi_mul1
ign_advance_corr_load_ram62:
                L A, off(062h)
                JBR off(016h).3, ign_advance_corr_if_ramee_b1_clr
                JBR off(011h).5, ign_advance_corr_if_ram28_b3_clr
ign_advance_corr_if_ramee_b1_clr:
                JBR off(0EEh).1, idle_mode_gate6
                MOV er3, off(06Eh)
                MOV DP, #00386h
                SJ ign_advance_corr_load_ind_2
ign_advance_corr_if_ram28_b3_clr:
                JBR off(028h).3, idle_mode_gate6
                ST A, er3
                MOV DP, #00384h
ign_advance_corr_load_ind_2:
                L A, [DP]
                SJ ign_advance_corr_vcal5_2
idle_mode_gate6:
                JBR off(028h).5, idle_mode_gate6_store_er3
                JBS off(01Ah).3, idle_mode_gate6_store_er3
                JBS off(0EEh).1, idle_mode_gate6_store_er3
                JBS off(028h).3, idle_mode_gate6_store_er3
                CMPB off(0DAh), #000h
                JEQ ign_advance_corr_set_x2
                SB off(025h).5
                JNE idle_mode_gate6_store_er3
ign_advance_corr_set_x2:
                MOV X2, A
                LB A, #014h
                MOV X1, #05C49h
                JBR off(01Bh).0, ign_advance_corr_store_ramda
                LB A, #014h
                MOV X1, #05C5Bh
ign_advance_corr_store_ramda:
                STB A, off(0DAh)
                LB A, 0D8h
                VCAL 0
                L A, X2
                VCAL 5
idle_mode_gate6_store_er3:
                ST A, er3
                MOV DP, #0030Ch
                L A, [DP]
ign_advance_corr_vcal5_2:
                VCAL 5
                MOV er3, off(066h)
                VCAL 5
                ST A, off(086h)
                ST A, off(088h)
                CLRB A
                STB A, off(08Ah)
                STB A, off(08Bh)
                CLR A
                ST A, er1
                ST A, er2
                MOV X1, A
                MOV X2, A
                SJ idle_vcal4_set_er3
idle_pi_mul1:
                MOV er0, 0C8h
                LC A, [DP]
                MUL
                L A, er1
                JBR off(01Bh).7, idle_pi_mul2
                VCAL 7
idle_pi_mul2:
                MOV X1, A
                MOV er0, 0CAh
                INC DP
                INC DP
                LC A, [DP]
                MUL
                L A, er1
                JBR off(01Ah).4, idle_pi_mul3
                VCAL 7
idle_pi_mul3:
                MOV X2, A
                INC DP
                INC DP
                LC A, [DP]
                MUL
                ST A, er2
                L A, off(068h)
idle_vcal4_set_er3:
                MOV er3, off(086h)
                VCAL 4
                LB A, off(08Ah)
                JBS off(01Ah).4, idle_integrator_sub
                ADDB A, r5
                STB A, r5
                L A, er3
                ADC A, er1
                JGE idle_integrator_result
                L A, #0FFFFh
                SJ idle_integrator_result
idle_integrator_sub:
                SUBB A, r5
                STB A, r5
                L A, er3
                SBC A, er1
                JGE idle_integrator_result
                CLR A
idle_integrator_result:
                CAL vss_period
                ST A, er1
                ST A, er3
                JLT idle_pi_set_ram86
                L A, X1
                VCAL 4
                L A, X2
                VCAL 4
                CAL vss_period
                JLT idle_pi_result_common
                MOVB off(08Ah), r5
idle_pi_set_ram86:
                MOV off(086h), er1
idle_pi_result_common:
                ST A, er3
                L A, off(06Ch)
                JBS off(028h).5, idle_vcal5_call3
                L A, off(06Ah)
idle_vcal5_call3:
                VCAL 5
                ST A, off(060h)
                JBS off(025h).7, idle_stall_check2_load_ram74
                JBR off(028h).5, idle_stall_check2_load_ram74
                JBS off(01Ah).2, idle_stall_check2_load_ram74
                MB C, off(02Ah).1
                JBR off(017h).6, ign_advance_corr_branch
                MB C, off(02Ah).6
ign_advance_corr_branch:
                JLT idle_stall_check2_load_ram74
                L A, off(07Ah)
                JNE idle_stall_check2_load_ram74
                L A, off(080h)
                JNE idle_stall_check2_load_ram74
                CMPB 0BEh, #07Bh
                JLT idle_stall_check2_load_ram74
                CMP 0C8h, #00018h
                JGE idle_stall_check2_load_ram74
                L A, #00040h
                JBR off(01Ah).4, idle_stall_check2
                L A, #00040h
idle_stall_check2:
                CMP A, 0CAh
                JLT idle_stall_check2_load_ram74
                CMPB 0D9h, #067h
                JGE idle_stall_check2_load_ram74
                LB A, off(0DAh)
                JNE idle_stall_check2_load_ram74
                LB A, 0BCh
                MOV X1, #05C77h
                VCAL 1
                LB A, #0C2h
                JBS off(016h).3, sub_sub_acc
                LB A, #0C2h
sub_sub_acc:
                SUBB A, r6
                JGE idle_stall_set_er0
                CLRB A
idle_stall_set_er0:
                MOV er0, #00040h
                CMPB A, 0BEh
                JLT idle_stall_cmp_ramd9_imm
                MOV er0, #00010h
idle_stall_cmp_ramd9_imm:
                CMPB 0D9h, #028h
                JLT idle_stall_diff_calc
                MOV er0, #00001h
idle_stall_diff_calc:
                MOV X1, #0030Ch
                L A, off(086h)
                SUB A, off(062h)
                JLT idle_stall_diff_calc_clear_acc
                SUB A, off(066h)
                JGE idle_stall_diff_calc_call_alu_1
idle_stall_diff_calc_clear_acc:
                CLR A
idle_stall_diff_calc_call_alu_1:
                CAL alu_1
                CAL const_table_a
idle_stall_check2_load_ram74:
                L A, off(074h)
                MOV er3, off(076h)
                VCAL 5
                L A, off(078h)
                VCAL 5
                L A, off(07Ah)
                VCAL 5
                L A, off(07Ch)
                VCAL 5
                L A, off(080h)
                CMP A, #08000h
                JGE idle_target_clamp1
                ADD A, er3
                JGE idle_target_clamp2
                SJ idle_target_clamp_max
idle_target_clamp1:
                ADD A, er3
                JGE idle_target_final_store_ram72
idle_target_clamp2:
                CMP A, #08000h
                JLT idle_target_final_store_ram72
idle_target_clamp_max:
                L A, #07FFFh
idle_target_final_store_ram72:
                ST A, off(072h)
                CLR X1
                JBS off(017h).5, idle_output_gate2
                JBR off(025h).7, idle_target_final_set_er3
                MOV DP, #0030Ch
                L A, 00384h[X1]
                ST A, [DP]
idle_target_final_set_er3:
                MOV er3, #01000h
                L A, 00384h[X1]
                VCAL 5
                MB C, 0B0h.1
                JLT idle_output_common
                JBS off(012h).5, idle_output_common
                MOV er3, off(062h)
                L A, 00384h[X1]
                VCAL 5
                CLR A
                JBS off(012h).2, ign_advance_corr_load_imm
                JBR off(012h).4, idle_output_vcal5
ign_advance_corr_load_imm:
                L A, #01500h
idle_output_vcal5:
                VCAL 5
                JBS off(02Bh).4, idle_output_common
idle_output_gate2:
                L A, off(060h)
                JBS off(028h).6, idle_pi_final_calc
                CLR off(070h)
                JBS off(02Bh).1, idle_output_gate3
idle_output_common:
                MOV er3, off(066h)
                VCAL 5
idle_output_gate3:
                MOV er3, off(072h)
                XCHG A, er3
                VCAL 4
idle_pi_final_calc:
                MOV X2, A
                CLR X1
                L A, 0037Eh[X1]
                SUB A, 0030Ch[X1]
                SLL A
                ST A, er0
                CLR A
                JLT idle_pi_scale_store_ram82
                LB A, off(092h)
                ANDB A, #07Fh
                STB A, ACCH
                CLRB A
                MUL
                L A, er1
idle_pi_scale_store_ram82:
                ST A, off(082h)
                L A, X2
                CLRB r0
                MOVB r1, off(092h)
                MUL
                SLL A
                L A, er1
                ROL A
                JGE idle_pi_result_clamp
                L A, #0FFFFh
idle_pi_result_clamp:
                ST A, er3
                L A, off(082h)
                VCAL 5
                LCB A, IdleControlScale
                JEQ ign_advance_corr_load_er3
                L A, off(084h)
                VCAL 4
ign_advance_corr_load_er3:
                L A, er3
idle_gear_target_check:
                JNE ign_advance_corr_set_er3
                JBS off(01Ah).4, idle_gear_target_reset
                SJ idle_gear_target_store_ram5e
ign_advance_corr_set_er3:
                MOV er3, #03FFFh
                JBS off(016h).3, ign_advance_corr_cmp_acc_er3
                MOV er3, #03FFFh
ign_advance_corr_cmp_acc_er3:
                CMP A, er3
                JLT idle_gear_target_store_ram5e
                L A, er3
                JBS off(01Ah).4, idle_gear_target_store_ram5e
idle_gear_target_reset:
                MOV off(086h), off(088h)
                MOVB off(08Ah), off(08Bh)
idle_gear_target_store_ram5e:
                ST A, off(05Eh)
                MOV X1, #IdleDutyTarget
                CAL interp_table
idle_gear_target_final:
                ST A, off(05Ch)
                RB off(02Bh).1
                MB C, off(028h).5
                MB off(01Ah).3, C
                LB A, off(028h)
                ANDB A, #0F0h
                SWAPB
                STB A, off(028h)
                RB 0B6h.4
                RT
; Fault response A (031h.1): expected-state words atomic_ram_update (RAM 0x15 <- 0x01B3, 0x21 <-
; 0x02BF), fault countdown 0F3h (wrap at 255), adc_fault_default.
fault_recovery_a:
                MOV DP, #00015h
                MOV X1, #001B3h
                CAL atomic_ram_update
                MOV DP, #00021h
                MOV X1, #002BFh
                CAL atomic_ram_update
                LB A, 0F3h
                ADDB A, #001h
                JEQ vcal3_task_c_msec_tick
                STB A, 0F3h
vcal3_task_c_msec_tick:
                CAL adc_fault_default
                CLR X1
                LB A, 0039Dh[X1]
                JEQ percyl_counter_gate
                CMPB off(0C5h), #000h
                JNE percyl_alt_check
                MOVB r2, #010h
                CMPB A, r2
                JGE percyl_counter_check2
                MOVB r2, #001h
percyl_counter_check2:
                SUBB A, r2
                MOV er1, #01107h
                JNE fault_recovery_a_store_ind
percyl_counter_gate:
                SC
                JBS off(014h).7, tach_output_drive
                CLR A
fault_recovery_a_load_ind:
                LB A, 0039Eh[X1]
                STB A, r0
                CMPB A, #020h
                JLT percyl_counter_dp_select
                CLRB 0039Eh[X1]
                LCB A, OptionFlagsFromBytes
                JEQ tach_output_drive
                LB A, 0AFh
                JEQ tach_output_drive
                SJ percyl_bcd_convert
percyl_counter_dp_select:
                MOV DP, #00321h
                CMPB A, #018h
                JGE percyl_counter_increment
                DEC DP
                JBS off(008h).4, percyl_counter_increment
                DEC DP
                JBS off(008h).3, percyl_counter_increment
                DEC DP
percyl_counter_increment:
                INCB 0039Eh[X1]
                TBR [DP]
                JNE percyl_wrap_check1
                LB A, 0039Eh[X1]
                ANDB A, #007h
                RC
                JNE fault_recovery_a_load_ind
                SJ tach_output_drive
percyl_wrap_check1:
                ADDB A, #001h
                CMPB A, #01Dh
                JNE percyl_wrap_check2
                LB A, #02Bh
percyl_wrap_check2:
                CMPB A, #01Bh
                JNE percyl_wrap_check3
                LB A, #029h
percyl_wrap_check3:
                CMPB A, #01Ah
                JNE percyl_wrap_check4
                LB A, #024h
percyl_wrap_check4:
                CMPB A, #019h
                JNE percyl_bcd_convert
                LB A, #023h
percyl_bcd_convert:
                MOVB r0, #00Ah
                DIVB
                SWAPB
                ORB A, r1
                MOV er1, #02B20h
fault_recovery_a_store_ind:
                STB A, 0039Dh[X1]
                CMPB A, #010h
                JLT percyl_result_final
                MOVB r2, r3
percyl_result_final:
                MOVB off(0C5h), r2
percyl_alt_check:
                CMPB A, #010h
                L A, #00206h
                JLT percyl_alt_store_er1
                L A, #00311h
percyl_alt_store_er1:
                ST A, er1
                LB A, off(0C5h)
                CMPB A, r2
                JGE tach_output_drive
                CMPB r3, A
tach_output_drive:
                MB P1.5, C
                JBR off(010h).7, tach_output_return
                MOV DP, #0031Eh
                L A, [DP]
                JNE tach_output_drive2
                INC DP
                INC DP
                L A, [DP]
                JNE tach_output_drive2
                LCB A, OptionFlagsFromBytes
                JEQ set_carry_flag
                LB A, 0AFh
                JNE tach_output_drive2
set_carry_flag:
                SC
tach_output_drive2:
                MB P1.4, C
tach_output_return:
                RT
; Fault response B (031h.2): expected-state words atomic_ram_update (RAM 0x02 <- 0x01B0, 0x08 <-
; 0x02B6), fault countdown 0F2h, then the fault state block (0x35E5 zeros).
fault_recovery_b:
                MOV DP, #00002h
                MOV X1, #001B0h
                CAL atomic_ram_update
                MOV DP, #00008h
                MOV X1, #002B6h
                CAL atomic_ram_update
                LB A, 0F2h
                ADDB A, #001h
                JEQ fault_recovery_b_goto_learn_table1_check
                STB A, 0F2h
fault_recovery_b_goto_learn_table1_check:
                SJ learn_table1_check
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
learn_table1_check:
                LB A, off(0BCh)
                JNE learn_table2_check
                MOVB off(0BCh), #002h
                MOV X1, #DiagSnapshot2
                MOV DP, #001D7h
                MOVB r6, #027h
learn_table1_loop:
                LB A, [DP]
                ADDB A, #001h
                JLT fault_recovery_b_rom_load_ind
                CMPCB A, [X1]
                JLT learn_table1_store_ind
fault_recovery_b_rom_load_ind:
                LCB A, [X1]
learn_table1_store_ind:
                STB A, [DP]
                LB A, r6
                SUBB A, 0F4h
                JNE learn_table1_advance
                STB A, 0F4h
learn_table1_advance:
                INC X1
                INC DP
                INCB r6
                CMP DP, #001DBh
                JLE learn_table1_loop
learn_table2_check:
                LB A, off(0BDh)
                JNE vcal3_task_a_return
                MOVB off(0BDh), #002h
                LB A, #001h
                MB C, 0B7h.1
                JLT learn_counter_store_ramf7
                LB A, 0F7h
                ADDB A, #001h
                CMPB A, #020h
                JLT learn_counter_store_ramf7
                LB A, #020h
learn_counter_store_ramf7:
                STB A, 0F7h
                LB A, 0F6h
                ADDB A, #001h
                CMPB A, #020h
                JLT learn_retry_store_ramf6
                RB 0B7h.1
                LB A, #020h
learn_retry_store_ramf6:
                STB A, 0F6h
vcal3_task_a_return:
                RT
; Main-loop gate: verifies IE matches the mode mask (0x02BAB normal / 0x0A9A3 restricted, selected
; by 017h.2; mismatch -> trap 0x4F via trap_retry_check), runs the periodic RAM test (ram_readback_test
; over the 0x0398/0x03FA window), issues VCAL 3, then sets IE + expected words
; 0F8h/0FAh to the mode mask (0x02BAB / 0x0A9A3) and restores IE -> state_verify.
main_loop_gate:
                L A, #02BABh
                MOV X1, #002A0h
                JBR off(017h).2, regbank_selftest2_ie_check
                L A, #0A9A3h
                MOV X1, #000A0h
regbank_selftest2_ie_check:
                CMP A, 0F8h
                JNE selftest_fail_set_ramf5_3
                CMP A, IE
                JNE selftest_fail_set_ramf5_3
                L A, X1
                CMP A, 0FAh
                JEQ main_loop_gate_set_dp
selftest_fail_set_ramf5_3:
                MOVB 0F5h, #04Fh
                J trap_retry_check
main_loop_gate_set_dp:
                MOV DP, #00398h
                L A, [DP]
                CMP A, #003FAh
                JGT regbank_selftest2_default
                MOV X1, A
                MOV DP, 00084h[X1]
                L A, #05555h
                CAL ram_readback_test
                SLL A
                CAL ram_readback_test
                L A, X1
                SUB A, #00002h
                JGE main_loop_gate_set_dp_2
                L A, #05555h
                MOV X1, A
                CMP A, X1
                JNE selftest_fail_set_ramf5_4
                MOV X2, A
                CMP A, X2
                JNE selftest_fail_set_ramf5_4
                SLL A
                MOV X1, A
                CMP A, X1
                JEQ regbank_selftest2_check3
selftest_fail_set_ramf5_4:
                MOVB 0F5h, #042h
                BRK
regbank_selftest2_check3:
                MOV X2, A
                CMP A, X2
                JNE selftest_fail_set_ramf5_4
regbank_selftest2_default:
                L A, #003FAh
main_loop_gate_set_dp_2:
                MOV DP, #00398h
                ST A, [DP]
                VCAL 3
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                JBS off(012h).3, irqmode_select_b
                JBS off(017h).2, irqmode_check1
                RB IRQH.7
                JEQ irqmode_check1
                SB 0B6h.7
                SB 0B4h.0
irqmode_check1:
                ORB PSWH, #001h
                CMPB 81[USP], #029h
                ANDB PSWH, #0FEh
                JLT irqmode_select_b
                JBR off(017h).2, irqmode_done
                L A, #02BABh
                ST A, IE
                ST A, 0F8h
                MOV 0FAh, #002A0h
                RB off(017h).2
                SJ irqmode_done
irqmode_select_b:
                JBS off(017h).2, irqmode_done
                L A, #0A9A3h
                ST A, IE
                ST A, 0F8h
                MOV 0FAh, #000A0h
                SB off(017h).2
                RB -91[USP].7
                RB off(01Dh).7
                SB TCON3.3
                SB TCON3.2
irqmode_done:
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
; State verification (loop entry): SSP == 0x47E, RAM 0x400 == 0, PSW & 0x1107 == 0x1100, LRB == 0x41,
; P0IO == 0xFF, P1IO == 0xFF, P2IO == 0xFF, P2SF == 0x07, P3IO == 0xB1, P3SF == 0xFF, P4IO == 0x0D,
; P4SF == 0xF0, TCON0-3 == 0x93/0x53/0x92/0x93, PWCON0 & 0x7B == 0x3A, PWCON1 & 0x7B == 0x7A,
; ADSEL == 0, ADSCAN == 0x10, STTMC & 0xF3 == 0x12, STCON & 0x7F == 0x1C, SRCON == 0x8C, STTMR ==
; 0xDF. Any mismatch -> trap 0x50 via trap_retry_check.
state_verify:
                CMP SSP, #0047Eh
                JNE selftest_fail_set_ramf5_5
                MOV DP, #00400h
                L A, [DP]
                JNE selftest_fail_set_ramf5_5
                L A, PSW
                AND A, #01107h
                CMP A, #01100h
                JNE selftest_fail_set_ramf5_5
                CMP LRB, #00041h
                JNE selftest_fail_set_ramf5_5
                CMPB P0IO, #0FFh
                JNE selftest_fail_set_ramf5_5
                CMPB P1IO, #0FFh
                JNE selftest_fail_set_ramf5_5
                CMPB P2IO, #0FFh
                JNE selftest_fail_set_ramf5_5
                CMPB P2SF, #007h
                JNE selftest_fail_set_ramf5_5
                CMPB P3IO, #0B1h
                JNE selftest_fail_set_ramf5_5
                CMPB P3SF, #0FFh
                JNE selftest_fail_set_ramf5_5
                CMPB P4IO, #00Dh
                JNE selftest_fail_set_ramf5_5
                CMPB P4SF, #0F0h
                JNE selftest_fail_set_ramf5_5
                LB A, TCON0
                MOVB r0, #0F3h
                ANDB A, r0
                CMPB A, #093h
                JNE selftest_fail_set_ramf5_5
                LB A, TCON1
                ANDB A, r0
                CMPB A, #053h
                JNE selftest_fail_set_ramf5_5
                LB A, TCON2
                ANDB A, r0
                CMPB A, #092h
                JNE selftest_fail_set_ramf5_5
                LB A, TCON3
                ANDB A, r0
                CMPB A, #093h
                JEQ periph_init_verify_pwm_adc
selftest_fail_set_ramf5_5:
                MOVB 0F5h, #050h
                BRK
periph_init_verify_pwm_adc:
                LB A, PWCON0
                ANDB A, #07Bh
                CMPB A, #03Ah
                JNE selftest_fail_set_ramf5_5
                LB A, PWCON1
                ANDB A, #07Bh
                CMPB A, #07Ah
                JNE selftest_fail_set_ramf5_5
                LB A, ADSEL
                ANDB A, #05Fh
                JNE selftest_fail_set_ramf5_5
                LB A, ADSCAN
                ANDB A, #05Fh
                CMPB A, #010h
                JNE selftest_fail_set_ramf5_5
                MOV DP, #00356h
                MB C, [DP].1
                JGE state_verify_load_ramfa
                LB A, STTMC
                ANDB A, #0F3h
                CMPB A, #012h
                JNE selftest_fail_set_ramf5_5
                LB A, STCON
                ANDB A, #07Fh
                CMPB A, #01Ch
                JNE selftest_fail_set_ramf5_5
                CMPB SRCON, #08Ch
                JNE selftest_fail_set_ramf5_5
                CMPB STTMR, #0DFh
                JNE selftest_fail_set_ramf5_5
state_verify_load_ramfa:
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                MOV er0, TM0
                MOV er1, TM1
                MOV er2, TM2
                MOV er3, TM3
                ORB PSWH, #001h
                NOP
                ANDB PSWH, #0FEh
                MOV X1, TM0
                MOV X2, TM1
                MOV DP, TM2
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                L A, X1
                SUB A, er0
                ST A, er0
                JEQ timer_drift_trap
                CMP A, #00022h
                JGE timer_drift_trap
                L A, X2
                SUB A, er1
                ST A, er1
                JEQ timer_drift_trap
                CMP A, #00080h
                JGE timer_drift_trap
                L A, DP
                SUB A, er2
                MOV X2, A
                JEQ timer_drift_trap
                CMP A, #00022h
                JGE timer_drift_trap
                L A, er3
                SUB A, er2
                MB C, ACCH.7
                JGE clock_selftest_check2
                VCAL 7
clock_selftest_check2:
                CMP A, #00002h
                JGE timer_drift_trap
                L A, er1
                SRL A
                SRL A
                SUB A, X2
                JGE clock_selftest_check3
                VCAL 7
clock_selftest_check3:
                CMP A, #00002h
                JGE timer_drift_trap
                L A, X2
                SUB A, er0
                JGE clock_selftest_check4
                VCAL 7
clock_selftest_check4:
                CMP A, #00002h
                JLT timer_reinit
; Timer drift trap: the TM0/TM1 deltas since the last gate were outside their windows (TM0 <= 0x21,
; TM1 <= 0x7F, neither 0) -> trap 0x4B via trap_retry_check, then falls into timer_reinit.
timer_drift_trap:
                MOVB 0F5h, #04Bh
                BRK
; Timer reinitialisation: VCAL 3 + timer_state_reinit: CKP/VSS state
; words (0A0h=4, 0A2h=2, 0A4h/0E8h = 0xFFFF, 0358h/035Eh = 0xFF04, 0357h/035Dh = 0xFF, 0B8h |= 0x3),
; TMR3 - 1, TCON3 |= 0x0C, flag cleanup (01Eh.4, 01Fh &= 0xF9, P1 &= 0xFC), IE restore.
timer_reinit:
                VCAL 3
                CAL timer_state_reinit
                MOVB r0, #001h
                JBR off(017h).2, warmcold_ie_setup
                MOVB r0, #006h
warmcold_ie_setup:
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                RB off(031h).5
                JBR off(017h).4, warmcold_tm2_check
                J flag_cleanup
warmcold_tm2_check:
                JNE coldstart_full_reset
                LB A, r0
                CMPB A, 0AEh
                JLT coldstart_full_reset
                JNE warmrestart_path
                L A, TM2
                CMP A, 0EEh
                JGE coldstart_full_reset
warmrestart_path:
                J flag_cleanup_or_pswh
coldstart_full_reset:
                SB off(017h).4
                CLRB A
                MOVB 0A2h, #002h
                STB A, 0A3h
                MOVB -76[USP], #005h
                STB A, -75[USP]
                MOVB -67[USP], #004h
                CLR A
                MOV X1, A
                ST A, 00360h[X1]
                ST A, 00362h[X1]
                ST A, 00364h[X1]
                ST A, 00366h[X1]
                ST A, 00368h[X1]
                ST A, 0036Ah[X1]
                ST A, off(066h)
                ST A, 003A6h[X1]
                L A, #0FFFFh
                ST A, 0036Eh[X1]
                ST A, 00370h[X1]
                ST A, 00372h[X1]
                ST A, 0C4h
                CLRB A
                STB A, off(036h)
                STB A, -77[USP]
                STB A, 0C3h
                STB A, -26[USP]
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                SB P4.0
                ORB TCON3, #00Ch
                SB -90[USP].0
                MOVB 0A0h, #004h
                SB -86[USP].5
                L A, #0FFFFh
                ST A, 0A4h
                ST A, 0E8h
                L A, #0FF04h
                ST A, 00358h[X1]
                ST A, 0035Eh[X1]
                LB A, #0FFh
                STB A, 00357h[X1]
                STB A, 0035Dh[X1]
                ORB 0B8h, #003h
                RB off(021h).7
                ANDB P1, #0FCh
                ANDB -89[USP], #0F9h
                ANDB off(01Fh), #0F9h
                RB off(032h).7
                RB -90[USP].4
                RB off(01Eh).4
                CLR A
                ST A, -88[USP]
                ST A, -92[USP]
                ST A, off(01Ch)
                ST A, 42[USP]
                ST A, 40[USP]
                ST A, 0ECh
                ST A, 0EAh
; Flag cleanup after timer reinit: P1 &= 0xFC, 01Fh &= 0xF9, 032h.7 cleared, 01Ch/0ECh/0EAh = 0,
; TMR3 - 1, IE restored, then the TPS gate.
flag_cleanup:
                L A, TM3
                SUB A, #00001h
                ST A, TMR3
flag_cleanup_or_pswh:
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                SC
                JBS off(017h).4, warmcold_deg_flag
                JBS off(011h).0, warmcold_deg_select
                JBR off(017h).5, housekeeping_call
warmcold_deg_select:
                LB A, #012h
                JBS off(017h).5, warmcold_deg_check
                LB A, #01Dh
warmcold_deg_check:
                CMPB A, 0C5h
warmcold_deg_flag:
                MB off(017h).5, C
                JGE housekeeping_call
                JBR off(011h).0, flag_cleanup_clear_acc
                SB off(030h).4
flag_cleanup_clear_acc:
                CLRB A
                STB A, 0F3h
                STB A, 0F2h
                JBR off(017h).4, tps_learn_vcal3
; Housekeeping call point: 0C4h (TPS-derived byte, 0x31/0x1C/0x8C class values) check, VCAL 3
; issued, 0379h/037Ah/0311h/030Ch/0384h state words and 0C5h threshold updates.
housekeeping_call:
                MOVB off(0C4h), #031h
tps_learn_vcal3:
                VCAL 3
                CLR X1
                MOVB r0, #07Bh
                JBS off(017h).4, tps_learn_table_load_ind
                JBS off(01Ah).1, tps_learn_table_load_ind
                JBS off(01Ah).2, tps_learn_table_load_ind
                LB A, 0D4h
                CMPB A, r0
                JGE tps_learn_table_load_ind
                STB A, r1
                MOVB r3, 0037Ah[X1]
                SUBB A, r3
                JLT housekeeping_call_load_r1
                CMPB A, #004h
                JGE housekeeping_call_load_r1
                LB A, off(0D2h)
                JNE housekeeping_call_clear_x1
                LB A, r3
                STB A, 00311h[X1]
                SJ tps_learn_table_load_ind
housekeeping_call_load_r1:
                LB A, r1
                STB A, 0037Ah[X1]
tps_learn_table_load_ind:
                LB A, 00311h[X1]
                CMPB A, r0
                LB A, #096h
                JLT housekeeping_call_store_ramd2
                LB A, #032h
housekeeping_call_store_ramd2:
                STB A, off(0D2h)
housekeeping_call_clear_x1:
                CLR X1
                L A, 0030Ch[X1]
                CMP A, #00010h
                JLT housekeeping_call_load_ind
                CMP A, #01000h
                JLE fueltbl_sanitize_loop
housekeeping_call_load_ind:
                L A, 00384h[X1]
                ST A, 0030Ch[X1]
fueltbl_sanitize_loop:
                MOV DP, #00300h
fueltbl_sanitize_check:
                JBR off(016h).2, fueltbl_range_check
                MB C, 0B8h.5
                JLT fueltbl_default_value
fueltbl_range_check:
                CMP [DP], #09862h
                JGT fueltbl_default_value
                CMP [DP], #07133h
                JGE fueltbl_sanitize_advance
fueltbl_default_value:
                MOV [DP], #08000h
fueltbl_sanitize_advance:
                ADD DP, #00004h
                CMP DP, #0030Ch
                JLT fueltbl_sanitize_check
                MB C, -88[USP].2
                JGE sensor_check_vcal3
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                MOVB r0, 22[USP]
                MOVB r1, -106[USP]
                MOVB r2, -105[USP]
                MOVB r3, -68[USP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                LB A, r3
                CAL phase_countdown
                CMPB A, r0
                JNE knock_check_alt_path
                LB A, r2
                EXTND
                SLL A
                LC A, SelfTestValues[ACC]
                JEQ sensor_check_vcal3
                CMP A, er0
                JEQ sensor_check_vcal3
knock_check_alt_path:
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                RB TCON0.4
                RB TCON0.2
                LB A, #00Fh
                STB A, -105[USP]
                STB A, 23[USP]
                ORB P2, A
                SB TCON0.2
                LB A, -68[USP]
                CAL phase_countdown
                STB A, 22[USP]
                XORB A, #0FFh
                MB C, ACC.7
                ROLB A
                STB A, -106[USP]
                RB TCON0.2
                SB TCON0.4
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
sensor_check_vcal3:
                VCAL 3
                MOV DP, #003D1h
                LB A, [DP]
                STB A, 0DBh
                RC
                JBS off(012h).3, housekeeping_call_flag_ram17_b7
                CMPB 89[USP], #015h
                JGT housekeeping_call_flag_ram17_b7
                SC
                JBS off(01Ch).6, housekeeping_call_flag_ram17_b7
                MOVB 89[USP], #014h
housekeeping_call_flag_ram17_b7:
                MB off(017h).7, C
                JBS off(012h).2, sensor_check_rc
                JBS off(012h).4, sensor_check_rc
                JBR off(017h).5, housekeeping_call_if_ram30_b5_set
                MOVB 66[USP], #032h
                SJ sensor_check_rc
housekeeping_call_if_ram30_b5_set:
                JBS off(030h).5, sensor_check_rc
                CMPB off(036h), #0FFh
                JGE housekeeping_call_if_ram30_b4_clr
                MOVB 66[USP], #032h
housekeeping_call_if_ram30_b4_clr:
                JBR off(030h).4, sensor_check_rc
                MOV DP, #00376h
                LB A, [DP]
                SUBB A, ADCR6H
                JGE sensor_check_result
                VCAL 6
sensor_check_result:
                CMPB A, #000h
                JGE sensor_check_set_ram30_b5
                LB A, 66[USP]
                JEQ dtc05_map_range_latch
sensor_check_rc:
                RC
                SJ dtc05_map_range_latch
sensor_check_set_ram30_b5:
                SB off(030h).5
dtc05_map_range_latch:
                MB 0B0h.3, C
                RB PSWL.4
                CLR X1
                LB A, 003D4h[X1]
                STB A, r1
                RC
                JBS off(012h).5, dtc06_ect_latch
                LB A, #0FCh
                CMPB A, r1
                JLT dtc06_ect_latch
                LB A, r1
                CMPB A, #004h
dtc06_ect_latch:
                MB 0B0h.1, C
                JBS off(012h).5, ect_simulate_ramp
                JLT ect_simulate_ramp_set_ramd9
                JBS off(010h).7, ect_fault_range_check_set_r0
                SUBB A, 00377h[X1]
                JGE ect_fault_delta_check
                VCAL 6
ect_fault_delta_check:
                CMPB A, #002h
                JGT housekeeping_call_load_r1_2
                LB A, 67[USP]
                JNE housekeeping_call_if_ram30_b3_set
                LB A, r1
                JBS off(017h).4, ect_fault_range_check_set_r0
                CMPB A, 00378h[X1]
                JGT sensor_bank_ect_check
                SJ ect_fault_range_check_set_r0
ect_simulate_ramp:
                JBR off(017h).5, ect_simulate_ramp_set_ramd9
                CLR A
                LB A, off(0C4h)
                MOVB r0, #00Ah
                DIVB
                MOV DP, #CoolantFailWarmup
                ADD DP, A
                LCB A, [DP]
                STB A, 0D9h
                SB PSWL.4
                SJ sensor_bank_ect_check
ect_simulate_ramp_set_ramd9:
                MOVB 0D9h, #03Bh
                SB PSWL.4
                SJ sensor_bank_ect_check
ect_fault_range_check_set_r0:
                MOVB r0, 0D9h
                MOV DP, #000D9h
                CAL alu_3
                CMPB A, r0
                JEQ housekeeping_call_if_ram17_b5_set
                SB PSWL.4
housekeeping_call_if_ram17_b5_set:
                JBS off(017h).5, housekeeping_call_fuel_table_init
                STB A, 0031Ah[X1]
housekeeping_call_fuel_table_init:
                CAL fuel_table_init
housekeeping_call_load_r1_2:
                LB A, r1
                STB A, 00377h[X1]
sensor_bank_ect_check:
                MOVB 67[USP], #005h
housekeeping_call_if_ram30_b3_set:
                JBS off(030h).3, housekeeping_call_test_pswl_b4
                LB A, #057h
                CMPB A, 0D9h
                MB off(0EDh).1, C
                SC
                SJ housekeeping_call_flag_ramec_b1
housekeeping_call_test_pswl_b4:
                MB C, PSWL.4
housekeeping_call_flag_ramec_b1:
                MB off(0ECh).1, C
                RC
                JBS off(012h).7, dtc08_tdc_latch
                JBR off(017h).4, dtc08_tdc_latch
                MB C, off(011h).0
                JBR off(016h).3, dtc08_tdc_latch
                JGE dtc08_tdc_latch
                MB C, off(011h).5
dtc08_tdc_latch:
                MB 0B0h.5, C
                JBR off(013h).1, iat_range_check
                MOVB 0D8h, #057h
                SJ iat_check_return
iat_range_check:
                LB A, #0FCh
                MOV DP, #003CCh
                CMPB A, [DP]
                JLT dtc10_iat_latch
                LB A, [DP]
                CMPB A, #004h
                JLT dtc10_iat_latch
                MOV DP, #000D8h
                CAL alu_3
iat_check_return:
                RC
dtc10_iat_latch:
                MB 0B0h.6, C
                LB A, #080h
                RC
                JBS off(017h).6, sensor_bank_store_rame3
                JBS off(019h).3, sensor_bank_store_rame3
                JBS off(013h).2, sensor_bank_store_rame3
                MOV DP, #003D2h
                LB A, #0FFh
                CMPB A, [DP]
                JLT dtc_bit08_latch
                LB A, [DP]
                CMPB A, #000h
                JLT dtc_bit08_latch
sensor_bank_store_rame3:
                STB A, 0E3h
dtc_bit08_latch:
                MB 0B0h.7, C
                JBR off(027h).4, sensor_bank_stamp_bc
                JBR off(013h).4, sensor_bank_bc_alt
sensor_bank_stamp_bc:
                MOVB 0BCh, #0F9h
                SJ dcode14_return
sensor_bank_bc_alt:
                CLR A
                LB A, #0FFh
                MOV DP, #003CDh
                CMPB A, [DP]
                JLT dcode14_check
                LB A, [DP]
                CMPB A, #000h
                JLT dcode14_check
                CAL mul_shift
                MOV DP, #000BCh
                CAL alu_3
dcode14_return:
                RC
dcode14_check:
                MB 0B1h.2, C
                VCAL 3
                JBS off(017h).5, dcode14_rc
                JBS off(013h).5, dcode14_rc
                LB A, 0DBh
                MOV X1, #06027h
                VCAL 2
                CMPB A, off(05Ch)
                JLT dcode14_rc
                LB A, 0DBh
                MOV X1, #0602Dh
                VCAL 2
                CMPB A, off(05Ch)
                JGE dcode14_rc
                LB A, 68[USP]
                JEQ dtc14_iacv_latch
dcode14_rc:
                RC
dtc14_iacv_latch:
                MB 0B1h.3, C
                LB A, #044h
                CMPB A, 0DBh
                JGE dtc17_vss_latch
                CMPB off(036h), #0A7h
                JGE dtc17_vss_latch
                RC
                JBS off(02Dh).1, dtc17_vss_latch
                JBS off(017h).5, dtc17_vss_latch
                JBS off(014h).0, dtc17_vss_latch
                JBR off(031h).3, dtc17_vss_latch
                MB C, off(01Ch).4
dtc17_vss_latch:
                MB 0B1h.4, C
                VCAL 3
                LB A, #01Fh
                JBR off(019h).3, dcode_stamp_store_ramdc
                JBR off(017h).6, dcode_stamp_store_ramdc
                JBS off(014h).3, dcode_stamp_store_ramdc
                CMPB 0DBh, #069h
                JLT dcode_stamp_store_ramdc
                MOV DP, #003D2h
                LB A, #0DCh
                CMPB A, [DP]
                JLT dtc20_eld_latch
                LB A, [DP]
                CMPB A, #00Eh
                JLT dtc20_eld_latch
dcode_stamp_store_ramdc:
                STB A, 0DCh
                RC
dtc20_eld_latch:
                MB 0B1h.7, C
                RC
                JBR off(016h).4, dtc21_vtec_solenoid_latch
                JBS off(014h).4, dtc21_vtec_solenoid_latch
                JBR off(01Fh).2, housekeeping_call_set_ind
                MOVB 53[USP], #032h
                LB A, 52[USP]
                JBS off(010h).5, dtc21_vtec_solenoid_latch
altvtec_vtsf_check_sc:
                SC
                SJ dtc21_vtec_solenoid_latch
housekeeping_call_set_ind:
                MOVB 52[USP], #032h
                LB A, 53[USP]
                JBS off(010h).5, altvtec_vtsf_check_sc
dtc21_vtec_solenoid_latch:
                MB 0B2h.0, C
                JBR off(016h).4, altvtec_vtps_result
                JNE altvtec_vtps_result
                JBS off(014h).4, altvtec_vtps_result
                JLT altvtec_vtps_result
                JBS off(014h).5, altvtec_vtps_result
                MB C, off(011h).1
                JBR off(01Fh).2, dtc22_vtec_pressure_latch
                JLT altvtec_vtps_result
                SC
                SJ dtc22_vtec_pressure_latch
altvtec_vtps_result:
                RC
dtc22_vtec_pressure_latch:
                MB 0B2h.1, C
                RC
                JBR off(027h).6, dtc23_knock_latch
                JBS off(017h).5, dtc23_knock_latch
                JBS off(014h).6, dtc23_knock_latch
                JBS off(033h).6, dtc23_knock_latch
                L A, off(012h)
                AND A, #0C3BCh
                JNE dtc23_knock_latch
                JBS off(014h).5, dtc23_knock_latch
                LB A, off(0FCh)
                JEQ dtc23_knock_latch
                JBS off(033h).7, dtc23_knock_latch
                MB C, off(032h).7
dtc23_knock_latch:
                MB 0B2h.2, C
                JBR off(016h).5, autotcc_return
                LB A, ADCR5H
                STB A, 0D7h
                JBS off(017h).5, autotcc_return
                JBS off(015h).1, autotcc_return
                CMPB 0DBh, #0FFh
                JLT autotcc_return
                LB A, #0FFh
                CMPB A, 0D7h
                JLT dtc26_code26_latch
                CMPB 0D7h, #000h
                SJ dtc26_code26_latch
autotcc_return:
                RC
dtc26_code26_latch:
                MB 0B3h.1, C
                JBR off(016h).5, automatic_return
                JBS off(017h).5, automatic_return
                JBS off(015h).0, automatic_return
                JBS off(015h).1, automatic_return
                MB C, 0B3h.1
                JLT automatic_return
                CMPB 0DBh, #0FFh
                JGE housekeeping_call_cmp_ramd7_imm
automatic_return:
                RC
                SJ dtc25_code25_latch
housekeeping_call_cmp_ramd7_imm:
                CMPB 0D7h, #0FFh
                JLE Automatic_test_p4_b6
                MB C, P4.6
                XORB PSWH, #080h
                SJ dtc25_code25_latch
Automatic_test_p4_b6:
                MB C, P4.6
dtc25_code25_latch:
                MB 0B3h.0, C
                JBR off(019h).3, knockwindow_rc
                JBS off(017h).5, knockwindow_rc
                MOV DP, #003AFh
                LB A, [DP]
                CMPB A, #031h
                JEQ knockwindow_rc
                L A, off(012h)
                AND A, #01808h
                JNE knockwindow_rc
                JBS off(014h).5, knockwindow_rc
                JBS off(01Ch).5, knockwindow_rc
                JBS off(01Dh).3, knockwindow_rc
                JBS off(018h).0, knockwindow_rc
                CMPB 0CCh, #005h
                JLT housekeeping_call_load_ind_2
                J timer_state_reinit_set_x1_5
housekeeping_call_load_ram36:
                LB A, off(036h)
                CAL interp_word
                ADDB A, #010h
                JGE housekeeping_call_cmp_acc_ram35
                LB A, #0FFh
housekeeping_call_cmp_acc_ram35:
                CMPB A, off(035h)
                JGE knockwindow_rc
housekeeping_call_load_ind_2:
                L A, -40[USP]
                CMP A, #0B333h
                JGE knockwindow_sc
                JBS off(017h).3, housekeeping_call_cmp_acc_imm
                JBS off(01Eh).4, knockwindow_rc
housekeeping_call_cmp_acc_imm:
                CMP A, #05B00h
                JLE knockwindow_sc
knockwindow_rc:
                RC
                SJ knockwindow_result
knockwindow_sc:
                SC
knockwindow_result:
                MB 0B5h.7, C
                VCAL 3
                JBS off(0ECh).1, housekeeping_call_set_x1
                J housekeeping_call_load_ramd8
housekeeping_call_set_x1:
                MOV X1, #05B2Eh
                JBS off(016h).3, housekeeping_call_load_ramd9
                MOV X1, #05B13h
housekeeping_call_load_ramd9:
                LB A, 0D9h
                VCAL 0
                STB A, off(062h)
                VCAL 3
                MOV X1, #05C9Eh
                LB A, 0D9h
                CAL interp_word
                STB A, off(096h)
                MOV X1, #05C7Bh
                LB A, 0D9h
                CAL interp_word
                MOV DP, #0037Dh
                STB A, [DP]
                VCAL 3
                CLR X2
                MOV X1, #05D5Eh
                LB A, 0D9h
                CAL interp_word
                STB A, 0037Ch[X2]
                MOV X1, #05E6Ah
                JBS off(016h).3, housekeeping_call_load_ramd9_2
                MOV X1, #05E4Fh
housekeeping_call_load_ramd9_2:
                LB A, 0D9h
                VCAL 0
                STB A, 0037Eh[X2]
                VCAL 3
                LB A, 0D9h
                MOV X1, #05F31h
                MOV X2, #05F25h
                CMPB A, #023h
                JLT knockwindow_result_flag_ram21_b2
                MOV X1, #05F13h
                MOV X2, #KnockRetardLimit+2
knockwindow_result_flag_ram21_b2:
                MB off(021h).2, C
                CAL interp_word
                STB A, r3
                MOV X1, X2
                LB A, 0D9h
                CAL interp_word
                STB A, r2
                MOV off(052h), er1
                LB A, 0D9h
                MOV X1, #05EF7h
                CAL interp_word
                STB A, off(054h)
                VCAL 3
                MOV X1, #05892h
                MOV X2, #05884h
                JBR off(016h).3, housekeeping_call_load_ramd9_3
                MOV X1, #058AEh
                MOV X2, #058A0h
housekeeping_call_load_ramd9_3:
                LB A, 0D9h
                CAL interp_word
                STB A, r2
                MOV X1, X2
                LB A, 0D9h
                CAL interp_word
                STB A, ACCH
                LB A, r2
                MOV 14[USP], A
                VCAL 3
                MOV X1, #05670h
                MOV X2, #05662h
                JBR off(016h).3, housekeeping_call_load_ramd9_4
                MOV X1, #0568Ch
                MOV X2, #0567Eh
housekeeping_call_load_ramd9_4:
                LB A, 0D9h
                CAL interp_word
                STB A, r2
                MOV X1, X2
                LB A, 0D9h
                CAL interp_word
                STB A, ACCH
                LB A, r2
                MOV 12[USP], A
                VCAL 3
                LB A, 0D9h
                MOV X1, #05626h
                CMPCB A, 00002h[X1]
                MB off(019h).5, C
                CAL interp_word
                STB A, -3[USP]
                LB A, 0D9h
                MOV X1, #057FEh
                VCAL 0
                STB A, -46[USP]
                VCAL 3
                LB A, 0D9h
                STB A, r2
                MOV X1, #054A2h
                CAL interp_word
                STB A, -24[USP]
                LB A, r2
                MOV X1, #054B4h
                CAL interp_word
                STB A, -23[USP]
                LB A, r2
                MOV X1, #054C6h
                CAL interp_word
                STB A, -22[USP]
                VCAL 3
                LB A, 0D9h
                STB A, r2
                MOV X1, #054D8h
                CAL interp_word
                STB A, -21[USP]
                LB A, r2
                MOV X1, #059B4h
                CAL interp_word
                STB A, -20[USP]
                LB A, r2
                MOV X1, #054EAh
                CAL interp_word
                STB A, -1[USP]
                VCAL 3
                LB A, 0D9h
                STB A, r2
                MOV X1, #0581Bh
                JBS off(016h).3, housekeeping_call_interp_word
                MOV X1, #0580Dh
housekeeping_call_interp_word:
                CAL interp_word
                STB A, 9[USP]
                LB A, r2
                MOV X1, #05837h
                JBS off(016h).3, housekeeping_call_interp_word_2
                MOV X1, #05829h
housekeeping_call_interp_word_2:
                CAL interp_word
                STB A, 10[USP]
                VCAL 3
                LB A, 0D9h
                STB A, r2
                MOV X1, #05845h
                JBS off(016h).3, housekeeping_call_interp_word_3
                MOV X1, #05853h
housekeeping_call_interp_word_3:
                CAL interp_word
                STB A, 11[USP]
                LB A, r2
                MOV X1, #057A3h
                VCAL 0
                STB A, 4[USP]
                VCAL 3
                LB A, 0D9h
                MOV X1, #057B5h
                VCAL 0
                STB A, 6[USP]
                LB A, 0D9h
                MOV X1, #06329h
                CAL interp_word
                STB A, -19[USP]
                LB A, 0D9h
                MOV X1, #0550Ah
                CAL interp_word
                STB A, 116[USP]
                VCAL 3
                LB A, 0D9h
                MOV X1, #05AA6h
                VCAL 0
                STB A, -52[USP]
                VCAL 3
housekeeping_call_load_ramd8:
                LB A, 0D8h
                MOV X1, #05E39h
                VCAL 0
                STB A, off(07Ch)
                LB A, 0BCh
                MOV X1, #05E4Bh
                VCAL 1
                STB A, off(092h)
                VCAL 3
                LB A, #03Ah
                JBS off(021h).0, threshold_bank_cmp_acc_ram36_2
                LB A, #040h
threshold_bank_cmp_acc_ram36_2:
                CMPB A, off(036h)
                MB off(021h).0, C
                LB A, #088h
                JBS off(021h).1, threshold_bank_cmp_acc_ram35
                LB A, #090h
threshold_bank_cmp_acc_ram35:
                CMPB A, off(035h)
                MB off(021h).1, C
                CLRB A
                JGE threshold_bank_store_ram3a
                JBR off(021h).0, threshold_bank_store_ram3a
                JBS off(013h).1, threshold_bank_store_ram3a
                LB A, 0D8h
                MOV X1, #05F51h
                CAL interp_word
threshold_bank_store_ram3a:
                STB A, off(03Ah)
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                LB A, #074h
                JBS off(020h).5, threshold_bank_cmp_acc_ram36_3
                LB A, #080h
threshold_bank_cmp_acc_ram36_3:
                CMPB A, off(036h)
                MB off(020h).5, C
                LB A, #0C2h
                JBS off(020h).6, threshold_bank_cmp_acc_ram36_4
                LB A, #0C6h
threshold_bank_cmp_acc_ram36_4:
                CMPB A, off(036h)
                MB off(020h).6, C
                LB A, #0C8h
                J ign_dispatch_warm_if_ram22_b6_set
                DB  000h,000h
threshold_bank_cmp_acc_ram35_2:
                CMPB A, off(035h)
                CLRB A
                J battery_voltage_check_flag_ram20_b7
housekeeping_call_branch:
                JGE div_scale_store_ram43
                CLR A
                J ign_dispatch_warm_set_dp
housekeeping_call_load_ind_3:
                LB A, [DP]
                CMPB A, #0FAh
                JGE div_scale_default
                SUBB A, #007h
                JGE div_scale_calc1
                CLRB A
div_scale_calc1:
                MOVB r0, #051h
                DIVB
                JBR off(020h).5, div_scale_gate_common
                MOVB r0, #01Bh
                LB A, r1
                DIVB
                JBR off(020h).6, div_scale_gate_common
                MOVB r0, #009h
                LB A, r1
                DIVB
div_scale_gate_common:
                CMPB A, #003h
                JLT div_scale_mul_final
div_scale_default:
                LB A, #002h
div_scale_mul_final:
                MOVB r0, #008h
                MULB
                NOP
                NOP
                NOP
                VCAL 6
div_scale_store_ram43:
                STB A, off(043h)
                LB A, #005h
                MOV X1, #00004h
                JBS off(016h).3, gear_detect_store_ram4f
                LB A, #001h
                CLR X1
                JBS off(017h).5, gear_detect_store_ram4f
                JBS off(014h).0, gear_detect_store_ram4f
                MOVB r1, 0CCh
                CLRB r0
                L A, 0C4h
                MUL
                L A, er1
                MOV DP, #00004h
gear_detect_loop:
                CMPC A, GearRatios[X1]
                JLT gear_detect_index_calc
                INC X1
                INC X1
                JRNZ DP, gear_detect_loop
gear_detect_index_calc:
                SRL X1
                L A, X1
                LB A, ACC
                ADDB A, #001h
gear_detect_store_ram4f:
                STB A, off(04Fh)
                LCB A, GearTipInScale[X1]
                STB A, off(050h)
                LB A, 0DBh
                MOV X1, #05ED5h
                CAL interp_word
                STB A, off(04Bh)
                VCAL 3
                JBS off(017h).4, threshold_bank_load_imm
                LB A, 0BEh
                CMPB A, #04Ah
                JLT housekeeping_call_cmp_acc_imm_2
                SB -87[USP].3
housekeeping_call_cmp_acc_imm_2:
                CMPB A, #04Bh
                JLT threshold_bank_load_imm
                SB -87[USP].0
threshold_bank_load_imm:
                LB A, #0A0h
                JBS off(023h).2, threshold_bank_cmp_acc_ram36_5
                LB A, #0D8h
threshold_bank_cmp_acc_ram36_5:
                CMPB A, off(036h)
                MB off(023h).2, C
                CLR A
                MOV X1, #StockRevLimitA
                MOV X2, #StockRevLimitB
                JBR off(01Fh).1, revlimit_table_select
                MOV X1, #StockRevLimitC
                MOV X2, #StockRevLimitD
revlimit_table_select:
                LC A, 00002h[X1]
                MOV DP, A
                LC A, 00002h[X2]
                JBS off(02Dh).1, housekeeping_call_set_ind_2
                JBR off(017h).5, housekeeping_call_if_ram14_b0_set
housekeeping_call_set_ind_2:
                MOVB 49[USP], #00Ch
                SJ revlimit_table_select_and_ie
housekeeping_call_if_ram14_b0_set:
                JBS off(014h).0, revlimit_table_select_and_ie
                LB A, 74[USP]
                JNE revlimit_table_select_load_rambc
                MOVB 74[USP], #014h
                JBS off(012h).5, revlimit_table_select_if_ram23_b2_clr
                CMPB 0D9h, #044h
                JGE revlimit_table_select_set_ind
revlimit_table_select_if_ram23_b2_clr:
                JBR off(023h).2, revlimit_table_select_set_ind
                LB A, 49[USP]
                JNE callhelper_rom_load_ind
                L A, 20[USP]
                CAL ram_window
                MOV DP, A
                L A, 18[USP]
                MOV X1, X2
                CAL ram_window
                SJ revlimit_table_select_and_ie
revlimit_table_select_set_ind:
                MOVB 49[USP], #00Ch
callhelper_rom_load_ind:
                LC A, 00002h[X1]
                MOV er0, A
                L A, 20[USP]
                CAL alu_2
                MOV DP, A
                LC A, 00002h[X2]
                ST A, er0
                L A, 18[USP]
                CAL alu_2
revlimit_table_select_and_ie:
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                ST A, 18[USP]
                L A, DP
                ST A, 20[USP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
revlimit_table_select_load_rambc:
                LB A, 0BCh
                MOV X1, #058D4h
                VCAL 1
                STB A, 16[USP]
                VCAL 3
                LB A, 0BCh
                MOV X1, #0569Eh
                CAL interp_word
                STB A, -25[USP]
                LB A, 0BCh
                MOV X1, #057E5h
                VCAL 1
                STB A, 1[USP]
                LB A, 0BCh
                MOV X1, #05622h
                VCAL 1
                STB A, -2[USP]
                VCAL 3
                MOV X1, #055A6h
                CMPB 0CCh, #00Fh
                JLT iat_table_select
                MOV X1, #055AAh
                CMPB 0CCh, #00Fh
                JLT iat_table_select
                MOV X1, #055AEh
iat_table_select:
                LB A, 0D8h
                VCAL 1
                CMPB 0D9h, A
                MB off(019h).1, C
                LB A, 0D8h
                MOV X1, #05516h
                VCAL 0
                MOV DP, #003EAh
                STB A, [DP]
                LB A, 0D8h
                MOV X1, #05531h
                VCAL 0
                INC DP
                INC DP
                STB A, [DP]
                LB A, 0D8h
                MOV X1, #0554Ch
                VCAL 0
                INC DP
                INC DP
                STB A, [DP]
                VCAL 3
                CLR A
                LB A, #0C2h
                JBS off(023h).4, iat_table_select_cmp_acc_ram36
                LB A, #0C6h
iat_table_select_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(023h).4, C
                LCB A, IdleControlScale
                SRLB A
                SRLB A
                CLRB r2
                MOV DP, #003CEh
                LB A, [DP]
                JLT knock_retard_check
                CMPB A, #0F0h
                JLT knock_div_calc1
                LB A, #076h
knock_div_calc1:
                MOVB r0, #030h
                DIVB
                JBS off(023h).4, knock_table_index
                SRLB A
                LB A, r1
                JGE knock_div_calc2
                LB A, #02Fh
                SUBB A, r1
knock_div_calc2:
                MOVB r0, #009h
                DIVB
                ADDB A, #006h
knock_table_index:
                SLLB A
                EXTND
                LC A, KnockFuelMultiplier[ACC]
                SJ housekeeping_call_store_ind
knock_retard_check:
                ADDB A, #080h
                STB A, r2
                L A, #08000h
housekeeping_call_store_ind:
                ST A, -32[USP]
                MOVB off(042h), r2
                MOV DP, #003D8h
                LB A, [DP]
                JBS off(019h).3, knock_result_add_acc
                LB A, 0E3h
knock_result_add_acc:
                ADDB A, #080h
                STB A, r0
                LCB A, OptionFlagsFromBytes
                JEQ housekeeping_call_store_ind_2
                LCB A, IdleControlScale
                SRLB A
                CLRB A
                XCHGB A, r0
                JLT housekeeping_call_store_ind_2
                CLRB A
housekeeping_call_store_ind_2:
                STB A, -65[USP]
                LB A, r0
                STB A, -55[USP]
                CLRB A
                MOV DP, #003D7h
                LCB A, IdleControlScale
                NOP
                MB C, ACC.3
                JGE housekeeping_call_clear_acc
                LB A, [DP]
                MOVB r0, #080h
                MULB
                L A, ACC
                ADD A, #0C000h
                ST A, er0
                MOV off(084h), er0
                CLR A
                LB A, #076h
                SJ knock_div_calc3
housekeeping_call_clear_acc:
                CLR A
                ST A, off(084h)
                LB A, [DP]
                CMPB A, #0F0h
                JLT knock_div_calc3
                LB A, #076h
knock_div_calc3:
                MOVB r0, #030h
                DIVB
                STB A, r2
                SRLB A
                LB A, r1
                JGE knock_div_calc4
                LB A, #02Fh
                SUBB A, r1
knock_div_calc4:
                MOVB r0, #009h
                DIVB
                ADDB A, #006h
                SLLB A
                EXTND
                MOV X1, #KnockLevels
                JBR off(016h).3, knock_div_calc4_if_ram16_b0_set
                MOV X1, #KnockLevelsAuto
knock_div_calc4_if_ram16_b0_set:
                JBS off(016h).0, knock_table2d_lookup
                ADD X1, #00024h
knock_table2d_lookup:
                MOV X2, X1
                ADD X1, A
                LC A, [X1]
                ST A, er0
                ADD X1, #0000Ch
                LC A, [X1]
                ST A, er2
                LB A, r2
                SLLB A
                EXTND
                ADD X2, A
                LC A, [X2]
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                ST A, -10[USP]
                L A, er0
                ST A, -8[USP]
                L A, er2
                ST A, 114[USP]
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                LB A, 0DBh
                MOV X1, #056B6h
                VCAL 0
                STB A, -60[USP]
                VCAL 3
                MOV DP, #003CAh
                LB A, [DP]
                STB A, 0DAh
                JBR off(019h).3, injidx_gate2
                MOV DP, #003AFh
                LB A, [DP]
                CMPB A, #031h
                JNE injidx_gate1
                SB off(023h).3
                SB off(019h).0
                RB off(023h).1
                SJ injidx_flag_set_ram23_b0
injidx_gate1:
                JBR off(023h).3, housekeeping_call_if_ram1d_b4_set
injidx_gate2:
                RB off(023h).3
injidx_flag_clear_ram19_b0:
                RB off(019h).0
                SB off(023h).1
injidx_flag_set_ram23_b0:
                SB off(023h).0
                J vss_ect_stamp
housekeeping_call_if_ram1d_b4_set:
                JBS off(01Dh).4, injidx_flag_clear_ram19_b0
                LB A, off(0C1h)
                JEQ sensor_fault_check
                RB off(019h).0
                RB off(023h).1
injidx_flag_set2:
                RB off(023h).0
                MOVB off(0C2h), #064h
                SJ vss_ect_stamp
; Sensor fault / compensation check: the flag matrix 017h.5/019h.0/023h.1/016h.6/018h.0/01Dh.2
; (sensor-fault and state flags) decides the compensation; calls corr_map_lookup (0x07F6A map) and
; the flag pairs 023h.0/019h.0 updates.
sensor_fault_check:
                JBS off(017h).5, injidx_flag_set2
                JBS off(019h).0, vss_ect_gate
                JBR off(023h).1, injidx_gate6
                JBS off(016h).6, injidx_gate5
                JBS off(018h).0, vss_ect_gate
injidx_gate5:
                JBR off(01Dh).2, vss_ect_gate
                RB off(019h).0
                RB off(023h).1
                SB off(023h).0
injidx_gate6:
                JBR off(016h).6, closeloopnarrow_check
                JBS off(019h).0, closeloopnarrow_check
                JBS off(023h).1, closeloopnarrow_check
                JBS off(023h).0, closeloopnarrow_check
                JBR off(019h).2, injidx_stamp_set_ramc2
                JBR off(019h).1, injidx_stamp_set_ramc2
                JBS off(01Dh).2, injidx_load_ramc2
injidx_stamp_set_ramc2:
                MOVB off(0C2h), #064h
                SJ closeloopnarrow_check
injidx_load_ramc2:
                LB A, off(0C2h)
                JNE closeloopnarrow_check
                LB A, #033h
                SJ closeloopnarrow_result
closeloopnarrow_check:
                LB A, #01Ch
                JBS off(016h).0, closeloopnarrow_result
                LB A, #01Ch
closeloopnarrow_result:
                CMPB A, 0DAh
                JLT vss_ect_gate
                SB off(019h).0
vss_ect_gate:
                CMPB 0D9h, #028h
                JGE vss_ect_stamp
                CMPB 0CCh, #005h
                JGE vss_ect_stamp
                CMPB off(036h), #080h
                JLT vss_ect_stamp
                JBR off(01Dh).2, vss_ect_stamp
                LB A, off(0B6h)
                JNE idle_state_defaults
                SB off(019h).0
                RB off(023h).1
                SJ idle_state_defaults
vss_ect_stamp:
                MOVB off(0B6h), #004h
idle_state_defaults:
                MOVB r0, #005h
                MOVB r1, #032h
                MOVB r2, #032h
                MOVB r3, #01Dh
                JBS off(016h).0, idle_state_defaults_if_ram1d_b1_clr
                MOVB r3, #01Dh
idle_state_defaults_if_ram1d_b1_clr:
                JBR off(01Dh).1, idle_stage_alt_start
                JBR off(018h).0, idle_stage_alt_start
                MOVB off(0BFh), r1
                MOVB off(0C0h), r2
                JBR off(019h).0, idle_stage_set_ramb7
                JBS off(01Eh).4, idle_stage_cmp_ramda_imm
                L A, -40[USP]
                CMP A, #0BC15h
                JGE idle_stage_cmp_ramda_imm
                CMP A, #05A00h
                JLE idle_stage_cmp_ramda_imm
                LB A, r3
                CMPB A, 0DAh
                JLT idle_stage_load_ramb7
idle_stage_set_ramb7:
                MOVB off(0B7h), r0
idle_stage_load_ramb7:
                LB A, off(0B7h)
                SJ idle_stage_set_ramd4
idle_stage_alt_start:
                MOVB off(0B7h), r0
                JBR off(01Ch).2, idle_stage_set_rambf
                MOVB off(0C0h), r2
                JBR off(019h).0, idle_stage_bf_set_rambf
                LB A, r3
                CMPB A, 0DAh
                JLT idle_stage_bf_load_rambf
idle_stage_bf_set_rambf:
                MOVB off(0BFh), r1
idle_stage_bf_load_rambf:
                LB A, off(0BFh)
                SJ idle_stage_set_ramd4
idle_stage_set_rambf:
                MOVB off(0BFh), r1
                JBR off(019h).0, idle_stage_set_ramc0
                JBR off(01Ch).6, sensor_fault_check_load_ramc0
idle_stage_set_ramc0:
                MOVB off(0C0h), r2
sensor_fault_check_load_ramc0:
                LB A, off(0C0h)
idle_stage_set_ramd4:
                MOVB off(0D4h), #050h
                SJ idle_stage_branch
idle_stage_cmp_ramda_imm:
                CMPB 0DAh, #04Dh
                JLE idle_stage_load_ramd4
                CLRB A
                NOP
                NOP
                SJ idle_stage_set_ramd4
idle_stage_load_ramd4:
                LB A, off(0D4h)
idle_stage_branch:
                JNE gio_fuelpump_dispatch
                RB off(019h).0
                SB off(023h).1
gio_fuelpump_dispatch:
                VCAL 3
                RC
                LB A, off(0C6h)
                JNE fuelpump_relay_drive
                JBS off(011h).0, fuelpump_relay_drive
                MB C, off(017h).4
fuelpump_relay_drive:
                MB P0.7, C
                JBS off(010h).7, sensor_fault_check_load_imm
                JBS off(018h).6, fuelpump_state_active
                MOV DP, #003D5h
                LB A, [DP]
                CMPB A, #0FFh
                JGT fuelpump_gate4
                CMPB A, #0FCh
                JGE fuelpump_gate4_rom_load_optionidlestart
fuelpump_gate4:
                JBS off(030h).6, fuelpump_state_active
fuelpump_gate4_rom_load_optionidlestart:
                LCB A, OptionFlagsFromBytes
                JEQ flag_dispatch_if_ram11_b0_set
                LB A, 0AFh
                JNE fuelpump_state_active
flag_dispatch_if_ram11_b0_set:
                JBS off(011h).0, fuelpump_state_store_ramc6
                JBS off(017h).4, fuelpump_state_check
fuelpump_state_store_ramc6:
                STB A, off(0C6h)
fuelpump_state_check:
                RC
                LB A, off(0C6h)
                JEQ fuelpump_state_active_flag_p1_b4
fuelpump_state_active:
                SC
fuelpump_state_active_flag_p1_b4:
                MB P1.4, C
sensor_fault_check_load_imm:
                LB A, #014h
                JBS off(026h).0, rpm_threshold_cmp_acc_ramcc
                LB A, #019h
rpm_threshold_cmp_acc_ramcc:
                CMPB A, 0CCh
                MB off(026h).0, C
                LB A, #010h
                JBS off(026h).1, rpm_threshold_cmp_acc_ramcc_2
                LB A, #020h
rpm_threshold_cmp_acc_ramcc_2:
                CMPB A, 0CCh
                MB off(026h).1, C
                LB A, #026h
                JBS off(026h).2, rpm_threshold_cmp_acc_ramd1
                LB A, #07Fh
rpm_threshold_cmp_acc_ramd1:
                CMPB A, 0D1h
                MB off(026h).2, C
                LB A, #073h
                JBS off(026h).3, sensor_fault_check_cmp_acc_ram36
                LB A, #080h
sensor_fault_check_cmp_acc_ram36:
                CMPB A, off(036h)
                J timer_state_reinit_flag_ram26_b3
sensor_fault_check_load_imm_2:
                L A, #00EA6h
                JBS off(026h).5, sensor_fault_check_cmp_ramc4_acc
                L A, #00C35h
sensor_fault_check_cmp_ramc4_acc:
                CMP 0C4h, A
                MB off(026h).5, C
                CMPB 0F3h, #032h
                JLT accut_reset_clear_ramc3
                J timer_state_reinit_if_ram26_b6_set
sensor_fault_check_cmp_ramd9_imm:
                CMPB 0D9h, #013h
                JGE sensor_fault_check_goto_next
                JBR off(026h).0, sensor_fault_check_goto_next
                JBS off(026h).3, accut_reset_clear_ramf7
sensor_fault_check_goto_next:
                J flag_dispatch_if_ram18_b7_set
sensor_fault_check_clear_acc:
                CLRB A
                JBS off(026h).1, accut_store_ramc3
                LB A, #028h
accut_store_ramc3:
                STB A, off(0C3h)
                SJ sensor_fault_check_if_ram26_b5_set
accut_check_load_ramc3:
                LB A, off(0C3h)
                JNE accut_reset_clear_ramf7
sensor_fault_check_if_ram26_b5_set:
                JBS off(026h).5, accut_check_if_ram11_b2_clr
                RB off(026h).4
                SJ accut_result_common
accut_check_if_ram11_b2_clr:
                JBR off(011h).2, accut_common
                SB off(026h).4
                LB A, off(0F6h)
                JNE accut_result_common
                MOVB off(0F7h), #028h
accut_delay_check:
                SB off(01Bh).0
                RC
                SJ accut_output_drive
accut_reset_clear_ramc3:
                CLRB off(0C3h)
accut_reset_clear_ramf7:
                CLRB off(0F7h)
accut_common:
                RB off(026h).4
                LB A, off(0F7h)
                JNE accut_delay_check
                MOVB off(0F6h), #032h
accut_result_common:
                RB off(01Bh).0
                SC
accut_output_drive:
                MB P0.0, C
                LB A, #000h
                JBS off(0EDh).4, sensor_fault_check_cmp_acc_ram36_2
                LB A, #000h
sensor_fault_check_cmp_acc_ram36_2:
                CMPB A, off(036h)
                MB off(0EDh).4, C
                NOP
                LB A, #000h
                JBS off(0EDh).5, sensor_fault_check_cmp_acc_ramcc
                LB A, #000h
sensor_fault_check_cmp_acc_ramcc:
                CMPB A, 0CCh
                MB off(0EDh).5, C
                JBS off(017h).5, purge_result_rc
                JBS off(012h).5, sensor_fault_check_if_ram18_b0_clr
                CMPB 0D9h, #000h
                JGE purge_result_rc
sensor_fault_check_if_ram18_b0_clr:
                JBR off(018h).0, sensor_fault_check_cmp_ramd9_imm_2
                JBR off(01Eh).4, sensor_fault_check_cmp_ramd9_imm_2
                JBR off(019h).0, purge_result_rc
sensor_fault_check_cmp_ramd9_imm_2:
                CMPB 0D9h, #0FFh
                JGE sensor_fault_check_goto_next_2
                CMPB 0D8h, #0FFh
                JGE sensor_fault_check_goto_next_2
                JBS off(01Dh).5, sensor_fault_check_goto_next_2
                CLRB A
                JBS off(0EDh).5, sensor_fault_check_store_ramd5
                LB A, #000h
sensor_fault_check_store_ramd5:
                STB A, off(0D5h)
                SJ sensor_fault_check_cmp_ind_imm
sensor_fault_check_goto_next_2:
                J timer_state_reinit_load_ramd5
                DB  000h
sensor_fault_check_cmp_ind_imm:
                CMP 92[USP], #005DCh
                JLT purge_result_rc
                CMPB off(0B3h), #005h
                JNE purge_result_sc
                CMPB off(0CBh), #019h
                JLT purge_result_rc
purge_result_sc:
                SC
                SJ sensor_fault_check_flag_p0_b1
purge_result_rc:
                RC
sensor_fault_check_flag_p0_b1:
                MB P0.1, C
                LCB A, 05489h
                JEQ sensor_fault_check_vcal3
                LB A, #0D7h
                JBR off(0EEh).2, sensor_fault_check_cmp_ram36_acc
                LB A, #0DCh
sensor_fault_check_cmp_ram36_acc:
                CMPB off(036h), A
                MB off(0EEh).2, C
                JBS off(0EEh).3, sensor_fault_check_xor_pswh
                MB P4.3, C
                SJ sensor_fault_check_vcal3
sensor_fault_check_xor_pswh:
                XORB PSWH, #080h
                MB P0.5, C
sensor_fault_check_vcal3:
                VCAL 3
                LB A, #048h
                MOVB r1, #048h
                JBS off(024h).0, vss_band_if_ram16_b3_set
                LB A, #055h
                MOVB r1, #055h
vss_band_if_ram16_b3_set:
                JBS off(016h).3, sensor_fault_check_cmp_acc_ram36_3
                LB A, r1
sensor_fault_check_cmp_acc_ram36_3:
                CMPB A, off(036h)
                MB off(024h).0, C
                LB A, #0A0h
                JBS off(024h).1, sensor_fault_check_cmp_acc_ram36_4
                LB A, #0B0h
sensor_fault_check_cmp_acc_ram36_4:
                CMPB A, off(036h)
                MB off(024h).1, C
                MOVB r0, 0CCh
                LB A, #00Dh
                JBS off(024h).2, sensor_fault_check_cmp_acc_r0
                LB A, #00Fh
sensor_fault_check_cmp_acc_r0:
                CMPB A, r0
                MB off(024h).2, C
                LB A, #049h
                JBS off(024h).3, sensor_fault_check_cmp_acc_r0_2
                LB A, #04Bh
sensor_fault_check_cmp_acc_r0_2:
                CMPB A, r0
                MB off(024h).3, C
                LB A, #049h
                JBS off(024h).4, sensor_fault_check_cmp_acc_r0_3
                LB A, #04Bh
sensor_fault_check_cmp_acc_r0_3:
                CMPB A, r0
                MB off(024h).4, C
                LB A, #082h
                JBS off(024h).5, sensor_fault_check_cmp_ramdf_acc
                LB A, #07Ah
sensor_fault_check_cmp_ramdf_acc:
                CMPB 0DFh, A
                MB off(024h).5, C
                LB A, #026h
                JBS off(024h).6, sensor_fault_check_cmp_ramd9_acc
                LB A, #024h
sensor_fault_check_cmp_ramd9_acc:
                CMPB 0D9h, A
                MB off(024h).6, C
                SB PSWL.4
                JBR off(017h).6, sensor_fault_check_set_ram25_b1
                JBS off(017h).4, sensor_fault_check_set_ram25_b1
                JBR off(018h).7, state_dispatch2
sensor_fault_check_set_ram25_b1:
                SB off(025h).1
                J state_result_clear5
state_dispatch2:
                JBR off(024h).2, state_cce_set2b
                JBS off(01Ch).2, state_dispatch3
                JBR off(016h).3, state_cce_set2b
                JBR off(01Eh).1, state_cce_set2b
state_dispatch3:
                JBR off(024h).0, state_cce_set2b
                JBS off(024h).4, state_cce_set2
                JBR off(024h).6, state_cce_set2
                JBS off(025h).0, state_cce_set2
                LB A, off(0CEh)
                JNE state_ccf_gate
                MOVB off(0CFh), #002h
sensor_fault_check_clear_pswl_b4:
                RB PSWL.4
                SJ sensor_fault_check_set_ramcc
state_cce_set2:
                MOVB off(0CEh), #002h
sensor_fault_check_set_ramcc:
                MOVB off(0CCh), #009h
                SJ state_set_ramba
state_cce_set2b:
                MOVB off(0CEh), #002h
state_ccf_gate:
                LB A, off(0CFh)
                JNE sensor_fault_check_clear_pswl_b4
                NOP
                NOP
                LB A, off(0CCh)
                JEQ state_ccc_check
                JBR off(025h).0, state_dispatch4
                SJ state_set_ramba
state_ccc_check:
                JBR off(024h).5, sensor_fault_check_if_ram16_b3_clr
                MOVB off(0CDh), #014h
sensor_fault_check_set_ram25_b0:
                SB off(025h).0
                SJ state_set_ramba
sensor_fault_check_if_ram16_b3_clr:
                JBR off(016h).3, state_ccd_check
                JBS off(011h).5, sensor_fault_check_set_ram25_b0
state_ccd_check:
                LB A, off(0CDh)
                JNE state_set_ramba
                JBS off(024h).2, state_ccd_check_clear_ram25_b0
                JBS off(025h).0, state_set_ramba
state_ccd_check_clear_ram25_b0:
                RB off(025h).0
state_dispatch4:
                JBS off(024h).3, state_if_ram25_b1_set
                JBS off(024h).1, state_if_ram25_b1_set
                CMPB 0D9h, #029h
                JGE state_if_ram25_b1_set
                CMPB 0D8h, #0A9h
                JGE state_if_ram25_b1_set
                JBS off(011h).2, state_if_ram25_b1_set
                LB A, off(0BAh)
                JEQ state_if_ram25_b1_set
                RB off(025h).1
state_result_set5:
                SB P0.2
                SJ sensor_fault_check_test_pswl_b4
state_set_ramba:
                MOVB off(0BAh), #016h
state_if_ram25_b1_set:
                JBS off(025h).1, state_load_ramd0
                SB off(025h).1
                MOVB off(0D0h), #003h
state_load_ramd0:
                LB A, off(0D0h)
                JNE state_result_set5
                CMPB off(099h), #01Eh
                JGT state_result_set5
state_result_clear5:
                RB P0.2
sensor_fault_check_test_pswl_b4:
                MB C, PSWL.4
                MB P0.3, C
                VCAL 3
                JBR off(019h).3, flags_set_ramb8_b2
                JBR off(016h).6, flags_set_ramb8_b2
                JBR off(017h).4, altc_condition_check
flags_set_ramb8_b2:
                SB 0B8h.2
                RB 0B3h.2
                SJ gio_p1_2_check
altc_condition_check:
                JBS off(015h).2, gio_p1_2_check
                JBS off(012h).5, gio_p1_2_check
                MB C, 0B0h.1
                JLT gio_p1_2_check
                CMPB 0D9h, #0C5h
                JGE gio_p1_2_check
                CMPB 0DBh, #0A7h
                JLT flags_flag_ram19_b2
gio_p1_2_check:
                RC
                SB P1.2
flags_flag_ram19_b2:
                MB off(019h).2, C
                VCAL 3
                JBS off(01Ah).6, state_if_ram1a_b7_set
                CMPB 0C5h, #012h
                JGE state_set_ramfb
                LB A, 0D7h
                CMPB A, #0FFh
                JGT state_set_ramfb
                CMPB A, #000h
                JLT state_set_ramfb
                MB C, P4.6
                JGE state_load_ramfb
state_set_ramfb:
                MOVB off(0FBh), #000h
                SJ state_if_ram1a_b7_set
state_load_ramfb:
                LB A, off(0FBh)
                JNE state_if_ram1a_b7_set
                SB off(01Ah).6
state_if_ram1a_b7_set:
                JBS off(01Ah).7, state_if_ram1a_b7_set_2
                JBS off(017h).5, state_if_ram13_b0_set
                JBS off(01Ah).6, state_if_ram24_b7_clr
state_if_ram13_b0_set:
                JBS off(013h).0, state_set_ram1a_b7
sensor_fault_check_set_ramdd:
                MOVB off(0DDh), #000h
                SJ state_if_ram1a_b7_set_2
state_if_ram24_b7_clr:
                JBR off(024h).7, sensor_fault_check_set_ramdd
                JBS off(01Dh).4, sensor_fault_check_set_ramdd
                LB A, off(0DDh)
                JNE state_if_ram1a_b7_set_2
state_set_ram1a_b7:
                SB off(01Ah).7
state_if_ram1a_b7_set_2:
                JBS off(01Ah).7, state_if_ram1a_b7_set_3
                JBR off(01Ah).6, state_set_ramde
                JBS off(017h).5, state_set_ramde
                JBS off(015h).1, altc_p46_check
                MB C, 0B3h.1
                JGE state_set_ramde
altc_p46_check:
                MB C, P4.6
                JGE state_set_ramde
                JBS off(018h).0, state_load_ramde
                JBS off(01Eh).2, state_set_ramde
state_load_ramde:
                LB A, off(0DEh)
                JNE state_if_ram1a_b7_set_3
                SB off(01Ah).7
                SJ state_if_ram1a_b7_set_3
state_set_ramde:
                MOVB off(0DEh), #000h
state_if_ram1a_b7_set_3:
                JBS off(01Ah).7, state_set_r0
                JBR off(01Ah).6, state_set_ramdf
                JBS off(017h).5, state_set_ramdf
                LB A, 0D7h
                CMPB A, #0FFh
                JGT state_set_ramdf
                CMPB A, #000h
                JLT state_set_ramdf
                JBR off(015h).0, state_set_ramdf
                JBS off(018h).0, state_dc_check2
                JBS off(01Eh).2, state_set_ramdf
state_dc_check2:
                CMPB A, #0FFh
                JGT state_load_ramdf
state_set_ramdf:
                MOVB off(0DFh), #000h
                SJ state_set_r0
state_load_ramdf:
                LB A, off(0DFh)
                JNE state_set_r0
                SB off(01Ah).7
state_set_r0:
                MOVB r0, #004h
                MOV DP, #0601Eh
                LB A, 0D9h
state_dec_dp:
                DEC DP
                DECB r0
                JEQ sensor_fault_check_load_ramfa
                CMPCB A, [DP]
                JGE state_dec_dp
sensor_fault_check_load_ramfa:
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                LB A, off(033h)
                ANDB A, #0FCh
                ORB A, r0
                STB A, off(033h)
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                CMPB 0D8h, #023h
                MB off(033h).2, C
                VCAL 3
                MOV DP, #003D5h
                LB A, [DP]
                CMPB A, #0FFh
                JGT sensor_fault_check_sc
                CMPB A, #0FCh
                JGE sensor_fault_check_test_ram14_b7
sensor_fault_check_sc:
                SC
                JBS off(030h).6, sensor_fault_check_set_dp
sensor_fault_check_test_ram14_b7:
                MB C, off(014h).7
sensor_fault_check_set_dp:
                MOV DP, #00324h
                MB [DP].0, C
                LB A, [DP]
                ANDB A, #0F1h
                STB A, [DP]
                L A, ADCR6
                ST A, 0BAh
                LB A, ADCR7H
                MOV DP, #003A4h
                STB A, [DP]
                LB A, ADCR2H
                MOV DP, #003A5h
                STB A, [DP]
                RC
                CLRB A
                MB C, off(011h).1
                XORB PSWH, #080h
                ROLB A
                ROLB A
                ROLB A
                MB C, off(011h).5
                ROLB A
                MB C, off(011h).4
                ROLB A
                MB C, off(010h).3
                XORB PSWH, #080h
                ROLB A
                MB C, off(011h).2
                ROLB A
                MB C, off(011h).0
                ROLB A
                JBS off(016h).3, sensor_fault_check_set_dp_2
                ANDB A, #08Fh
sensor_fault_check_set_dp_2:
                MOV DP, #003B0h
                STB A, [DP]
                RC
                CLRB A
                ROLB A
                MB C, P4.6
                XORB PSWH, #080h
                ROLB A
                MB C, off(02Ch).2
                ROLB A
                MB C, off(02Ch).0
                ROLB A
                MB C, off(010h).7
                ROLB A
                ROLB A
                ROLB A
                ROLB A
                MOV DP, #003B1h
                STB A, [DP]
                RC
                CLRB A
                MOV DP, #003B2h
                STB A, [DP]
                RC
                CLRB A
                MB C, P1.2
                XORB PSWH, #080h
                ROLB A
                MB C, P1.4
                ROLB A
                ROLB A
                ROLB A
                MB C, P0.1
                XORB PSWH, #080h
                ROLB A
                MB C, P0.0
                XORB PSWH, #080h
                ROLB A
                MB C, P0.7
                XORB PSWH, #080h
                ROLB A
                MOV DP, #003B3h
                STB A, [DP]
                RC
                CLRB A
                ROLB A
                MB C, P0.6
                XORB PSWH, #080h
                ROLB A
                MB C, P0.4
                XORB PSWH, #080h
                ROLB A
                ROLB A
                MB C, P1.0
                ROLB A
                MB C, off(0EEh).2
                ROLB A
                MB C, P0.3
                XORB PSWH, #080h
                ROLB A
                MB C, P0.2
                XORB PSWH, #080h
                ROLB A
                MOV DP, #003B4h
                STB A, [DP]
                RC
                CLRB A
                ROLB A
                ROLB A
                MOV DP, #003B5h
                STB A, [DP]
                RC
                CLRB A
                MOV DP, #003B6h
                STB A, [DP]
                RC
                CLRB A
                MB C, off(01Dh).0
                ROLB A
                MOV DP, #003B7h
                STB A, [DP]
                MOV X1, #061CDh
                MOV DP, #003A8h
sensor_fault_check_rom_load_ind:
                LCB A, [X1]
                MOVB [DP], A
                INC X1
                INC DP
                CMP X1, #061D0h
                JNE sensor_fault_check_rom_load_ind
                MOVB r0, #040h
                JBR off(019h).3, sensor_fault_check_set_dp_3
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
                NOP
                NOP
                NOP
                NOP
                NOP
                MOVB r0, #001h
                JBS off(016h).2, sensor_fault_check_set_dp_3
                MOVB r0, #002h
                JBR off(0EEh).3, sensor_fault_check_set_dp_3
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
                NOP
                NOP
                NOP
                NOP
                MOVB r0, #004h
sensor_fault_check_set_dp_3:
                MOV DP, #003ABh
                LB A, r0
                STB A, [DP]
                CLRB r0
                RC
                ROLB r0
                ROLB r0
                ROLB r0
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
                NOP
                NOP
                MB C, off(016h).5
                ROLB r0
                NOP
                NOP
                NOP
                ROLB r0
                MB C, off(017h).6
                ROLB r0
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                ROLB r0
                MB C, off(016h).3
                ROLB r0
                MOV DP, #003ACh
                LB A, r0
                STB A, [DP]
                L A, off(05Eh)
                SLL A
                JLT diag_clamp_ff
                SLL A
                JGE diag_clamp_acch
diag_clamp_ff:
                LB A, #0FFh
                SJ diag_set_dp
diag_clamp_acch:
                LB A, ACCH
diag_set_dp:
                MOV DP, #003ADh
                STB A, [DP]
                MOV DP, #0030Ch
                L A, [DP]
                SLL A
                JLT diag_clamp_load_imm
                SLL A
                JGE diag_clamp_acch2
diag_clamp_load_imm:
                LB A, #0FFh
                SJ sensor_fault_check_set_dp_4
diag_clamp_acch2:
                LB A, ACCH
sensor_fault_check_set_dp_4:
                MOV DP, #003AEh
                STB A, [DP]
                LB A, 0CCh
                JBR off(014h).0, sensor_fault_check_set_dp_5
                CLRB A
sensor_fault_check_set_dp_5:
                MOV DP, #0039Fh
                STB A, [DP]
                MOV DP, #003AFh
                LB A, [DP]
                CMPB A, #033h
                JEQ diag_sc
                CMPB A, #034h
                JEQ diag_sc
                CMPB A, #035h
                JEQ diag_sc
                CMPB A, #036h
                JNE diag_rc
diag_sc:
                SC
                SJ diag_flag_ram19_b7
diag_rc:
                RC
diag_flag_ram19_b7:
                MB off(019h).7, C
                VCAL 3
                MOV er1, 0B0h
                MOV er2, 0B2h
                JBR off(017h).5, sensor_fault_check_test_ramb7_b1
                AND er1, #0C5E2h
                AND 0B0h, #0C5E2h
                AND er2, #0040Bh
                AND 0B2h, #0040Bh
sensor_fault_check_test_ramb7_b1:
                MB C, 0B7h.1
                JGE dtc_scan_init
                CLR A
                ST A, 0B0h
                ST A, 0B2h
                ST A, er1
                ST A, er2
dtc_scan_init:
                MOVB r7, #001h
                MOV DP, #002CBh
dtc_scan_loop:
                SRL er2
                ROR er1
                JLT dtc_scan_found_check
                LB A, r7
                SUBB A, off(0B3h)
                JNE dtc_scan_load_r7
                STB A, off(0B3h)
                STB A, [DP]
dtc_scan_load_r7:
                LB A, r7
                SUBB A, 0F4h
                JNE dtc_scan_advance
                STB A, 0F4h
dtc_scan_advance:
                INCB r7
                CMPB r7, #01Ch
                JNE dtc_scan_loop
                SJ dtc_debounce_init
dtc_scan_found_check:
                LB A, off(0B3h)
                JEQ dtc_scan_new_code
                CMPB A, r7
                JNE dtc_scan_advance
                LB A, [DP]
                JNE dtc_debounce_init
                SJ dtc_debounce2_init
dtc_scan_new_code:
                CLR A
                LB A, r7
                STB A, off(0B3h)
                LCB A, TroubleCodeDebounce[ACC]
                STB A, [DP]
dtc_debounce_init:
                VCAL 3
                MOVB r7, #021h
                CLR A
                XCHG A, 0B4h
                JBS off(01Ch).6, dtc_debounce_mask_apply
                AND A, #081FFh
dtc_debounce_mask_apply:
                ST A, er0
                MB C, 0B7h.1
                JGE dtc_debounce_loop_start
                CLR er0
dtc_debounce_loop_start:
                MOV DP, #001D1h
dtc_debounce_loop:
                SRL er0
                JGE sensor_fault_check_clear_acc_2
                LB A, [DP]
                JEQ dtc_debounce2_init
                DECB [DP]
                SJ dtc_debounce_advance
sensor_fault_check_clear_acc_2:
                CLR A
                LB A, r7
                CMPB A, 0F4h
                JNE dtc_debounce_advance
                LCB A, TroubleCodeDebounce[ACC]
                SUBB A, [DP]
                JNE dtc_debounce_advance
                STB A, 0F4h
dtc_debounce_advance:
                INC DP
                INCB r7
                CMPB r7, #02Ch
                JNE dtc_debounce_loop
                MOVB r7, #030h
                MOV DP, #001DCh
                SRL er0
                SRL er0
                SRL er0
                SRL er0
                SRL er0
                JLT dtc_debounce2_check
                MOV [DP], #00BB3h
                LB A, 0F4h
                SUBB A, r7
                JNE dtc_scan_ie_restore_nop_goto_next
                STB A, 0F4h
dtc_scan_ie_restore_nop_goto_next:
                J dtc_scan_ie_restore_nop_set_dp
dtc_debounce2_check:
                L A, [DP]
                JNE dtc_scan_ie_restore_nop_goto_next
dtc_debounce2_init:
                LB A, #005h
                STB A, [DP]
                LB A, 0F4h
                JNE dtc_active_confirm
                LB A, r7
                STB A, 0F4h
                SJ dtc_scan_ie_restore_nop_set_dp
dtc_active_confirm:
                SUBB A, r7
                JNE dtc_scan_ie_restore_nop_set_dp
                STB A, 0F4h
                JBR off(02Dh).0, sensor_fault_check_and_ie
                JBS off(010h).7, sensor_fault_check_and_ie
                MOV DP, #0031Dh
                CMPB r7, #005h
                JEQ sensor_fault_check_set_ramed_b3
                CMPB r7, #030h
                JNE sensor_fault_check_and_ie
                SB off(0EEh).4
                MB C, [DP].1
                SJ sensor_fault_check_branch
sensor_fault_check_set_ramed_b3:
                SB off(0EDh).3
                MB C, [DP].0
sensor_fault_check_branch:
                JGE dtc_scan_ie_restore_nop_set_dp
                JBR off(0EDh).1, dtc_scan_ie_restore_nop_set_dp
sensor_fault_check_and_ie:
                AND IE, #00080h
                CLR A
                LB A, r7
                CMPB A, #030h
                JNE dtc_active_confirm_rom_load_ind
                MOV 92[USP], #00BB3h
                JBS off(0EEh).3, dtc_active_confirm_rom_load_ind
                SB 0B8h.5
                SJ dtc_scan_ie_restore
dtc_active_confirm_rom_load_ind:
                LCB A, TroubleCodeNumbers[ACC]
                JEQ dtc_scan_ie_restore
                STB A, r6
                SB off(032h).4
                SB off(032h).5
                CAL boot_quotient
                CMPB r6, #018h
                JEQ cfgvariant_apply_done
                CAL fuel_state_init
                CAL engine_state_init
                CAL boot_lookup_c
                INC DP
                L A, er0
                ST A, [DP]
cfgvariant_apply_done:
                RB off(032h).4
                RB off(032h).5
                CLR A
                LB A, r7
                LCB A, TroubleCodeNumbers[ACC]
                CMPB A, r6
                JNE selftest_fail_set_ramf5_6
dtc_scan_ie_restore:
                L A, 0F8h
                ST A, IE
dtc_scan_ie_restore_nop_set_dp:
                MOV DP, #0031Dh
                JBS off(02Dh).0, sensor_fault_check_set_r0
                RB off(0EDh).3
                RB off(0EEh).4
                CLRB [DP]
sensor_fault_check_set_r0:
                MOVB r0, [DP]
                MOVB r1, r0
                MOV DP, #00322h
                MOV X1, #0011Eh
calchecksum_loop:
                DEC DP
                DEC X1
                LB A, r0
                ADDB A, [DP]
                STB A, r0
                LB A, r1
                XORB A, [DP]
                STB A, r1
                LB A, 00000h[X1]
                STB A, r2
                LB A, [DP]
                XORB A, r2
                ANDB A, r2
                JNE selftest_fail_set_ramf5_6
                CMP DP, #0031Eh
                JNE calchecksum_loop
                DEC DP
                LB A, [DP]
                ANDB A, #0FCh
                JNE selftest_fail_set_ramf5_6
                INC DP
                LB A, [DP]
                ANDB A, #002h
                JNE selftest_fail_set_ramf5_6
                INC DP
                LB A, [DP]
                ANDB A, #008h
                JNE selftest_fail_set_ramf5_6
                INC DP
                LB A, [DP]
                ANDB A, #006h
                JNE selftest_fail_set_ramf5_6
                INC DP
                LB A, [DP]
                ANDB A, #088h
                JNE selftest_fail_set_ramf5_6
                INC DP
                L A, [DP]
                CMP A, er0
                JNE selftest_fail_set_ramf5_6
                VCAL 3
                CAL boot_lookup_c
                INC DP
                L A, [DP]
                CMP A, er0
                JEQ freezeframe_decode_start
selftest_fail_set_ramf5_6:
                MOVB 0F5h, #043h
                BRK
freezeframe_decode_start:
                VCAL 3
                SC
                JBS off(0EDh).3, sensor_fault_check_flag_ram18_b7
                JBS off(0EEh).4, sensor_fault_check_flag_ram18_b7
                L A, off(012h)
                ORB A, off(014h)
                ADD A, #0FFFFh
sensor_fault_check_flag_ram18_b7:
                MB off(018h).7, C
                JLT sensor_fault_check_load_ram12
                ANDB off(018h), #0BFh
                ANDB off(02Bh), #0EFh
                ANDB off(025h), #07Fh
                ANDB off(0ECh), #0FBh
                SJ prep_lowpower_seq
sensor_fault_check_load_ram12:
                L A, off(012h)
                AND A, #0FFFDh
                JNE sensor_fault_check_flag_ram18_b6
                L A, off(014h)
                AND A, #014F5h
                JNE sensor_fault_check_flag_ram18_b6
                RC
sensor_fault_check_flag_ram18_b6:
                MB off(018h).6, C
                SC
                L A, off(012h)
                AND A, #02054h
                JNE sensor_fault_check_flag_ram2b_b4
                JBS off(014h).0, sensor_fault_check_flag_ram2b_b4
                RC
sensor_fault_check_flag_ram2b_b4:
                MB off(02Bh).4, C
                SC
                JBS off(0EDh).3, sensor_fault_check_flag_ram25_b7
                JBS off(0EEh).4, sensor_fault_check_flag_ram25_b7
                L A, off(012h)
                JNE sensor_fault_check_flag_ram25_b7
                L A, off(014h)
                AND A, #014FDh
                JNE sensor_fault_check_flag_ram25_b7
                RC
sensor_fault_check_flag_ram25_b7:
                MB off(025h).7, C
                SC
                J vcal3_leanprotect_ratelimit_if_ramed_b3_set
sensor_fault_check_load_ram12_2:
                L A, off(012h)
                JNE sensor_fault_check_flag_ramec_b2
                L A, off(014h)
                AND A, #074F5h
                JNE sensor_fault_check_flag_ramec_b2
                RC
sensor_fault_check_flag_ramec_b2:
                MB off(0ECh).2, C
prep_lowpower_seq:
                SB off(030h).3
                JNE lowpower_trap_goto_main_loop_gate
                CAL wdt_kick
                L A, TM1
                ADD A, #00A00h
                ST A, TMR1
                MULB
                DIV
                DIV
                MB C, 0B7h.1
                JLT prep_lowpower_ie_config
                CAL inj_init_pattern
                MOVB 0F7h, #020h
prep_lowpower_ie_config:
                MOV 0FAh, #002A0h
                L A, #02BABh
                ST A, 0F8h
                CLRB TRNSIT
                CLR IRQ
                RB TCON0.2
                ST A, IE
lowpower_trap_goto_main_loop_gate:
                J main_loop_gate
; Sequential-injection pulse engine (CAL'd from engine_main_irq): TMR0 scheduling (TM0 - 1 -> TMR0),
; bank pattern 096h/017h bits, pulse words 010h/012h/014h, 0362h/0366h tables, 0A4h (0xFFFF = VSS
; lost), P2 injector drivers, TRNSIT edge detect, TCON0; entry inj_pulse_engine_b (0x49CB) is the
; cold-start variant (r0 = 0xFF).
inj_pulse_engine:
                JBR off(028h).2, injtimer_shift_path
; Cold-start entry into inj_pulse_engine (r0 = 0xFF pattern).
inj_pulse_engine_b:
                MOVB r0, #0FFh
                L A, off(09Eh)
                ST A, er1
                CMPB off(017h), #00Fh
                JNE injtimer_schedule_done
                L A, TM0
                SUB A, #00001h
                ST A, TMR0
                MOV X1, #00110h
                MOV DP, #00198h
                L A, [DP]
                CMP A, #000C0h
                JGE injtimer_bank1_check2
                CLR A
                ST A, [DP]
                INC DP
                INC DP
                L A, [DP]
                CMP A, #000C0h
                JGE injtimer_bank2_zero
                CLR A
                ST A, [DP]
                INC DP
                INC DP
                L A, [DP]
                CMP A, #000C0h
                JLT injtimer_bank3_check
                ST A, er1
                LB A, off(016h)
                SRLB A
                RORB off(016h)
                SJ injtimer_schedule_common
injtimer_shift_path:
                LB A, off(096h)
                SLLB A
                ROLB off(096h)
                LB A, off(016h)
                SLLB A
                ROLB off(016h)
                RT
injtimer_bank2_zero:
                ST A, er1
                LB A, off(016h)
                SRLB A
                RORB off(016h)
                SRLB A
                RORB off(016h)
                SJ injtimer_bank_mask_calc
injtimer_bank3_check:
                CLR A
                ST A, [DP]
                SJ injtimer_schedule_done
injtimer_bank1_check2:
                ST A, er1
                LB A, off(016h)
                SLLB A
                ROLB off(016h)
                CAL inj_bank_advance
                LB A, off(096h)
                SRLB A
                SRLB A
                ANDB r0, A
injtimer_bank_mask_calc:
                CAL inj_bank_advance
                LB A, off(096h)
                SRLB A
                ANDB r0, A
injtimer_schedule_common:
                CAL inj_bank_advance
                ANDB r0, off(096h)
injtimer_schedule_done:
                LB A, off(096h)
                SLLB A
                ROLB off(096h)
                LB A, r0
                ANDB A, off(096h)
                CMP off(09Eh), #000C0h
                JLT injenable_reset_all
                MOVB r1, off(017h)
                ANDB off(017h), A
                JBS off(02Ah).7, injenable_p2_update
                JBS off(024h).5, injenable_p2_update
                ANDB off(097h), A
                ORB off(02Ah), #001h
injenable_p2_update:
                LB A, off(097h)
                ORB A, #0F0h
                ANDB P2, A
                ANDB TRNSIT, #0FBh
                ANDB PSWH, #0FEh
                ORB TCON0, #004h
                L A, TM0
                ORB PSWH, #001h
                ANDB TCON0, #0FBh
                CMPB r1, #00Fh
                JEQ inj_accum2_direct
                SUB A, TMR0
                ADD A, er1
                JBR off(009h).0, inj_accum_check1
                JBR off(009h).2, inj_pulse_engine_b_if_ram09_b3_set
                J inj_pulse_engine_b_branch
injenable_reset_all:
                LB A, #00Fh
                STB A, off(017h)
                STB A, off(097h)
                ORB P2, A
                SB TCON0.2
                LB A, off(096h)
                XORB A, #0FFh
                MB C, ACC.7
                ROLB A
                STB A, off(016h)
                RB TCON0.2
                L A, #00001h
                SJ inj_pulse_engine_b_store_ram10
inj_accum2_direct:
                ADD A, er1
                ST A, TMR0
                SJ inj_p2_calc_start
inj_accum_check1:
                JBR off(009h).2, inj_accum_check1_branch
inj_pulse_engine_b_if_ram09_b3_set:
                JBS off(009h).3, inj_pulse_engine_b_if_ram09_b1_set
                JBS off(009h).1, inj_pulse_engine_b_branch_2
inj_accum_check1_branch:
                JGE inj_accum_direct_add
                SUB A, off(010h)
                JLT inj_pulse_engine_b_add_acc
                SUB A, off(012h)
                JGE inj_pulse_engine_b_cmp_acc_imm
                ADD A, off(012h)
                CMP A, #00100h
                JLT inj_pulse_engine_b_clear_acc
                ST A, off(012h)
                CLR A
                J inj_accum_store_ram14
inj_pulse_engine_b_add_acc:
                ADD A, off(010h)
                CMP A, #00100h
                JLT inj_pulse_engine_b_clear_acc_2
                ST A, off(010h)
inj_pulse_engine_b_clear_acc:
                CLR A
                ST A, off(012h)
                J inj_accum_store_ram14
inj_pulse_engine_b_cmp_acc_imm:
                CMP A, #00100h
                JGE inj_accum_store_ram14
                CLR A
                SJ inj_accum_store_ram14
inj_accum_direct_add:
                ADD TMR0, A
inj_pulse_engine_b_clear_acc_2:
                CLR A
                ST A, off(010h)
                ST A, off(012h)
                J inj_accum_store_ram14
inj_pulse_engine_b_branch:
                JGE inj_accum_check4_add_tmr0
                CMP A, #00100h
                JGE inj_pulse_engine_b_store_ram10
                CLR A
inj_pulse_engine_b_store_ram10:
                ST A, off(010h)
                L A, #00001h
                ST A, off(012h)
                J inj_accum_store_ram14
inj_accum_check4_add_tmr0:
                ADD TMR0, A
                CLR A
                ST A, off(010h)
                L A, #00001h
                ST A, off(012h)
                J inj_accum_store_ram14
inj_pulse_engine_b_if_ram09_b1_set:
                JBS off(009h).1, inj_pulse_engine_b_branch
inj_pulse_engine_b_branch_2:
                JGE inj_pulse_engine_b_add_tmr0
                SUB A, off(010h)
                JGE inj_pulse_engine_b_cmp_acc_imm_2
                ADD A, off(010h)
                CMP A, #00100h
                JGE inj_pulse_engine_b_store_ram10_2
inj_pulse_engine_b_clear_acc_3:
                CLR A
inj_pulse_engine_b_store_ram10_2:
                ST A, off(010h)
inj_accum2_zero2:
                CLR A
inj_accum2_store2:
                ST A, off(012h)
                L A, #00001h
inj_accum_store_ram14:
                ST A, off(014h)
inj_p2_calc_start:
                L A, off(010h)
                JNE inj_p2_calc_alt
                L A, off(012h)
                JEQ inj_p2_calc_check114
                LB A, off(016h)
                SRLB A
                SRLB A
                SRLB A
                ORB A, off(016h)
                J inj_p2_calc_or197
inj_p2_calc_alt:
                LB A, off(016h)
                SJ inj_p2_calc_or197
inj_p2_calc_check114:
                L A, off(014h)
                JEQ inj_p2_default_f
                LB A, off(016h)
                RORB A
                XORB A, #0FFh
inj_p2_calc_or197:
                ORB A, off(097h)
                ANDB A, #00Fh
inj_p2_drive_return:
                ORB P2, A
                RB off(02Ah).7
                RT
inj_p2_default_f:
                LB A, #00Fh
                SJ inj_p2_drive_return
inj_pulse_engine_b_cmp_acc_imm_2:
                CMP A, #00100h
                JLT inj_accum2_zero2
                SJ inj_accum2_store2
inj_pulse_engine_b_add_tmr0:
                ADD TMR0, A
                SJ inj_pulse_engine_b_clear_acc_3
; Bank table advance: X1 walks the 0x0360 word pairs (0x100 wrap), used by inj_pulse_engine to walk
; the injector pulse table.
inj_bank_advance:
                CLR A
                XCHG A, [DP]
                MOV X2, A
                INC DP
                INC DP
                L A, [DP]
                SUB A, X2
                JLT inj_wrap_clamp_zero
                CMP A, #00100h
                JGE inj_wrap_clamp_store_ind
inj_wrap_clamp_zero:
                CLR A
inj_wrap_clamp_store_ind:
                ST A, 00000h[X1]
                INC X1
                INC X1
                RT
; Phase bit countdown: r6 = 0x77 rotated/decrypted countdown used by the phase sequencer.
phase_countdown:
                MOVB r6, #077h
                JEQ bitreverse_return
bitreverse_loop:
                MB C, r6.7
                ROLB r6
                SUBB A, #001h
                JNE bitreverse_loop
bitreverse_return:
                LB A, r6
                RT
; VSS / RPM update (CAL'd from the engine interrupts): TMR2 capture (0EEh/0EFh pair), edge counter
; 0A2h (max 5), 0362h/0366h tables, 09Fh, speed scale (0A4h = 0xFFFF on loss), 0B4h.0/01Fh.2 flags,
; TMR2 reschedule.
vss_rpm_update:
                L A, TMR2
                JBR off(01Fh).2, vss_rpm_update_store_er3
                L A, 0F0h
vss_rpm_update_store_er3:
                ST A, er3
                JBS off(00Fh).7, rpm_resync_gate
                MB C, IRQH.0
                JGE rpm_resync_gate
                INCB 0AEh
                SB 0B6h.0
rpm_resync_gate:
                SB off(028h).3
                JEQ rpm_resync_common
                SUB A, 0EEh
                JBR off(01Fh).2, rpm_resync_tcon2_check
                CLRB r1
                MOVB r0, 0AEh
                SBCB r0, #000h
                MOV er2, #00006h
                DIV
                CMPB r0, #000h
                JEQ rpm_period_reset_calc
                CLR A
rpm_period_reset_calc:
                ST A, off(036h)
                MOV X1, #0000Ch
rpm_period_reset_loop:
                DEC X1
                DEC X1
                ST A, 00360h[X1]
                JNE rpm_period_reset_loop
                SJ rpm_resync_common
rpm_resync_tcon2_check:
                MB C, TCON2.2
                JGE rpm_resync_store136
                CLR A
rpm_resync_store136:
                ST A, off(036h)
                LB A, 0A2h
                SLLB A
                EXTND
                MOV X1, A
                L A, off(036h)
                ST A, 00360h[X1]
rpm_resync_common:
                L A, er3
                ST A, 0EEh
                CLRB 0AEh
                CMPB 0A2h, #005h
                JNE vss_rpm_update_if_rama3_b2_set
                SLLB off(0A3h)
vss_rpm_update_if_rama3_b2_set:
                JBS off(0A3h).2, crank_set_dp
                MOV DP, #00358h
                MB C, 0B8h.0
                SJ crank_pswl4_flag_pswl_b4
crank_mul_alt:
                MULB
crank_mul_alt_mulb_mul:
                MULB
                SJ crank_clear_acc
crank_set_dp:
                MOV DP, #0035Eh
                MB C, 0B8h.1
crank_pswl4_flag_pswl_b4:
                MB PSWL.4, C
                LB A, 0A2h
                CMPB A, #004h
                JEQ crank_mul_alt
                JGE crank_load_ind
                STB A, r0
                INCB r0
                LB A, 0A0h
                ADDB A, #001h
                CMPB A, r0
                JLE crank_mul_alt_mulb_mul
                LB A, [DP]
                ADDB A, #001h
                CMPB A, r0
                JLE crank_mul_alt_mulb_mul
                JBR off(01Fh).0, crank_mul_alt_mulb_mul
crank_load_ind:
                L A, [DP]
                ST A, 0A0h
                DEC DP
                LB A, [DP]
                STB A, 09Fh
                MB C, PSWL.4
                MB off(02Ah).5, C
crank_clear_acc:
                CLR A
                MOV er0, 0A0h
                ST A, er3
                LB A, 0A2h
                ADDB A, #001h
                CMPB A, r0
                JEQ crank_mul_common2
                CMPB A, #006h
                JNE crank_cmp_rama2_imm
                LB A, r0
                JEQ crank_mul_common2
                SLLB A
                JLT crank_mul_common2
crank_cmp_rama2_imm:
                CMPB 0A2h, #003h
                JNE crank_mul_alt2
                CMPB r0, #005h
                JNE crank_mul_alt2
                MOV er3, off(036h)
crank_mul_common2:
                CLRB r0
                L A, off(036h)
                MUL
                LB A, 0A0h
                SLLB A
                JGE crank_mul_common2_load_er3
                ANDB PSWH, #0FEh
                L A, TM3
                SUB A, TMR2
                ADD A, #00010h
                CMP A, er1
                JGE crank_mul_common2_clear_tcon3_b2
                L A, TMR2
                ADD A, er1
                SJ tmr3_reload_store2
crank_mul_alt2:
                MUL
                RB r0.0
                L A, ACC
                SJ tmr3_reload_clamp_min
crank_mul_common2_clear_tcon3_b2:
                RB TCON3.2
                L A, TM3
                SUB A, #00001h
tmr3_reload_store2:
                ST A, TMR3
                RB TCON3.3
                ORB PSWH, #001h
                J tmr3_reload_clamp_min
crank_mul_common2_load_er3:
                L A, er3
                ADD A, er1
                JGE tmr3_reload_clamp_check
                L A, #0FFFFh
tmr3_reload_clamp_check:
                CMP A, #0001Fh
                JGE tmr3_store_rame8
tmr3_reload_clamp_min:
                L A, #0001Fh
tmr3_store_rame8:
                ST A, 0E8h
                MOV DP, #00F00h
                LB A, [DP]
                SRLB A
                ROR off(0AAh)
                SRLB A
                ROR off(0AAh)
                LB A, 0A2h
                JNE crank_load_rama2
                CLR A
                XCHG A, off(0AAh)
                ST A, 0ECh
crank_load_rama2:
                LB A, 0A2h
                CMPB A, #001h
                JNE crank_load_rama8
                L A, 0EAh
                ST A, off(0A8h)
crank_load_rama8:
                L A, off(0A8h)
                SRL A
                MB P1.7, C
                SRL A
                MB P1.3, C
                ST A, off(0A8h)
                MOV DP, #02F00h
                LB A, P1
                STB A, [DP]
                RT
; Speed ratio scale: MULB 3, subtract er1, SLL/SWAP, 0xFE compare - the VSS ratio scaler.
speed_ratio_scale:
                CLRB A
                STB A, r3
                SUBB A, r4
                MOVB r0, #003h
                MULB
                L A, ACC
                SUB A, er1
                SLL A
                SWAP
                CMPB ACC, #0FEh
                JNE ign_timer_clamp_store_er0
                L A, #000FFh
ign_timer_clamp_store_er0:
                ST A, er0
                CLRB A
                SUBB A, r2
                SLLB A
                JNE ign_timer_convert_return
                LB A, #0FFh
                SC
ign_timer_convert_return:
                RT
; Clamp: A clamped to the [X1] table word (r0/r1 pair).
clamp_table:
                STB A, r0
                LC A, [X1]
                CMPB r0, A
                JLT clamp_table_store_r1
                STB A, r0
clamp_table_store_r1:
                STB A, r1
                LB A, ACCH
                CMPB r0, A
                JGE clamp_table_sub_r0
                STB A, r0
clamp_table_sub_r0:
                SUBB r0, A
                SUBB r1, A
                LB A, r7
                J map_interp_core_sub_acc
; Interp word: 31-instruction table walk (stride +2, ACCH), the 2D map interpolation worker.
interp_word:
                CMPCB A, 00002h[X1]
                JGE map_interp_core
                INC X1
                INC X1
                J interp_word
; Map interpolation core: the row/column compare chain (A vs [X1], [X1]+2, [X1]+3 words) that walks
; the axis table and interpolates the map value; the vcal1/vcal2/vcal0 entries (0x4D41/0x4D54/0x4D67)
; are CAL targets into this chain (also the VCAL 1/2/0 vector entries).
map_interp_core:
                STB A, r0
                LC A, 00002h[X1]
                MOVB r6, ACCH
                STB A, r1
                SUBB r0, A
                LC A, [X1]
                SUBB A, r1
                STB A, r1
                LB A, ACCH
map_interp_core_sub_acc:
                SUBB A, r6
                JGE map_interp_core_mul
                STB A, r7
                CLRB A
                SUBB A, r7
                MULB
                MOVB r0, r1
                DIVB
                SUBB r6, A
                LB A, r6
                RT
map_interp_core_mul:
                MULB
                MOVB r0, r1
                DIVB
                ADDB A, r6
                STB A, r6
                RT
; CAL target into map_interp_core (also the VCAL 1 vector entry).
vcal1_interp_entry:
                CMPCB A, [X1]
                JLE vcal1_bracket_check
                LCB A, [X1]
vcal1_bracket_check:
                CMPCB A, 00002h[X1]
                JGE map_interp_core
                LCB A, 00002h[X1]
                J map_interp_core
; CAL target into map_interp_core (also the VCAL 2 vector entry).
vcal2_interp_entry:
                CMPCB A, [X1]
                JLE vcal2_bracket_check
                LCB A, [X1]
vcal2_bracket_check:
                CMPCB A, 00003h[X1]
                JGE vcal0_interp_entry_store_er0
                LCB A, 00003h[X1]
                J vcal0_interp_entry_store_er0
; CAL target into map_interp_core (also the VCAL 0 vector entry).
vcal0_interp_entry:
                CMPCB A, 00003h[X1]
                JGE vcal0_interp_entry_store_er0
                ADD X1, #00003h
                J vcal0_interp_entry
vcal0_interp_entry_store_er0:
                ST A, er0
                CLR A
                LC A, [X1]
                ST A, er2
                LC A, 00004h[X1]
                ST A, er3
                LC A, 00002h[X1]
                SWAP
                SUBB r0, A
                SUBB r4, A
                CLRB A
                STB A, r1
                XCHGB A, r5
                L A, ACC
; Scale / divide: the ratio scaler (mul then div) used by the speed/RPM scaling.
scale_div:
                SUB A, er3
                JGE scale_div_mul
                ST A, er1
                CLR A
                SUB A, er1
                MUL
                MOV er0, er1
                DIV
                SUB er3, A
                L A, er3
                RT
scale_div_mul:
                MUL
                MOV er0, er1
                DIV
                ADD A, er3
                ST A, er3
                RT
; Interp table: the +2/+4/+6 stride table walk (32 instructions) for the map axes.
interp_table:
                CMPC A, 00004h[X1]
                JGE table_interp_4byte_bracket
                ADD X1, #00004h
                J interp_table
table_interp_4byte_bracket:
                ST A, er0
                LC A, 00004h[X1]
                ST A, er2
                SUB er0, A
                LC A, [X1]
                SUB A, er2
                ST A, er2
                LC A, 00006h[X1]
                ST A, er3
                LC A, 00002h[X1]
                J scale_div
; Mul / shift: 9-instruction multiply-shift worker.
mul_shift:
                SUBB A, #018h
                JLT mul_shift_clear_acc
                MB C, ACCH.7
                ROLB A
                JGE mul_shift_return
                LB A, #0FFh
mul_shift_return:
                RT
mul_shift_clear_acc:
                CLRB A
                RT
; Speed scale: the VSS speed scaler (CAL'd from the speed update, 0x2959).
speed_scale:
                MUL
                MOV er2, er1
                CLR A
                SUB A, er0
                MOV er0, [DP]
                MUL
                L A, er1
                ADD A, er2
                ST A, [DP]
                RT
; Mul-by-8 / shift worker.
mul8_shift:
                MUL
                MOV DP, er1
                MOV X2, A
                L A, er3
                MUL
                SUB er2, A
                L A, er1
                SBC er3, A
                L A, X2
                ADD er2, A
                L A, DP
                ADC A, er3
                RT
; ALU helper: 21-instruction ALU worker (ALRB/ASSP reads).
alu_1:
                MOV er2, 00000h[X1]
                SUB A, er2
                JGE injtimer_bank_calc1_mul
                ST A, er1
                CLR A
                SUB A, er1
injtimer_bank_calc1_mul:
                MUL
                ST A, er0
                L A, 00002h[X1]
                SJ injtimer_bank_calc1_sign
injtimer_bank_calc1_sign:
                JGE injtimer_bank_calc1_add
                SUB A, er0
                ST A, er0
                L A, er2
                SBC A, er1
                RT
injtimer_bank_calc1_add:
                ADD A, er0
                ST A, er0
                L A, er2
                ADC A, er1
                RT
                DB  0E2h
; CAL target into the accum/mul helper region (also the VCAL 4 vector entry).
vcal4_interp_entry:
                ROL A
                JGE vcal4_interp_entry_ror_acc
                ROR A
                ADD A, er3
                JLT vcal4_store_er3
                CLR A
vcal4_store_er3:
                ST A, er3
                RT
vcal4_interp_entry_ror_acc:
                ROR A
; CAL target into the accum/mul helper region (also the VCAL 5 vector entry).
vcal5_interp_entry:
                ADD A, er3
                JGE vcal5_interp_entry_store_er3
                L A, #0FFFFh
vcal5_interp_entry_store_er3:
                ST A, er3
                RT
                DB  0E2h
; Accumulate loop: 26-instruction accumulation (1 loop) over the state words.
accum_loop:
                ROL A
                JLT accum_loop_ror_acc
                ROR A
                MB C, r7.7
                JLT signext_common_add
                ADD A, er3
                ROL A
                JGE signext_common_add_ror_acc
                L A, #07FFFh
                ST A, er3
                RT
signext_common_add:
                ADD A, er3
                ST A, er3
                RT
accum_loop_ror_acc:
                ROR A
                MB C, r7.7
                JGE signext_common_add
                ADD A, er3
                ROL A
                JLT signext_common_add_ror_acc
                L A, #08000h
                ST A, er3
                RT
signext_common_add_ror_acc:
                ROR A
                ST A, er3
                RT
; Mul / shift variant b.
mul_shift_b:
                MOV er0, #00005h
                MUL
                SRL er1
                ROR A
                SRL er1
                ROR A
                CMPB r2, #000h
                JEQ scale_mul5_div4_return
                L A, #0FFFFh
scale_mul5_div4_return:
                RT
; CAL target into the scale helper region (also the VCAL 7 vector entry); called from engine_main_irq.
vcal7_scale_entry:
                XOR A, #0FFFFh
                ADD A, #00001h
                RT
; CAL target into the scale helper region (also the VCAL 6 vector entry); called from engine_main_irq.
vcal6_scale_entry:
                XOR A, #086FFh
                RT
                DB  001h
newval_table3_clear_acc:
                CLR A
                ST A, er0
                ST A, er2
                LB A, r3
                CMPB A, r6
                JLT scaler_table_search_start
                LB A, r6
scaler_table_search_start:
                STB A, r6
                ADD X1, A
scaler_table_search_loop:
                INCB r6
                INC X1
                LCB A, [X1]
                JEQ scaler_table_interp
                CMPB A, r2
                JLE scaler_table_search_loop
scaler_table_interp:
                LB A, r2
scaler_table_search_back:
                DECB r6
                DEC X1
                CMPCB A, [X1]
                JLT scaler_table_search_back
                LCB A, [X1]
                STB A, r4
                LB A, r2
                SUBB A, r4
                STB A, r0
                INC X1
                LCB A, [X1]
                SUBB A, r4
                STB A, r4
                CLR A
                MB C, PSWL.4
                JGE scaler_div_final
                ROL er0
                SLL er2
scaler_div_final:
                DIV
                RT
table2d_lookup_interp:
                CLR A
                LB A, r2
                ADD X1, A
                MOV DP, X1
                L A, #00101h
                MB C, PSWL.5
                JGE table2d_row_calc
                LB A, r1
                MULB
                ADD DP, A
                CLR A
                LC A, [DP]
table2d_row_calc:
                ST A, er2
                LB A, r3
                MULB
                ADD X1, A
                LC A, [X1]
                MOV DP, A
                CLR A
                LB A, r0
                ADD X1, A
                LC A, [X1]
                MOV X1, A
                MOVB r0, r4
                L A, DP
                MULB
                ST A, er1
                MOVB r0, r5
                L A, DP
                SWAP
                MULB
                MOV DP, A
                L A, X1
                SWAP
                MULB
                MOVB r0, r4
                ST A, er2
                L A, X1
                MULB
                MOV X1, er1
                XCHG A, er2
                MOV er0, X2
                CAL interp_scale
                MOV er2, X1
                MOV X1, A
                L A, DP
                CAL interp_scale
                L A, X1
                MOV er0, er3
; Interp scale: 15-instruction scale worker (CAL'd from interp_scale_b / accum workers).
interp_scale:
                SUB A, er2
                JGE interp_scale_mul
                ST A, er1
                CLR A
                SUB A, er1
                MUL
                L A, er1
                SUB er2, A
                L A, er2
                RT
interp_scale_mul:
                MUL
                L A, er1
                ADD A, er2
                ST A, er2
                RT
; Interp scale variant b (CAL's interp_scale).
interp_scale_b:
                EXTND
                ADD DP, A
                CLR A
                LCB A, [DP]
                ST A, er2
                INC DP
                LCB A, [DP]
                CAL interp_scale
                LB A, r4
                RT
; State word 0x03F: 15-instruction state worker reading 0x03F.
state_03F:
                MOVB r0, off(03Fh)
                MOVB r1, #001h
                CMPB r0, #080h
                JGE mul_scale_rotate
                INCB r1
mul_scale_rotate:
                MUL
                LB A, r2
                L A, ACC
                SWAP
                SRLB r3
                ROR A
                CMPB r3, #000h
                JEQ stub_return_short
                L A, #0FFFFh
stub_return_short:
                RT
; Constant table a: the 0x00010/0x01000 constant table (14 instructions).
const_table_a:
                MOV X2, #00010h
                MOV DP, #01000h
                SJ clamp_range_check
; Constant table b: the 0x07133/0x09862 constant table (13 instructions).
const_table_b:
                MOV X2, #07133h
                MOV DP, #09862h
clamp_range_check:
                CMP A, X2
                JLE clamp_range_lowside
                CMP A, DP
                JLT clamp_range_store_ind
                MOV X2, DP
clamp_range_lowside:
                L A, X2
                CLR er0
clamp_range_store_ind:
                ST A, 00000h[X1]
                L A, er0
                ST A, 00002h[X1]
                RT
; ALU helper 2 (6 instructions).
alu_2:
                SUB A, #00025h
                JLT sub37_clamp_load_er0
                CMP A, er0
                JGE sub37_clamp_return
sub37_clamp_load_er0:
                L A, er0
sub37_clamp_return:
                RT
; RAM window: 19-instruction worker over the 0x0CE window (0x0CEh read).
ram_window:
                ADD A, #00018h
                JGE table_index_add_store_er3
                L A, #0FFFFh
table_index_add_store_er3:
                ST A, er3
                CLR er1
                LC A, [X1]
                ST A, er0
                L A, 0CEh
                SUB A, er0
                JLT table_index_add_clamp_rom_load_ind
                ST A, er0
                LC A, 00004h[X1]
                MUL
table_index_add_clamp_rom_load_ind:
                LC A, 00002h[X1]
                ADD A, er1
                CMP A, er3
                JLT table_index_add_clamp_return
                L A, er3
table_index_add_clamp_return:
                RT
                DB  090h,035h,022h,0C0h,000h,0C9h,008h,067h
                DB  0FFh,0FFh,0CBh,003h
; Accumulate loop b: 20-instruction accumulation over 0x00C (1 loop).
accum_loop_b:
                MUL
                L A, er1
                JBS off(00Ch).0, accum_loop_b_add_acc
                XCHG A, er3
                SUB A, er3
                JGE idle_pi_clamp_compare
accum_loop_b_sc:
                SC
                L A, X1
                ST A, er3
                RT
accum_loop_b_add_acc:
                ADD A, er3
                JLT idle_helper2_sc_path
idle_pi_clamp_compare:
                CMP A, X1
                JLE accum_loop_b_sc
                CMP X2, A
                JGT accum_loop_b_store_er3
idle_helper2_sc_path:
                SC
                L A, X2
accum_loop_b_store_er3:
                ST A, er3
                RT
                DB  067h,000h,005h,0EBh,016h,003h,067h,000h
                DB  005h,001h
; VSS period: 8-instruction worker over the 0x08C/0x08E period words.
vss_period:
                CMP off(08Ch), A
                JLT idle_pi_clamp_low
                CMP A, off(08Eh)
                JGE idle_pi_clamp_return
                L A, off(08Eh)
idle_pi_clamp_return:
                RT
idle_pi_clamp_low:
                L A, off(08Ch)
                RT
; Boot quotient: 22-instruction quotient worker (0x031D table, 0x011A/0x0212/0x031E writes).
boot_quotient:
                SUBB A, #001h
                MOVB r0, #008h
                DIVB
                MOV X1, A
                LB A, r1
                SBR 0011Ah[X1]
                SBR 00212h[X1]
                SBR 0031Eh[X1]
; Boot lookup: 14-instruction lookup over the 0x031D table (1 loop).
boot_lookup:
                MOV DP, #0031Dh
                CLR er0
cfgvariant_checksum_loop:
                LB A, r0
                ADDB A, [DP]
                STB A, r0
                LB A, r1
                XORB A, [DP]
                STB A, r1
                INC DP
                CMP DP, #00322h
                JNE cfgvariant_checksum_loop
                L A, er0
                ST A, [DP]
                RT
; Injector init pattern: 16-instruction init of 0x010/0x030 from P0/P1 port reads.
inj_init_pattern:
                MOV DP, #03F00h
                LB A, #090h
                STB A, [DP]
                MOV DP, #01F00h
                LB A, P0
                STB A, [DP]
                MOV DP, #02F00h
                LB A, P1
                STB A, [DP]
                MOV DP, #00F00h
                LB A, [DP]
                XORB A, #038h
                STB A, off(010h)
                STB A, -104[USP]
                SB off(030h).2
                RT
; Atomic RAM word update: saves IE/PSW (0F8h/0FAh), masks interrupts, updates the RAM word at DP
; with the X1 value, restores IE/PSW. CAL'd with (DP, X1) pairs to update the expected-state words.
atomic_ram_update:
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                LB A, 00000h[X1]
                JEQ atomic_ram_update_or_pswh
                DECB 00000h[X1]
atomic_ram_update_or_pswh:
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                INC X1
                JRNZ DP, atomic_ram_update
                RT
; WDT kick: reloads the WDT and advances the ADC channel (P2), 0x0B7 read.
wdt_kick:
                LB A, #03Ch
                STB A, WDT
                SWAPB
                STB A, WDT
                MB C, 0B7h.1
                JLT resetwatchdog_return
                XORB P2, #010h
resetwatchdog_return:
                RT
; Fuel table init: 13-instruction init of the 0x0378 block from 0x017/0x030.
fuel_table_init:
                ADDB A, #005h
                JGE ect_step_range_check
                LB A, #0FFh
ect_step_range_check:
                JBS off(017h).4, ect_step_clamp_default
                JBR off(030h).3, ect_step_clamp_default
                CMPB A, 00378h[X1]
                JGE fuel_table_init_return
ect_step_clamp_default:
                MOVB r0, #042h
                CMPB A, r0
                JGE fuel_table_init_store_ind
                LB A, r0
fuel_table_init_store_ind:
                STB A, 00378h[X1]
fuel_table_init_return:
                RT
; ALU helper 3 (10 instructions).
alu_3:
                SUBB A, [DP]
                JGE alu_3_sub_acc
                ADDB A, #002h
                SJ ect_smooth_branch
alu_3_sub_acc:
                SUBB A, #002h
ect_smooth_branch:
                JGE ect_smooth_add_acc
                CLRB A
ect_smooth_add_acc:
                ADDB A, [DP]
                STB A, [DP]
                RT
; Flag pair: 5-instruction worker over 0x024/0x026 (CAL'd from the engine interrupts).
flag_pair:
                L A, off(024h)
                ST A, -100[USP]
                L A, off(026h)
                ST A, -98[USP]
                RT
; Injector word stash: 11-instruction stash of the 0x01A/0x01C/0x01E/0x020/0x022 words onto the USP
; stack (94/96/103/106[USP]) for the ignition paths; CAL'd at the top of engine_main_irq.
inj_words_stash:
                L A, -110[USP]
                ST A, off(01Ah)
                L A, -108[USP]
                ST A, off(01Ch)
                L A, -106[USP]
                ST A, off(01Eh)
                L A, -104[USP]
                ST A, off(020h)
                L A, -102[USP]
                ST A, off(022h)
                RT
                DB  078h,0C2h,021h,090h,0A8h,0CAh,002h,0F5h
                DB  007h,0A3h,02Ch,0CAh,003h,04Ah,0CBh,002h
                DB  022h,0C1h,078h,0C2h,020h,070h,070h,0A8h
                DB  0B9h,0CEh,0E5h,001h
; RAM readback test: XCHG A,[X1] write/readback, X2 compare, BRK 0x42 on mismatch. CAL'd in a loop
; from selftest_ram and the periodic RAM test.
ram_readback_test:
                MOV X2, A
                SB off(030h).7
                AND IE, #002A0h
                ANDB PSWH, #0FEh
                XCHG A, 00084h[X1]
                XCHG A, 00084h[X1]
                ST A, er3
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                RB off(030h).7
                L A, er3
                CMP A, X2
                JNE ram_readback_test_set_ramf5
                RT
ram_readback_test_set_ramf5:
                MOVB 0F5h, #042h
                BRK
; ADC channel scan: advances the analog mux (P2.5-7 += 0x20), reads the A/D (ADCR0H -> 0x03CA,
; ADCR1H -> 0x03D2), TM2 timeout (0xC8 ticks -> BRK 0x4A), 0x003.3 flag, P2 channel advance.
adc_channel_scan:
                JBR off(030h).3, idle_helper1_alt
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                L A, TM2
                SUB A, off(058h)
                CMP A, #000C8h
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
                JLT idle_helper1_return
idle_helper1_alt:
                RB IRQH.4
                JEQ adc_channel_scan_set_ramf5
                LB A, P2
                SWAPB
                SRLB A
                ANDB A, #007h
                EXTND
                MOV X1, A
                LB A, ADCR1H
                STB A, 003D2h[X1]
                LB A, ADCR0H
                STB A, 003CAh[X1]
                L A, 0FAh
                ST A, IE
                ANDB PSWH, #0FEh
                ADDB P2, #020h
                MOV off(058h), TM2
                ORB PSWH, #001h
                L A, 0F8h
                ST A, IE
idle_helper1_return:
                RT
adc_channel_scan_set_ramf5:
                MOVB 0F5h, #04Ah
                BRK
; ADC fault default: 19-instruction fault default (0x036 read, 0x0AF/0x0F5/0x0F7 writes, 0x03D5 table).
adc_fault_default:
                CMPB off(036h), #00Ah
                JLT empty_stub_return
; ADC default write: 17-instruction default write (0x03D5 table, 0x0AF/0x0F5/0x0F7).
adc_default_write:
                MOV DP, #003D5h
                LB A, [DP]
                CMPB A, #0FFh
                JGT selftest_reason_range_check_entry_load_imm
                CMPB A, #0FCh
                JGE empty_stub_return
                CMPB A, #088h
                JGT selftest_reason_range_check_entry_load_imm
                CMPB A, #078h
                JGE empty_stub_return
selftest_reason_range_check_entry_load_imm:
                LB A, #049h
                STB A, 0AFh
                DECB 0F7h
                JNE empty_stub_return
                STB A, 0F5h
                BRK
empty_stub_return:
                RT
; ALU helper 4 (13 instructions).
alu_4:
                MOVB r0, #0BDh
                SLL A
                JLT dwell_scale_default
                SLL A
                JLT dwell_scale_default
                LB A, ACCH
                CMPB A, r0
                JGE dwell_scale_default
                MOVB r0, #00Fh
                CMPB A, r0
                JGE alu_4_return
dwell_scale_default:
                LB A, r0
alu_4_return:
                RT
; Serial word init: 8-instruction init of 0x056 from the 0x04700 ROM word.
serial_word_init:
                MOV DP, #04700h
; Serial word set: 7-instruction set of 0x056.
serial_word_set:
                LB A, [DP]
                XORB A, #0FFh
                ROLB A
                ROLB off(056h)
                ROLB A
                ROLB off(056h)
                RT
; Fuel state init: 158-instruction boot init of the fuel state (0x03A4/0x03CC/0x03CD/0x03D2/0x03D4
; tables, 0x0BB/0x0D7/0x0DA reads, 0x0324 write). CAL'd from rom_checksum_check (first boot).
fuel_state_init:
                CLRB r0
                CMPB r6, #001h
                JNE cfgvariant_check_v3
                CMPB 0DAh, #01Ah
                JLT cfgvariant_result_common
                INCB r0
cfgvariant_result_common:
                SJ cfgvariant_eval_result
cfgvariant_check_v3:
                CMPB r6, #003h
                JNE cfgvariant_check_v6
                LB A, 0BBh
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
                SJ cfgvariant_eval_result
cfgvariant_check_v6:
                CMPB r6, #006h
                JNE cfgvariant_check_v7
                MOV DP, #003D4h
                LB A, [DP]
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
                SJ cfgvariant_eval_result
cfgvariant_check_v7:
                CMPB r6, #007h
                JNE cfgvariant_check_v10
                MOV DP, #003A4h
                LB A, [DP]
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
                SJ cfgvariant_eval_result
cfgvariant_check_v10:
                CMPB r6, #00Ah
                JNE cfgvariant_check_v11
                MOV DP, #003CCh
                LB A, [DP]
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
                SJ cfgvariant_eval_result
cfgvariant_check_v11:
                CMPB r6, #00Bh
                JNE cfgvariant_check_v13
                MOV DP, #003D2h
                LB A, [DP]
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
                SJ cfgvariant_eval_result
cfgvariant_check_v13:
                CMPB r6, #00Dh
                JNE cfgvariant_check_v20
                MOV DP, #003CDh
                LB A, [DP]
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
                SJ cfgvariant_eval_result
cfgvariant_check_v20:
                CMPB r6, #014h
                JNE cfgvariant_check_v26
                MOV DP, #003D2h
                LB A, [DP]
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
                SJ cfgvariant_eval_result
cfgvariant_check_v26:
                CMPB r6, #01Ah
                JNE cfgvariant_check_v4
                LB A, 0D7h
                SLLB A
                JGE cfgvariant_eval_result
                INCB r0
cfgvariant_eval_result:
                J cfgvariant_remap_start
cfgvariant_check_v4:
                CMPB r6, #004h
                JNE cfgvariant_check_v8
                CMPB r7, #021h
                JEQ cfgvariant_eval_result2
                INCB r0
                SJ cfgvariant_eval_result2
cfgvariant_check_v8:
                CMPB r6, #008h
                JNE cfgvariant_check_v9
                CMPB r7, #022h
                JEQ cfgvariant_eval_result2
                INCB r0
                CMPB r7, #02Ah
                JEQ cfgvariant_eval_result2
                INCB r0
                SJ cfgvariant_eval_result2
cfgvariant_check_v9:
                CMPB r6, #009h
                JNE cfgvariant_check_v17
                CMPB r7, #023h
                JEQ cfgvariant_eval_result2
                INCB r0
                SJ cfgvariant_eval_result2
cfgvariant_check_v17:
                CMPB r6, #011h
                JNE cfgvariant_check_v14_cmp_r6_imm
cfgvariant_eval_result2:
                SJ cfgvariant_remap_start
cfgvariant_check_v14_cmp_r6_imm:
                CMPB r6, #00Eh
                JEQ cfgvariant_eval_result3
                CMPB r6, #01Dh
                JNE cfgvariant_check_v15_cmp_r6_imm
                L A, -40[USP]
                CMP A, #08000h
                JLT cfgvariant_eval_result3
                INCB r0
cfgvariant_eval_result3:
                SJ cfgvariant_remap_start
cfgvariant_check_v15_cmp_r6_imm:
                CMPB r6, #00Fh
                JEQ cfgvariant_eval_result4
                CMPB r6, #010h
                JEQ cfgvariant_eval_result4
                CMPB r6, #015h
                JEQ cfgvariant_eval_result4
                CMPB r6, #01Bh
                JNE cfgvariant_check_v5_cmp_r6_imm
cfgvariant_eval_result4:
                SJ cfgvariant_remap_start
cfgvariant_check_v5_cmp_r6_imm:
                CMPB r6, #005h
                JEQ cfgvariant_remap_start
                CMPB r6, #016h
                JEQ cfgvariant_remap_start
                CMPB r6, #017h
                JEQ cfgvariant_remap_start
                CMPB r6, #01Eh
                JNE cfgvariant_check_v5_cmp_r6_imm_2
                CMPB r7, #015h
                JNE cfgvariant_remap_start
                INCB r0
                SJ cfgvariant_remap_start
cfgvariant_check_v5_cmp_r6_imm_2:
                CMPB r6, #01Fh
                JNE cfgvariant_check_v1f
                CMPB r7, #016h
                JNE cfgvariant_remap_start
                INCB r0
                SJ cfgvariant_remap_start
cfgvariant_check_v1f:
                CMPB r6, #019h
                JEQ cfgvariant_remap_start
                MOVB r1, r6
                RT
cfgvariant_remap_start:
                CLR A
                LB A, r6
                CMPB A, #019h
                JNE cfgvariant_remap_cmp_acc_imm
                LB A, #023h
                SJ cfgvariant_remap_store_r1
cfgvariant_remap_cmp_acc_imm:
                CMPB A, #01Ah
                JNE cfgvariant_remap_cmp_acc_imm_2
                LB A, #024h
                SJ cfgvariant_remap_store_r1
cfgvariant_remap_cmp_acc_imm_2:
                CMPB A, #01Bh
                JNE cfgvariant_remap_cmp_acc_imm_3
                LB A, #029h
                SJ cfgvariant_remap_store_r1
cfgvariant_remap_cmp_acc_imm_3:
                CMPB A, #01Dh
                JNE cfgvariant_remap_store_r1
                LB A, #02Bh
cfgvariant_remap_store_r1:
                STB A, r1
                SRLB A
                MOV X1, A
                LB A, r0
                JGE cfgvariant_bit_calc
                ADDB A, #004h
cfgvariant_bit_calc:
                SBR 00324h[X1]
                RT
; Engine state init: 56-instruction boot init of the engine state (0x0344/0x03A4/0x03A6/0x03CC/
; 0x03CD/0x03D4 tables, 0x01D/0x09D/0x0BB/0x0C4/0x0CC/0x0DA/0x0DB reads). CAL'd from rom_checksum_
;check (first boot).
engine_state_init:
                MOV DP, #00344h
                LB A, [DP]
                JNE cfgvariant_snapshot_return
                INC DP
                LB A, 0CCh
                STB A, [DP]
                INC DP
                L A, 0C4h
                SWAP
                ST A, [DP]
                INC DP
                INC DP
                MOV X1, #003D4h
                LB A, 00000h[X1]
                STB A, [DP]
                INC DP
                MOV X1, #003CCh
                LB A, 00000h[X1]
                STB A, [DP]
                INC DP
                LB A, 0BBh
                STB A, [DP]
                INC DP
                MOV X1, #003CDh
                LB A, 00000h[X1]
                STB A, [DP]
                INC DP
                MOV X1, #003A4h
                LB A, 00000h[X1]
                STB A, [DP]
                INC DP
                LB A, 0DBh
                STB A, [DP]
                INC DP
                MOV X1, #003A6h
                L A, 00000h[X1]
                SWAP
                ST A, [DP]
                INC DP
                INC DP
                LB A, 0DAh
                STB A, [DP]
                INC DP
                LB A, -39[USP]
                STB A, [DP]
                INC DP
                LB A, 09Dh
                STB A, [DP]
                NOP
                MOV DP, #00344h
                LB A, r1
                ROLB A
                MB C, off(01Dh).0
                RORB A
                STB A, [DP]
cfgvariant_snapshot_return:
                RT
; Boot lookup b: 10-instruction lookup over the 0x031D/0x0356 tables (1 loop).
boot_lookup_b:
                CLR A
                MOV DP, #0031Dh
                CLRB [DP]
                MOV DP, #00356h
cfgvariant_state_dec_dp:
                DEC DP
                DEC DP
                ST A, [DP]
                CMP DP, #0031Eh
                JGT cfgvariant_state_dec_dp
                RT
; State table refresh: 14-instruction refresh of the 0x0300-0x031A block from 0x0384.
state_table_refresh:
                CLR X1
                L A, #08000h
                ST A, 00300h[X1]
                ST A, 00304h[X1]
                ST A, 00308h[X1]
                L A, 00384h[X1]
                ST A, 0030Ch[X1]
                CLRB A
                STB A, 00310h[X1]
                LB A, #07Bh
                STB A, 00311h[X1]
                LB A, #03Bh
                STB A, 0031Ah[X1]
                RT
; Boot lookup c: 15-instruction lookup over the 0x0324 table (1 loop).
boot_lookup_c:
                MOV DP, #00324h
                LB A, [DP]
                ANDB A, #0F0h
                STB A, r0
                STB A, r1
cfgvariant_checksum2_loop:
                INC DP
                LB A, r0
                ADDB A, [DP]
                STB A, r0
                LB A, r1
                XORB A, [DP]
                STB A, r1
                CMP DP, #00353h
                JNE cfgvariant_checksum2_loop
                RT
; Timer state reinit: 122-instruction reinitialisation of the CKP/VSS/timer state (0x0356/0x0384/
; 0x03CB/0x03CF/0x03D3 tables, 0x016/0x017/0x019/0x027/0x02D/0x0EE writes). CAL'd from timer_reinit
; and boot_state_init.
timer_state_reinit:
                CLRB A
                LCB A, OptionVtecChecks
                SLLB A
                MB off(016h).4, C
                LCB A, OptionVtecPressureSwitch
                SLLB A
                MB off(027h).6, C
                LCB A, OptionAlternatorControlCheck
                SLLB A
                MB off(016h).6, C
                LCB A, OptionBaroSensor
                SLLB A
                MB off(019h).3, C
                LCB A, OptionSecondSensorInputs
                SLLB A
                MB off(017h).3, C
                LCB A, OptionKnockWindowAlwaysOpen
                SLLB A
                MB off(027h).7, C
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                LCB A, OptionKnockRetardByIntakeAir
                SLLB A
                MB off(027h).1, C
                LCB A, OptionUnused216Bit1
                SLLB A
                MB off(02Dh).0, C
                LCB A, OptionVtecCoolantGate
                SLLB A
                MB off(02Dh).1, C
                MOV DP, #003CBh
                LB A, [DP]
                STB A, r1
                RC
                LCB A, OptionFlagsFromBytes
                STB A, r0
                MOV DP, #003D3h
                LB A, [DP]
                STB A, r2
                CMPB r0, #000h
                JEQ timer_state_reinit_sll_acc
                LCB A, OptionIdleStrategy2
timer_state_reinit_sll_acc:
                SLLB A
                MB off(016h).3, C
                LCB A, OptionAutomaticTransmission
                SLLB A
                MB off(0EEh).3, C
                CMPB r0, #000h
                JEQ boot_completion_helper_rc
                LCB A, OptionLowSpeedRetardCap
                SLLB A
                SJ boot_flag_iabv_common
boot_completion_helper_rc:
                RC
                JBS off(0EEh).3, boot_flag_iabv_common
                LB A, r2
                SLLB A
                SLLB A
                XORB PSWH, #080h
boot_flag_iabv_common:
                MB off(016h).2, C
                CMPB r0, #000h
                JEQ boot_flag_baro_check
                LCB A, OptionAltKnockShiftTables
                SLLB A
                SJ boot_flag_baro_common
boot_flag_baro_check:
                LB A, r2
                SLLB A
                SLLB A
                XORB PSWH, #080h
boot_flag_baro_common:
                MB off(016h).0, C
                CMPB r0, #000h
                JEQ timer_state_reinit_test_ram16_b2
                LCB A, OptionIdleValveType2
                SLLB A
                SJ timer_state_reinit_flag_ram17_b6
timer_state_reinit_test_ram16_b2:
                MB C, off(016h).2
                JBR off(0EEh).3, timer_state_reinit_flag_ram17_b6
                LB A, r1
                SLLB A
                XORB PSWH, #080h
timer_state_reinit_flag_ram17_b6:
                MB off(017h).6, C
                LCB A, 05469h
                SLLB A
                MB off(027h).4, C
                CMPB r0, #000h
                JEQ boot_flag_baro_common_rc
                LCB A, OptionKnockSensor
                SLLB A
                SJ boot_flag_baro_common_flag_ram16_b5
boot_flag_baro_common_rc:
                RC
                JBS off(0EEh).3, boot_flag_baro_common_flag_ram16_b5
                LB A, r1
                SLLB A
boot_flag_baro_common_flag_ram16_b5:
                MB off(016h).5, C
                CMPB r0, #000h
                JEQ timer_state_reinit_test_ram16_b3
                LCB A, OptionUnused16
                SLLB A
                SJ boot_flag_gearpreset_alt_flag_ram27_b2
timer_state_reinit_test_ram16_b3:
                MB C, off(016h).3
boot_flag_gearpreset_alt_flag_ram27_b2:
                MB off(027h).2, C
                CMPB r0, #000h
                JEQ boot_flag_set_dp
                LCB A, OptionSerialDiagMode
                SLLB A
                SJ boot_flag_final
boot_flag_set_dp:
                MOV DP, #003CFh
                CMPB [DP], #080h
                XORB PSWH, #080h
boot_flag_final:
                MOV DP, #00356h
                MB [DP].1, C
                L A, #00500h
                JBS off(016h).3, timer_state_reinit_set_dp
                L A, #00500h
timer_state_reinit_set_dp:
                MOV DP, #00384h
                ST A, [DP]
                RT
;@ IdleControlScale type=u8 formula=raw category="Idle" desc="Idle control: scale byte (also compared by the fuel code; 00h stock)."
IdleControlScale:DB  000h
;@ OptionVtecChecks type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): VTEC solenoid and pressure checks (codes 21, 22). Sets flag 216h bit 4. Checks the VTEC solenoid feedback (code 21) and the VTEC pressure switch result."
OptionVtecChecks:       DB  0FFh
;@ OptionVtecPressureSwitch type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): VTEC pressure switch (code 22). Sets flag 227h bit 6. Reads the VTEC oil-pressure switch (code 22), and gates the knock (code 23) check and the road-speed input."
OptionVtecPressureSwitch:       DB  0FFh
;@ OptionAlternatorControlCheck type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Alternator control check. Sets flag 216h bit 6. With flag 219h bit 1: the alternator control (ALTC) check; also a condition of the closed-loop O2 gate."
OptionAlternatorControlCheck:       DB  0FFh,000h,000h,0FFh
;@ OptionBaroSensor type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Barometric pressure sensor (code 13). Sets flag 227h bit 4. Reads the baro sensor; without it baro is the fixed value F9h."
OptionBaroSensor:       DB  0FFh
;@ OptionSecondSensorInputs type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Knock and O2 on the second inputs. Sets flag 219h bit 1. Knock read from 3CCh instead of 0C7h, the O2 closed-loop gate on 39Bh, codes 10 and 25, and (with 216h bit 6) the alternator control check."
OptionSecondSensorInputs:       DB  0FFh
;@ OptionKnockWindowAlwaysOpen type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Knock window open at any rpm. Sets flag 217h bit 3. The knock window is open whatever the rpm (otherwise only below the 6000h period point)."
OptionKnockWindowAlwaysOpen:       DB  0FFh,000h,000h,000h
;@ OptionKnockRetardByIntakeAir type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Knock retard limited by intake air. Sets flag 227h bit 7. The knock retard is limited by the intake air temperature (none above B5h)."
OptionKnockRetardByIntakeAir:       DB  000h
;@ OptionUnused216Bit1 type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Unused flag. Sets flag 216h bit 1. Set from its option byte at power-up; nothing in the code reads it."
OptionUnused216Bit1:       DB  0FFh,000h
;@ OptionAutomaticTransmission type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Automatic transmission. Sets flag 216h bit 3. The A/T shift and lock-up control, the A/T idle, decel-cut, tip-in and knock tables, and the A/T checks (codes 17, 19, 30). Used when OptionFlagsFromBytes is on; otherwise the board's resistors decide."
OptionAutomaticTransmission:       DB  000h,000h,000h,000h,000h,000h,000h,0FFh
;@ OptionVtecCoolantGate type=u8 flag=1 on=255 off=0 category="Options" desc="Option: coolant condition on VTEC engagement and flag 221h.6."
OptionVtecCoolantGate: DB  000h
;@ OptionFlagsFromBytes type=u8 flag=1 on=255 off=0 category="Options" desc="Where the equipment flags come from: non-zero, the option bytes OptionAutomaticTransmission ... OptionSerialDiagMode; zero, the resistors on the board (read at power-up into 3BFh/3C7h/3C6h/3C3h). Also selects the knock scaling (IdleControlScale)."
OptionFlagsFromBytes:DB  000h
;@ OptionIdleStrategy2 type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Second idle strategy. Sets flag 227h bit 1. The other idle speed and state logic (2C2h-2C8h) and the idle coolant correction."
OptionIdleStrategy2:       DB  000h
;@ OptionLowSpeedRetardCap type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Knock retard cap below 45 km/h. Sets flag 216h bit 2. Caps the knock retard (at 7Ah) below 45 km/h, has the stored fuel values checked against the fault flag, handles code 13 (0A0h.0) and is part of the model code. Used when OptionFlagsFromBytes is on; otherwise the board's resistors decide."
OptionLowSpeedRetardCap:       DB  0FFh
;@ OptionAltKnockShiftTables type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Second knock levels and shift points. Sets flag 216h bit 0. Picks the second half of the knock level table and the other A/T shift-point tables; also part of the model code the diagnostic link reports. Used when OptionFlagsFromBytes is on; otherwise the board's resistors decide."
OptionAltKnockShiftTables:       DB  0FFh
;@ OptionIdleValveType2 type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Second idle valve type. Sets flag 217h bit 6. The idle valve PID gains and tables for the other valve type, and the intake air check (code 10) skipped. Used when OptionFlagsFromBytes is on; otherwise the board's resistors decide."
OptionIdleValveType2:       DB  0FFh
;@ OptionKnockSensor type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte (bit 7 = on): Knock sensor (codes 23, 26). Sets flag 216h bit 5. Reads the knock sensor, sets codes 23 and 26, and has the scheduler run the knock task. Used when OptionFlagsFromBytes is on; otherwise the board's resistors decide."
OptionKnockSensor:       DB  000h,000h
                DB  000h
;@ OptionUnused16 type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte read at power-up into a carry that is then replaced by Option18's: it has no effect."
OptionUnused16:       DB  0FFh,000h
;@ OptionSerialDiagMode type=u8 flag=1 on=255 off=0 category="Options" desc="Option byte, bit 7 = on: the serial / diagnostic mode (354h bit 1), when OptionFlagsFromBytes is on; otherwise the board's resistor input 3C3h decides."
OptionSerialDiagMode:       DB  0FFh,0FFh
;@ InjectorTimerSelect type=u8 count=6 formula=raw category="Fuel" desc="Injector timer values picked by the bank flags 123h.0/123h.1."
InjectorTimerSelect:DB  008h,00Ah,00Ah
                DB  00Bh,00Bh,00Bh
;@ ThrottleFilterRate type=u8 count=4 formula=raw category="Throttle" desc="Throttle filter steps (two ranges of the MAP delta)."
ThrottleFilterRate:DB  004h,00Bh,004h,00Bh
;@ ThrottleFilterLimit type=u8 count=6 formula=raw category="Throttle" desc="Throttle filter limits (three ranges of the MAP delta)."
ThrottleFilterLimit:DB  040h
                DB  040h,040h,030h,030h,020h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,0FFh,0B3h,0F5h
                DB  0B3h,0E6h,0A6h,0CFh,0A0h,0A1h,096h,06Eh
                DB  091h,02Eh,08Ah,028h,080h,000h,080h,0FFh
                DB  0DAh,0F5h,0DAh,0E6h,0BDh,0CFh,0B6h,0A1h
                DB  0ADh,06Eh,0A4h,02Eh,09Ah,028h,080h,000h
                DB  080h,0FFh,080h,000h,080h,000h,080h,000h
                DB  080h,000h,080h,000h,080h,000h,080h,000h
                DB  080h,000h,080h,0FFh,08Dh,0A1h,08Dh,06Eh
                DB  08Ah,044h,088h,02Eh,084h,028h,080h,000h
                DB  080h,000h,080h,000h,080h,0FFh,08Ah,0E0h
                DB  08Ah,0D0h,085h,0A1h,073h,044h,050h,02Eh
                DB  040h,000h,040h,000h,040h,000h,040h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,0FFh,040h,0D7h
                DB  040h,0D2h,05Ah,0CFh,073h,000h,073h,000h
                DB  073h,0FFh,0CCh,08Ch,0F5h,0CCh,08Ch,0E6h
                DB  0D4h,088h,0CFh,0DDh,084h,0A1h,068h,081h
                DB  057h,000h,080h,034h,05Ch,07Fh,018h,056h
                DB  07Eh,000h,056h,07Eh,0FFh,0A4h,090h,0F5h
                DB  0A4h,090h,0E6h,08Bh,08Ch,0CFh,052h,088h
                DB  0A1h,07Bh,084h,057h,000h,080h,034h,0CDh
                DB  07Ch,018h,0E1h,07Ah,000h,0E1h,07Ah,0FFh
                DB  09Ch,094h,0F5h,09Ch,094h,0E6h,021h,090h
                DB  0CFh,0A6h,08Bh,0A1h,0C9h,086h,057h,000h
                DB  080h,034h,085h,07Bh,018h,099h,079h,000h
                DB  099h,079h
;@ PostFuelDecay type=u16 count=4 formula=raw category="Fuel" desc="After-start fuel: decay steps (manual transmission)."
PostFuelDecay:  DB  000h,0B0h,000h,00Dh,0C0h,001h
                DB  020h,000h
;@ PostFuelDecay2 type=u16 count=4 formula=raw category="Fuel" desc="After-start fuel: decay steps (flag 116h.3)."
PostFuelDecay2: DB  000h,0B0h,000h,00Dh,0C0h,001h
                DB  020h,000h
;@ PostFuelDecay3 type=u16 count=4 formula=raw category="Fuel" desc="After-start fuel: decay steps (flag 111h.5)."
PostFuelDecay3: DB  000h,0B0h,000h,00Dh,0C0h,001h
                DB  020h,000h,0FFh,000h,0A0h,0F5h,000h,0A0h
                DB  0E6h,000h,070h,0CFh,09Ah,059h,0A1h,09Ah
                DB  039h,06Eh,000h,030h,02Eh,0C3h,025h,000h
                DB  0C3h,025h,000h,0C3h,025h
;@ ClosedLoopOffsets type=u16 count=6 formula=raw category="Closed loop" desc="Closed-loop trim offsets, picked by coolant temperature."
ClosedLoopOffsets:DB  001h,000h,000h
                DB  001h,001h,000h,000h,002h,001h,000h,000h
                DB  004h,0ADh,02Eh,0A7h,054h,0B5h,038h,0A7h
                DB  060h,0B5h,038h,0A7h,060h
;@ ClosedLoopRate type=u16 count=12 formula=raw category="Closed loop" desc="Closed-loop trim rates."
ClosedLoopRate: DB  080h,000h,080h
                DB  000h,080h,000h,080h,000h,018h,000h,000h
                DB  000h,080h,000h,080h,000h,080h,000h,080h
                DB  000h,018h,000h,000h,000h
;@ ClosedLoopStep type=u16 count=28 formula=raw category="Closed loop" desc="Closed-loop trim steps (on a change of O2 state)."
ClosedLoopStep: DB  000h,001h,000h
                DB  004h,040h,004h,0A0h,004h,020h,001h,000h
                DB  000h,000h,001h,000h,004h,040h,004h,0A0h
                DB  004h,020h,001h,000h,000h,080h,000h,080h
                DB  000h,080h,000h,080h,000h,018h,000h,000h
                DB  000h,080h,000h,080h,000h,080h,000h,080h
                DB  000h,018h,000h,000h,000h,000h,001h,000h
                DB  004h,040h,004h,0A0h,004h,020h,001h,000h
                DB  000h,000h,001h,000h,004h,040h,004h,0A0h
                DB  004h,020h,001h,000h,000h,0FFh,030h,0E5h
                DB  030h,0E0h,080h,0DDh,0BDh,0A0h,0E6h,060h
                DB  0E6h,040h,0D0h,000h,0D0h,0FFh,000h,000h
                DB  000h,0FFh,080h,01Fh,080h,018h,080h,013h
                DB  08Bh,00Fh,08Bh,000h,08Bh,0FFh,06Eh,0C0h
                DB  06Eh,0A0h,06Ch,080h,059h,060h,04Dh,000h
                DB  03Bh,0FFh,076h,0C0h,076h,0A0h,073h,080h
                DB  061h,060h,054h,000h,042h,0FFh,080h,0E0h
                DB  080h,0D0h,082h,080h,082h,070h,080h,000h
                DB  080h,0FFh,080h,0D5h,080h,0C7h,082h,072h
                DB  082h,064h,080h,000h,080h,0FFh,093h,0A1h
                DB  093h,087h,086h,06Eh,07Ah,044h,066h,028h
                DB  054h,000h,054h,0FFh,086h,0A1h,086h,087h
                DB  071h,06Eh,05Eh,044h,051h,028h,041h,000h
                DB  041h,0FFh,093h,0A1h,093h,087h,086h,06Eh
                DB  07Ah,044h,066h,028h,054h,000h,054h,0FFh
                DB  086h,0A1h,086h,087h,071h,06Eh,05Eh,044h
                DB  051h,028h,041h,000h,041h,080h,080h,080h
                DB  080h,0FFh,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,0FFh,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,0FFh,05Ah,000h,0A7h,05Ah,000h,093h
                DB  07Eh,000h,07Eh,0AEh,000h,069h,0F6h,000h
                DB  054h,07Dh,001h,000h,07Dh,001h,000h,000h
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
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,0FFh,04Dh
                DB  000h,0D0h,04Dh,000h,06Eh,080h,000h,040h
                DB  0D0h,000h,028h,000h,001h,000h,000h,001h
                DB  0FFh,04Dh,000h,0D0h,04Dh,000h,06Eh,066h
                DB  000h,040h,080h,000h,028h,000h,001h,000h
                DB  000h,001h,030h,0DAh,000h,010h,000h,001h
                DB  030h,0E6h,000h,010h,000h,001h,030h,0CAh
                DB  000h,008h,000h,001h,030h,0DCh,000h,008h
                DB  000h,001h,030h,000h,001h,010h,000h,001h
                DB  0FFh,080h,000h,080h,0FFh,014h,000h,095h
                DB  014h,000h,06Dh,03Ch,000h,04Dh,080h,000h
                DB  034h,0E0h,000h,027h,00Eh,001h,000h,00Eh
                DB  001h,0FFh,04Bh,000h,0CFh,04Bh,000h,0A2h
                DB  07Dh,000h,06Eh,07Dh,000h,000h,07Dh,000h
                DB  0FFh,0A0h,0EDh,0A0h,0D0h,094h,0A1h,090h
                DB  06Eh,058h,028h,010h,000h,010h,0FFh,0A0h
                DB  0EDh,0A0h,0D0h,094h,0A1h,090h,06Eh,058h
                DB  028h,010h,000h,010h,0FFh,060h,0EDh,060h
                DB  0D0h,050h,0A1h,040h,06Eh,038h,028h,008h
                DB  000h,008h,0FFh,060h,0EDh,060h,0D0h,050h
                DB  0A1h,040h,06Eh,038h,028h,008h,000h,008h
                DB  0FFh,080h,0EDh,080h,0CFh,060h,0A1h,050h
                DB  06Eh,030h,028h,010h,000h,010h,0FFh,080h
                DB  0EDh,080h,0CFh,060h,0A1h,050h,06Eh,030h
                DB  028h,010h,000h,010h,0FFh,030h,075h,0F5h
                DB  030h,075h,0E6h,05Ch,044h,0CFh,0D4h,030h
                DB  0A1h,0F9h,015h,06Eh,035h,00Ch,028h,0D0h
                DB  007h,020h,0D0h,007h,000h,0D0h,007h,030h
                DB  080h,012h,05Ah,0FFh,080h,000h,080h,0FFh
                DB  093h,0A1h,093h,087h,086h,06Eh,07Ah,044h
                DB  066h,028h,054h,000h,054h,0FFh,088h,0A1h
                DB  088h,087h,073h,06Eh,060h,044h,053h,028h
                DB  043h,000h,043h,0FFh,093h,0A1h,093h,087h
                DB  086h,06Eh,07Ah,044h,066h,028h,054h,000h
                DB  054h,0FFh,088h,0A1h,088h,087h,073h,06Eh
                DB  060h,044h,053h,028h,043h,000h,043h,0FFh
                DB  033h,0E0h,024h,0C0h,017h,098h,019h,080h
                DB  019h,000h,019h,0FFh,027h,0E0h,018h,0C0h
                DB  00Bh,098h,013h,080h,013h,000h,013h,0FFh
                DB  000h,000h,000h
;@ StockRevLimitA type=u8 count=6 formula=raw category="Limits" desc="Stock rev limiter set A: cut/resume points (flag 21Fh.1 off)."
StockRevLimitA: DB  01Eh,02Bh,0EDh,000h,067h
                DB  001h
;@ StockRevLimitB type=u8 count=6 formula=raw category="Limits" desc="Stock rev limiter set B: cut/resume points (flag 21Fh.1 off)."
StockRevLimitB: DB  01Eh,02Bh,0E7h,000h,01Dh,001h
;@ StockRevLimitC type=u8 count=6 formula=raw category="Limits" desc="Stock rev limiter set A: cut/resume points (flag 21Fh.1 on)."
StockRevLimitC: DB  01Eh
                DB  02Bh,0EDh,000h,067h,001h
;@ StockRevLimitD type=u8 count=6 formula=raw category="Limits" desc="Stock rev limiter set B: cut/resume points (flag 21Fh.1 on)."
StockRevLimitD: DB  01Eh,02Bh,0E7h
                DB  000h,01Dh,001h
;@ KnockFuelMultiplier type=u16 count=12 formula=raw category="Knock" desc="Knock: fuel multipliers by knock level (RAM 150h)."
KnockFuelMultiplier:DB  033h,073h,09Ah,079h,000h
                DB  080h,066h,086h,0CDh,08Ch,0CDh,08Ch,033h
                DB  073h,09Ah,079h,000h,080h,066h,086h,0CDh
                DB  08Ch,0CDh,08Ch
;@ KnockLevels type=u16 count=24 formula=raw category="Knock" desc="Knock: detection levels (manual)."
KnockLevels:    DB  026h,004h,0ABh,004h,030h
                DB  005h,0B4h,005h,039h,006h,039h,006h,099h
                DB  004h,02Ch,005h,0C0h,005h,053h,006h,0E6h
                DB  006h,0E6h,006h,04Ch,005h,0F6h,005h,0A0h
                DB  006h,049h,007h,0F3h,007h,0F3h,007h,026h
                DB  004h,0ABh,004h,030h,005h,0B4h,005h,039h
                DB  006h,039h,006h,099h,004h,02Ch,005h,0C0h
                DB  005h,053h,006h,0E6h,006h,0E6h,006h,04Ch
                DB  005h,0F6h,005h,0A0h,006h,049h,007h,0F3h
                DB  007h,0F3h,007h
;@ KnockLevelsAuto type=u16 count=24 formula=raw category="Knock" desc="Knock: detection levels (automatic)."
KnockLevelsAuto:DB  026h,004h,0ABh,004h,030h
                DB  005h,0B4h,005h,039h,006h,039h,006h,099h
                DB  004h,02Ch,005h,0C0h,005h,053h,006h,0E6h
                DB  006h,0E6h,006h,04Ch,005h,0F6h,005h,0A0h
                DB  006h,049h,007h,0F3h,007h,0F3h,007h,026h
                DB  004h,0ABh,004h,030h,005h,0B4h,005h,039h
                DB  006h,039h,006h,099h,004h,02Ch,005h,0C0h
                DB  005h,053h,006h,0E6h,006h,0E6h,006h,04Ch
                DB  005h,0F6h,005h,0A0h,006h,049h,007h,0F3h
                DB  007h,0F3h,007h
;@ GearRatios type=u16 count=4 formula=raw category="Transmission" desc="Gear detection: rpm-to-speed ratio boundaries between gears."
GearRatios:     DB  046h,000h,06Eh,000h,096h
                DB  000h,0C5h,000h,0CAh,0CEh
;@ VTECRpmLoadAuto type=u8 count=4 formula=raw category="VTEC" desc="VTEC engage / disengage rpm (automatic): word pairs."
VTECRpmLoadAuto:DB  0CAh,0CEh,0FFh
                DB  0FFh,000h,0FFh,000h,0FFh,000h,0FFh,0FFh
                DB  0FFh,000h,0FFh,000h,0FFh,000h,0FFh,0FFh
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,0FFh,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h
;@ VTECPressureTable type=u8 count=28 formula=raw category="VTEC" desc="VTEC oil-pressure switch timing, indexed by RAM 0BFh."
VTECPressureTable:DB  0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,0FFh
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,0FFh,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,0FFh
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
;@ VTECTransition type=u8 count=6 formula=raw category="VTEC" desc="VTEC change-over fuel/timing steps."
VTECTransition: DB  000h,000h,011h,055h,077h
                DB  0FFh,0FFh,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,0FFh,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,0FFh,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,0FFh,000h
                DB  013h,0E1h,000h,011h,0CFh,000h,011h,0A1h
                DB  000h,018h,068h,000h,018h,050h,000h,013h
                DB  044h,000h,00Fh,028h,000h,000h,000h,000h
                DB  000h,0FFh,000h,013h,0E1h,000h,011h,0CFh
                DB  000h,011h,0A1h,000h,018h,068h,000h,018h
                DB  050h,000h,013h,044h,000h,00Fh,028h,000h
                DB  000h,000h,000h,000h,0FFh,0FFh,03Fh,0F5h
                DB  0FFh,03Fh,0E6h,000h,030h,0CFh,000h,026h
                DB  068h,000h,024h,050h,000h,01Eh,028h,000h
                DB  00Ch,020h,000h,014h,000h,000h,019h,0FFh
                DB  0FFh,03Fh,0F5h,0FFh,03Fh,0E6h,000h,030h
                DB  0CFh,000h,026h,068h,000h,024h,050h,000h
                DB  01Eh,028h,000h,00Ch,020h,000h,014h,000h
                DB  000h,019h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,0FFh,094h,004h,0A1h,094h,004h
                DB  087h,00Dh,005h,06Eh,0A2h,005h,044h,053h
                DB  007h,028h,077h,00Ah,000h,077h,00Ah,0FFh
                DB  094h,004h,0A1h,094h,004h,087h,00Dh,005h
                DB  06Eh,0A2h,005h,044h,053h,007h,028h,0B8h
                DB  008h,000h,0B8h,008h
;@ IdleAirTarget1 type=u8 count=28 formula=raw category="Idle" desc="Idle air against target idle speed (4-byte entries; flag 21Ah.5 clear)."
IdleAirTarget1: DB  0FFh,0FFh,062h,000h
                DB  077h,00Ah,062h,000h,053h,007h,030h,000h
                DB  0A2h,005h,01Ch,000h,00Dh,005h,016h,000h
                DB  094h,004h,012h,000h,000h,000h,012h,000h
;@ IdleAirTarget2 type=u8 count=28 formula=raw category="Idle" desc="Idle air against target idle speed (4-byte entries; flag 21Ah.5 set)."
IdleAirTarget2: DB  0FFh,0FFh,06Fh,000h,077h,00Ah,06Fh,000h
                DB  053h,007h,037h,000h,0A2h,005h,020h,000h
                DB  00Dh,005h,01Ah,000h,094h,004h,016h,000h
                DB  000h,000h,016h,000h,0FFh,0FFh,054h,002h
                DB  077h,00Ah,054h,002h,053h,007h,039h,001h
                DB  0A2h,005h,0C0h,000h,00Dh,005h,09Dh,000h
                DB  094h,004h,083h,000h,000h,000h,083h,000h
;@ IdleStep1 type=u8 count=6 formula=raw category="Idle" desc="Idle control steps."
IdleStep1:      DB  0FFh,0FFh,000h,001h,000h,004h
;@ IdleStepDefault type=u8 count=6 formula=raw category="Idle" desc="Idle control steps (default)."
IdleStepDefault:DB  0FFh,0FFh
                DB  000h,00Ch,000h,008h
;@ IdleStep2 type=u8 count=6 formula=raw category="Idle" desc="Idle control steps."
IdleStep2:      DB  000h,080h,000h,009h
                DB  040h,000h
;@ IdleStepGear type=u8 count=6 formula=raw category="Idle" desc="Idle control steps in gear."
IdleStepGear:   DB  000h,000h,000h,080h,001h,000h
;@ IdleTimer type=u8 count=6 formula=raw category="Idle" desc="Idle control timers."
IdleTimer:      DB  0FFh,0FFh,0FFh,0FFh,000h,000h,0FFh,0FFh
                DB  0FFh,0FFh,000h,000h,0FFh,000h,000h,0C0h
                DB  000h,000h,0A0h,080h,001h,080h,000h,002h
                DB  030h,000h,003h,000h,000h,003h,0FFh,000h
                DB  002h,0C0h,000h,002h,057h,000h,004h,036h
                DB  000h,006h,020h,000h,007h,000h,000h,007h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,0FFh,000h,000h,000h,0FFh,08Bh
                DB  0A1h,08Bh,087h,07Ch,06Eh,06Ah,044h,056h
                DB  028h,049h,000h,049h,0FFh,014h,000h,0A1h
                DB  014h,000h,087h,014h,000h,06Eh,014h,000h
                DB  044h,014h,000h,028h,014h,000h,000h,014h
                DB  000h,0FFh,0C0h,0A1h,0C0h,087h,0A0h,06Eh
                DB  078h,044h,064h,028h,05Ah,000h,05Ah,0FFh
                DB  00Ah,0A1h,00Ah,087h,008h,06Eh,008h,044h
                DB  005h,028h,002h,000h,002h,0FFh,016h,0A1h
                DB  016h,087h,015h,06Eh,014h,044h,013h,028h
                DB  012h,000h,012h,0FFh,09Fh,040h,09Fh,02Ch
                DB  08Fh,020h,080h,01Ah,07Ch,000h,07Ch,0FFh
                DB  08Fh,040h,08Fh,02Ch,080h,020h,073h,01Ah
                DB  06Fh,000h,06Fh,0FFh,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,0FFh
                DB  09Fh,040h,09Fh,02Ch,08Fh,020h,080h,01Ah
                DB  07Ch,000h,07Ch,0FFh,08Fh,040h,08Fh,02Ch
                DB  080h,020h,073h,01Ah,06Fh,000h,06Fh
;@ IdleIntegralGainHigh1 type=u8 count=18 formula=raw category="Idle" desc="Idle control gain against rpm (word values)."
IdleIntegralGainHigh1:DB  0FFh
                DB  020h,005h,0D0h,0C0h,003h,0B4h,0C0h,002h
                DB  08Ch,080h,000h,080h,000h,000h,000h,000h
                DB  000h
;@ IdleIntegralGainHigh2 type=u8 count=18 formula=raw category="Idle" desc="Idle control gain against rpm (word values)."
IdleIntegralGainHigh2:DB  0FFh,0B0h,006h,0D0h,000h,005h,0B4h
                DB  070h,003h,08Ch,060h,001h,07Ch,000h,000h
                DB  000h,000h,000h
;@ IdleIntegralGainHigh3 type=u8 count=18 formula=raw category="Idle" desc="Idle control gain against rpm (word values)."
IdleIntegralGainHigh3:DB  0FFh,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h
;@ IdleIntegralGainAutoC type=u8 count=18 formula=raw category="Idle" desc="Idle control gain against rpm (word values)."
IdleIntegralGainAutoC:DB  0FFh,020h,005h
                DB  0D0h,0C0h,003h,0B4h,0C0h,002h,08Ch,080h
                DB  000h,080h,000h,000h,000h,000h,000h
;@ IdleIntegralGainAutoD type=u8 count=18 formula=raw category="Idle" desc="Idle control gain against rpm (word values)."
IdleIntegralGainAutoD:DB  0FFh
                DB  0B0h,006h,0D0h,000h,005h,0B4h,070h,003h
                DB  08Ch,060h,001h,07Ch,000h,000h,000h,000h
                DB  000h,0FFh,080h,000h,080h,000h,080h,000h
                DB  080h,000h,080h,0FFh,000h,00Bh,036h,000h
                DB  00Ch,020h,000h,012h,018h,000h,014h,000h
                DB  000h,015h,0FFh,000h,00Bh,036h,000h,00Ch
                DB  020h,000h,012h,018h,000h,014h,000h,000h
                DB  015h,0FFh,0C0h,0B0h,0C0h,080h,098h,053h
                DB  080h,000h,080h,0FFh,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
;@ IdleIntegratorTarget type=u8 count=20 formula=raw category="Idle" desc="Idle integrator limit against target idle."
IdleIntegratorTarget:DB  0FFh,0FFh
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h
;@ IdleElectricalLoadCorrection type=u8 count=6 formula=raw category="Idle" desc="Idle correction against the electrical load (manual)."
IdleElectricalLoadCorrection:DB  040h,0FFh,03Fh,004h,000h,000h
;@ IdleElectricalLoadCorrectionAuto type=u8 count=6 formula=raw category="Idle" desc="Idle correction against the electrical load (automatic)."
IdleElectricalLoadCorrectionAuto:DB  040h,0FFh,03Fh,004h,000h,000h,080h,080h
                DB  080h,080h,080h,0FFh,0FFh,03Fh,0C0h,0FFh
                DB  03Fh,080h,000h,01Ch,040h,000h,008h,000h
                DB  000h,006h,0FFh,000h,003h,000h,000h,003h
                DB  000h,000h,003h,000h,000h,003h,000h,000h
                DB  003h,0FFh,000h,006h,000h,000h,006h,000h
                DB  000h,006h,000h,000h,006h,000h,000h,006h
                DB  0FFh,0FFh,03Fh,079h,0FFh,03Fh,055h,000h
                DB  020h,040h,000h,01Ah,039h,000h,00Ch,032h
                DB  000h,004h,02Bh,000h,000h,000h,000h,000h
                DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,0FFh,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,0FFh,000h,000h,02Ah
                DB  000h,000h,027h,080h,000h,023h,000h,001h
                DB  000h,000h,001h,000h,000h,001h,0FFh,080h
                DB  000h,080h,0FFh,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,0FFh,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
;@ IdleDutyTarget type=u8 count=32 formula=raw category="Idle" desc="Idle valve duty against target (4-byte entries)."
IdleDutyTarget: DB  0FFh,0FFh,0FFh,0FFh,0FFh,03Fh,000h,0C0h
                DB  080h,036h,066h,0A6h,0F0h,018h,000h,080h
                DB  010h,00Ah,066h,066h,000h,003h,033h,053h
                DB  0A0h,000h,066h,046h,000h,000h,0CCh,02Ch
;@ IdleDuty type=u8 count=32 formula=raw category="Idle" desc="Idle valve duty curve (4-byte entries)."
IdleDuty:       DB  0FFh,0FFh,000h,080h,000h,00Ah,000h,080h
                DB  000h,008h,01Eh,085h,080h,006h,01Eh,085h
                DB  000h,003h,085h,07Bh,000h,002h,033h,073h
                DB  000h,001h,028h,05Ch,000h,000h,028h,05Ch
                DB  0FFh,0B8h,0ABh,09Ah,055h,05Ch,047h,055h
                DB  039h,04Dh,02Bh,03Ch,00Bh,010h,000h,010h
                DB  0FFh,01Ch,0BCh,02Eh,0A7h,034h,092h,040h
                DB  07Dh,050h,068h,068h,054h,0A0h,03Fh,0D9h
                DB  000h,0D9h,000h,0D9h,0FFh,03Bh,0AAh,025h
                DB  071h,017h,038h,009h,01Ch,002h,013h,000h
                DB  000h,000h,0FFh,000h,0AEh,000h,084h,01Eh
                DB  054h,01Eh,045h,000h,000h,000h
;@ KnockRetardLimit type=u8 count=3 formula=raw category="Knock" desc="Knock retard limits."
KnockRetardLimit:DB  0D4h,0AEh
                DB  0FFh,073h,0F5h,073h,0CFh,055h,0A1h,02Eh
                DB  057h,015h,02Eh,000h,000h,000h,0FFh,073h
                DB  0F5h,073h,0CFh,04Ch,0A1h,022h,057h,00Ch
                DB  02Eh,000h,000h,000h
;@ KnockSteps type=u8 count=4 formula=raw category="Knock" desc="Knock retard steps."
KnockSteps:     DB  077h,064h,0D4h,064h
                DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,0FFh,000h,01Ch,000h
                DB  018h,00Dh,00Fh,015h,000h,015h,000h,015h
                DB  0FFh,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h,0FFh,000h,06Ch,000h
                DB  044h,00Ch,02Eh,015h,000h,015h
;@ HighIdleIgnition type=u16 count=4 colstride=4 formula=degrees_quarter cols.axis=HighIdleIgnitionTbl cols.type=u16 cols.stride=4 cols.unit=counts category="Idle" desc="Idle held with timing once warm (coolant byte below 54h), one of a pair picked by flag 1Ah.4, against RAM 0CAh (the ROM's own units, not converted); the result is capped at 0Eh (3.5 degrees)." at=HighIdleIgnitionTbl+2
HighIdleIgnitionTbl:DB  0FFh,0FFh
                DB  015h,000h,0CDh,000h,015h,000h,073h,000h
                DB  00Ch,000h,000h,000h,000h,000h
;@ LowIdleIgnition type=u16 count=4 colstride=4 formula=degrees_quarter cols.axis=LowIdleIgnitionTbl cols.type=u16 cols.stride=4 cols.unit=counts category="Idle" desc="Idle held with timing once warm (coolant byte below 54h), one of a pair picked by flag 1Ah.4, against RAM 0CAh (the ROM's own units, not converted); the result is capped at 0Eh (3.5 degrees)." at=LowIdleIgnitionTbl+2
LowIdleIgnitionTbl:DB  0FFh,0FFh
                DB  015h,000h,0B2h,000h,015h,000h,068h,000h
                DB  00Ch,000h,000h,000h,000h,000h
;@ DwellMapHigh type=u8 count=19 formula=raw category="Dwell" desc="Dwell / knock window map (high cam)."
DwellMapHigh:   DB  000h,000h
                DB  000h,000h,015h,01Ah,01Eh,01Bh,01Ah,026h
                DB  039h,03Eh,03Eh,03Eh,03Eh,000h,000h,000h
                DB  000h
;@ RamInitValues type=u8 count=14 formula=raw category="Internal" desc="Start-up values copied to RAM."
RamInitValues:  DB  000h,000h,000h,000h,000h,015h,01Ah
                DB  01Eh,01Bh,01Ah,026h,039h,03Eh,03Eh,03Eh
                DB  03Eh,000h,000h,000h,000h,000h
;@ DwellMapLow type=u8 count=40 formula=raw category="Dwell" desc="Dwell / knock window map (low cam)."
DwellMapLow:    DB  000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,015h,01Eh,01Ah
                DB  039h,03Eh,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,015h,01Eh,01Ah,039h,03Eh,0FFh,050h
                DB  0D0h,040h,0C0h,038h,0A0h,030h,080h,030h
                DB  040h,028h,000h,028h,0FFh,055h,0C0h,055h
                DB  090h,055h,080h,055h,066h,055h,040h,02Ah
                DB  000h,02Ah,001h,004h,003h,001h,001h,0FFh
                DB  080h,04Dh,080h,040h,05Ah,030h,040h,028h
                DB  026h,000h,026h,0FFh,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h
;@ GearTipInScale type=u8 count=8 formula=raw category="Transmission" desc="Per-gear scale (RAM 250h)."
GearTipInScale: DB  080h,080h,080h,05Ah,047h,0ADh,070h
                DB  02Eh,060h,0F0h,020h,070h
;@ CoolantFailWarmup type=u8 count=5 formula=raw category="Sensors" desc="Coolant readings used while the sensor has failed (a warm-up ramp)."
CoolantFailWarmup:DB  0E1h,0D0h,0A1h
                DB  070h,028h,0C2h,000h,0FAh,03Eh,000h,047h
                DB  0E5h,000h,051h,03Eh,000h,019h,02Ch,0A0h
                DB  025h,05Ah
;@ KnockWindowHigh type=u8 count=20 formula=raw category="Knock" desc="Knock window (high cam)."
KnockWindowHigh:DB  000h,02Bh,02Bh,02Bh,02Bh,02Bh
                DB  02Bh,02Fh,02Fh,027h,023h,018h,011h,011h
                DB  011h,000h,000h,000h,000h,000h
;@ KnockWindowLow type=u8 count=14 formula=raw category="Knock" desc="Knock window (low cam)."
KnockWindowLow: DB  02Bh,02Bh
                DB  02Bh,02Bh,02Bh,02Bh,02Bh,027h,027h,027h
                DB  02Bh,02Bh,02Bh,02Bh
;@ SerialRamMap type=u8 count=262 formula=raw category="Internal" desc="Serial link: the RAM each tester address reads (not a tuning value)."
SerialRamMap:   DB  02Bh,02Bh,02Bh,027h
                DB  01Ah,010h,0A1h,003h,0A0h,003h,09Fh,003h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,0B0h,003h,0B1h,003h,0B2h,003h
                DB  0B3h,003h,0B4h,003h,0B5h,003h,0B6h,003h
                DB  0B7h,003h,0D4h,003h,0CCh,003h,0BBh,000h
                DB  0CDh,003h,0A4h,003h,0DAh,000h,000h,004h
                DB  0DBh,000h,0A5h,003h,0D2h,003h,0D7h,000h
                DB  000h,004h,0D2h,003h,000h,004h,000h,004h
                DB  000h,004h,059h,001h,000h,004h,005h,003h
                DB  000h,004h,0A3h,003h,0A2h,003h,05Bh,003h
                DB  044h,002h,0ADh,003h,09Dh,000h,0AEh,003h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,0D2h,001h,0D3h,001h
                DB  0D1h,001h,0DAh,001h,0DBh,001h,0D9h,001h
                DB  0AFh,003h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,024h,003h,025h,003h,026h,003h
                DB  027h,003h,028h,003h,029h,003h,02Ah,003h
                DB  02Bh,003h,02Ch,003h,02Dh,003h,02Eh,003h
                DB  02Fh,003h,030h,003h,031h,003h,032h,003h
                DB  033h,003h,034h,003h,035h,003h,036h,003h
                DB  037h,003h,038h,003h,039h,003h,03Ah,003h
                DB  03Bh,003h,03Ch,003h,03Dh,003h,03Eh,003h
                DB  03Fh,003h,040h,003h,041h,003h,042h,003h
                DB  043h,003h,044h,003h,045h,003h,046h,003h
                DB  047h,003h,048h,003h,049h,003h,04Ah,003h
                DB  04Bh,003h,04Ch,003h,04Dh,003h,04Eh,003h
                DB  04Fh,003h,050h,003h,051h,003h,052h,003h
                DB  053h,003h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,0A8h,003h,0A9h,003h,0AAh,003h
                DB  0ABh,003h,0ACh,003h,000h,004h,000h,004h
                DB  000h,004h
;@ RamInitValues2 type=u8 count=12 formula=raw category="Internal" desc="Start-up values for RAM 1A9h-1B5h (not a tuning value)."
RamInitValues2: DB  02Dh,02Dh,007h,006h,0FFh,0FFh
                DB  0FFh,0FFh,019h,019h,019h,0B3h
;@ TroubleCodeDebounce type=u8 count=49 formula=raw category="Internal" desc="Trouble codes: debounce counts per code (not a tuning value)."
TroubleCodeDebounce:DB  00Bh,00Fh
                DB  00Fh,00Fh,0FFh,02Dh,04Bh,00Fh,0FFh,0FFh
                DB  0FFh,0FFh,02Dh,02Dh,0FFh,0FFh,02Dh,006h
                DB  02Dh,00Fh,00Fh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,014h,0FFh,0FFh,0FFh,0FFh,0FFh,02Dh
                DB  02Dh,007h,006h,0FFh,0FFh,0FFh,0FFh,019h
                DB  019h,019h,0FFh,0FFh,0FFh,0FFh,0B3h
;@ TroubleCodeNumbers type=u8 count=49 formula=raw category="Internal" desc="Trouble codes: code numbers (not a tuning value)."
TroubleCodeNumbers:DB  00Bh
                DB  003h,006h,007h,005h,001h,008h,00Ah,00Bh
                DB  00Ch,00Ch,00Dh,00Eh,011h,000h,013h,014h
                DB  015h,016h,017h,018h,01Eh,01Fh,000h,000h
                DB  019h,01Ah,01Bh,000h,000h,000h,000h,000h
                DB  004h,008h,009h,00Fh,01Eh,01Fh,010h,013h
                DB  004h,008h,009h,000h,000h,000h,000h,01Dh
                DB  001h,094h,000h
;@ DiagSnapshot2 type=u8 count=5 formula=raw category="Internal" desc="Diagnostic snapshot limits (not a tuning value)."
DiagSnapshot2:  DB  0FFh,0FFh,019h,019h,019h
;@ CrankSyncPattern type=u8 count=24 formula=raw category="Internal" desc="Crank signal decoding (not a tuning value)."
CrankSyncPattern:DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FEh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FDh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FEh,0FFh,0FFh,0FFh,0FFh,0FFh,0FDh
;@ CrankToothPattern type=u8 count=30 formula=raw category="Internal" desc="Crank signal decoding (not a tuning value)."
CrankToothPattern:DB  007h,008h,009h,00Ah,00Bh,000h,001h,002h
                DB  003h,004h,005h,006h,007h,008h,009h,00Ah
                DB  00Bh,000h,001h,002h,003h,004h,005h,006h
                DB  007h,008h,009h,00Ah,00Bh,000h
;@ SelfTestValues type=u8 count=109 formula=raw category="Internal" desc="Self-test reference values (not a tuning value)."
SelfTestValues: DB  000h,000h
                DB  077h,022h,0EEh,044h,077h,044h,0DDh,088h
                DB  0FFh,0FFh,0EEh,088h,077h,088h,0BBh,011h
                DB  0BBh,022h,0FFh,0FFh,0BBh,044h,0DDh,011h
                DB  0DDh,022h,0EEh,011h,000h,000h,0FFh,0FFh
                DB  046h,000h,077h,00Ah,046h,000h,053h,007h
                DB  056h,000h,0A2h,005h,06Ah,000h,00Dh,005h
                DB  07Ch,000h,094h,004h,08Bh,000h,000h,000h
                DB  08Bh,000h,0FFh,0FFh,050h,000h,077h,00Ah
                DB  050h,000h,053h,007h,063h,000h,0A2h,005h
                DB  076h,000h,00Dh,005h,085h,000h,094h,004h
                DB  092h,000h,000h,000h,092h,000h,0FFh,000h
                DB  000h,0A1h,000h,000h,087h,054h,000h,06Eh
                DB  067h,000h,044h,0ABh,000h,028h,050h,001h
                DB  000h,050h,001h
timer_state_reinit_load_r6:
                LB A, r6
                MB C, PSWL.4
                JLT timer_state_reinit_goto_next
                MOV DP, #003B8h
                J corr_map_lookup_load_ind_3
timer_state_reinit_goto_next:
                J deadtime_retry_goto_next
vcal3_leanprotect_ratelimit_if_ramed_b3_set:
                JBS off(0EDh).3, vcal3_leanprotect_ratelimit_goto_next
                JBS off(0EEh).4, vcal3_leanprotect_ratelimit_goto_next
                J sensor_fault_check_load_ram12_2
vcal3_leanprotect_ratelimit_goto_next:
                J sensor_fault_check_flag_ramec_b2
timer_state_reinit_load_ramb3:
                LB A, off(0B3h)
                JNE diag_mode_code_goto_next
                J ofc_enable_check
diag_mode_code_goto_next:
                J ofc_enable_check_if_ram2e_b0_set
timer_state_reinit_set_ramd6:
                MOVB off(0D6h), #014h
                MOVB 51[USP], #032h
                MOVB off(0C7h), #064h
                J ign_advance_corr_sc
state_if_ram1a_b0_clr:
                JBR off(01Ah).0, state_goto_next
                JBS off(02Bh).4, state_goto_next
                MB C, 0B0h.1
                JLT state_goto_next
                JBS off(012h).5, state_goto_next
                J idle_step_flag_load_ramd9
state_goto_next:
                J ign_advance_corr_rc
ve_result_flag_branch:
                JGE state_goto_next
                JBS off(01Ah).2, state_goto_next
                JBR off(016h).3, timer_state_reinit_load_ind
                JBR off(011h).5, state_goto_next
timer_state_reinit_load_ind:
                L A, [DP]
                J ign_advance_corr_add_acc
timer_state_reinit_set_er0:
                MOV er0, off(062h)
                MOVB ACCH, #026h
                MOVB r5, #0FFh
                CMPB off(0C7h), #000h
                JNE ve_result_flag_goto_idle_gear_mul_apply
                J ign_advance_corr_set_acch
ve_result_flag_goto_idle_gear_mul_apply:
                J idle_gear_mul_apply
timer_state_reinit_load_r0:
                LB A, r0
                CMPB A, off(069h)
                J corr_map_lookup_branch
timer_state_reinit_if_ram1e_b3_set:
                JBS off(01Eh).3, timer_state_reinit_goto_next_2
                INC X1
                INC X1
timer_state_reinit_goto_next_2:
                J corr_map_lookup_load_ind
;@ InjectorCorrectionLimits type=u8 count=8 formula=raw category="Fuel" desc="Fuel correction limits, closed loop (first four) and open loop (last four)."
InjectorCorrectionLimits:DB  0E6h,03Fh,0E6h,03Fh,0E6h,03Fh,0E6h,03Fh
timer_state_reinit_set_x1:
                MOV X1, #0631Dh
                JBS off(027h).1, timer_state_reinit_goto_next_3
                MOV X1, #058C8h
timer_state_reinit_goto_next_3:
                J fuel_map_lookup_b_load_ram33
timer_state_reinit_set_x1_2:
                MOV X1, #06311h
                JBS off(027h).1, timer_state_reinit_goto_next_4
                MOV X1, #058BCh
timer_state_reinit_goto_next_4:
                J fuel_map_lookup_b_load_ram33_2
                DB  0FFh,030h,0E0h,021h,0D0h,01Eh,0C0h,023h
                DB  0B0h,028h,000h,028h,0FFh,027h,0E0h,018h
                DB  0D0h,015h,0C0h,017h,0B0h,022h,000h,022h
                DB  0FFh,0CCh,0F5h,0CCh,0E6h,0AEh,0CFh,0AAh
                DB  0A1h,0A9h,06Eh,0A4h,02Eh,09Ah,028h,080h
                DB  000h,080h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
timer_state_reinit_sll_acc_2:
                SLL A
                ROL er1
                SLL A
                L A, er1
                ROL A
                J corr_map_lookup_add_acc
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
timer_state_reinit_flag_ram2c_b0:
                MB off(02Ch).0, C
                LB A, #0C2h
                JBS off(0F8h).3, overrev_hardcap_compare_cmp_acc_ram33
                LB A, #0C6h
overrev_hardcap_compare_cmp_acc_ram33:
                CMPB A, off(033h)
                MB off(0F8h).3, C
                J fuel_map_lookup_b_if_ram25_b4_set
timer_state_reinit_if_ram30_b5_set:
                JBS off(030h).5, timer_state_reinit_goto_next_5
                JBS off(0F8h).3, timer_state_reinit_goto_next_6
timer_state_reinit_goto_next_5:
                J fuel_map_lookup_b_set_ram2c_b3
timer_state_reinit_goto_next_6:
                J fuel_map_lookup_b_clear_ram2c_b3
timer_state_reinit_set_x1_3:
                MOV X1, #0631Dh
                JBS off(027h).1, timer_state_reinit_goto_next_7
                MOV X1, #058C8h
timer_state_reinit_goto_next_7:
                J corr_map_lookup_if_ram2b_b5_clr
timer_state_reinit_set_x1_4:
                MOV X1, #06311h
                JBS off(027h).1, timer_state_reinit_goto_ignmap2_rpm_gate
                MOV X1, #058BCh
timer_state_reinit_goto_ignmap2_rpm_gate:
                J ignmap2_rpm_gate
timer_state_reinit_set_x1_5:
                MOV X1, #0631Dh
                JBS off(01Fh).1, timer_state_reinit_goto_next_8
                MOV X1, #058C8h
timer_state_reinit_goto_next_8:
                J housekeeping_call_load_ram36
timer_state_reinit_load_imm:
                LB A, #000h
                JBS off(0F8h).4, timer_state_reinit_cmp_ramd8_acc
                LB A, #000h
timer_state_reinit_cmp_ramd8_acc:
                CMPB 0D8h, A
                MB off(0F8h).4, C
                LB A, off(033h)
                MOV X1, #05612h
                JGE timer_state_reinit_goto_next_9
                MOV X1, #0640Dh
timer_state_reinit_goto_next_9:
                J fuel_map_lookup_b_cmp_acc_ind
timer_state_reinit_flag_ram26_b3:
                MB off(026h).3, C
                LB A, #0F0h
                JBS off(026h).6, timer_state_reinit_cmp_acc_ram36
                LB A, #0FAh
timer_state_reinit_cmp_acc_ram36:
                CMPB A, off(036h)
                MB off(026h).6, C
                J sensor_fault_check_load_imm_2
timer_state_reinit_if_ram26_b6_set:
                JBS off(026h).6, timer_state_reinit_goto_next_10
                NOP
                NOP
                NOP
                J sensor_fault_check_cmp_ramd9_imm
timer_state_reinit_goto_next_10:
                J accut_reset_clear_ramf7
                DB  003h,0FCh,042h,0FFh,030h,0E5h,030h,0E0h
                DB  080h,0DDh,0BDh,0A0h,0E6h,060h,0E6h,040h
                DB  0D0h,000h,0D0h,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh
timer_state_reinit_load_imm_2:
                LB A, #0C2h
                MOVB r0, #0C2h
                JBS off(031h).1, timer_state_reinit_set_dp_2
                LB A, #0C6h
                MOVB r0, #0C6h
timer_state_reinit_set_dp_2:
                MOV DP, #059A0h
                J ign_cold_path_nop_2
timer_state_reinit_if_ram31_b2_set:
                JBS off(031h).2, tps_hysteresis_flag2_goto_next
                JBS off(025h).5, tps_hysteresis_flag2_goto_next
                J ign_cold_path_load_ramba
tps_hysteresis_flag2_goto_next:
                J vtec_engage_conditions_start_set_ramba
timer_state_reinit_load_ramd5:
                LB A, off(0D5h)
                JNE timer_state_reinit_if_ramed_b4_set
idle_mode_gate6_goto_next:
                J sensor_fault_check_cmp_ind_imm
timer_state_reinit_if_ramed_b4_set:
                JBS off(0EDh).4, idle_mode_gate6_goto_next
                J purge_result_rc
timer_state_reinit_set_r1:
                MOVB r1, r2
                CMPB A, r1
                JGE knockwindow_gate_start_goto_idle_ectvs_result3
                J ign_advance_scale_load_imm_2
knockwindow_gate_start_goto_idle_ectvs_result3:
                J idle_ectvs_result3
timer_state_reinit_add_er3:
                ADD er3, A
                MB C, PSWL.4
                JLT timer_state_reinit_goto_next_11
                CLR A
                J ign_cold_path_load_ram44_2
timer_state_reinit_goto_next_11:
                J ign_cold_path_clear_acc_2
; Ignition dispatch (engine interrupt tail): 01Dh.4 set -> ign_dispatch_warm (J ign_advance lookup at
; 0x0BBF); 012h.2 -> 0x64A7 (018h.0 -> 0x05Ah cold constant, J ign_cold_path 0x0BCF); 012h.4 -> J
; ign_warm_path 0x0B85.
ign_dispatch:
                JBS off(01Dh).4, ign_dispatch_warm
                JBS off(012h).2, ign_dispatch_if_ram18_b0_set
                JBR off(012h).4, ign_dispatch_goto_ign_warm_path
ign_dispatch_if_ram18_b0_set:
                JBS off(018h).0, ign_dispatch_load_imm
ign_dispatch_goto_ign_warm_path:
                J ign_warm_path
ign_dispatch_load_imm:
                LB A, #05Ah
                J ign_cold_path
; Ignition dispatch, warm: J ign_advance lookup (0x0BBF) with the 0x034h (52) / 0x02Dh (45) / 0x016h.3
; state, then ign_advance_scale (0x2D53) / ign_advance_corr (0x2DC7) with the 0x08D3/0x0360 scale.
ign_dispatch_warm:
                J ignmap_alt_path
ign_dispatch_warm_set_r1:
                MOVB r1, #034h
                JBS off(016h).3, ign_dispatch_warm_set_r2
                MOVB r1, #034h
ign_dispatch_warm_set_r2:
                MOVB r2, #02Dh
                J ign_advance_scale
ign_dispatch_warm_if_ram16_b3_set:
                JBS off(016h).3, ign_dispatch_warm_goto_ign_advance_corr
                L A, #008D3h
                MOV er3, #00360h
ign_dispatch_warm_goto_ign_advance_corr:
                J ign_advance_corr
                DB  0F4h,0D8h,0CEh,003h,003h,0A7h,02Dh,022h
                DB  049h,003h,080h,02Dh
ign_dispatch_warm_set_er2:
                MOV er2, #IgnitionLow2
                MOV X1, #IgnitionLow
                J ign_warm_path_if_ram14_b5_clr
ign_dispatch_warm_set_er2_2:
                MOV er2, #IgnitionHigh2
                MOV X1, #IgnitionHigh
                J ign_warm_path_goto_next
tipin_decay_check_if_ramee_b3_set:
                JBS off(0EEh).3, ign_dispatch_warm_clear_pswl_b5
                JBR off(016h).4, ign_dispatch_warm_clear_pswl_b5
                JBS off(016h).2, ign_dispatch_warm_clear_pswl_b5
                MOV X1, er2
ign_dispatch_warm_clear_pswl_b5:
                RB PSWL.5
                CAL table2d_lookup_interp
                J ign_warm_path_set_r0
ign_dispatch_warm_flag_ram2f_b5:
                MB off(02Fh).5, C
                LB A, #0FFh
                JBS off(030h).1, to_injtimer_sub_common_cmp_acc_ram33_2
                LB A, #0FFh
to_injtimer_sub_common_cmp_acc_ram33_2:
                CMPB A, off(033h)
                MB off(030h).1, C
                LB A, #0FFh
                JBS off(030h).2, to_injtimer_sub_common_cmp_acc_ram32
                LB A, #0FFh
to_injtimer_sub_common_cmp_acc_ram32:
                CMPB A, off(032h)
                MB off(030h).2, C
                J fuel_map_lookup_b_load_imm_2
ign_dispatch_warm_set_ramc5:
                MOVB off(0C5h), #0FFh
                RB off(025h).5
                J corr_map_lookup_clear_ram2f_b4
ign_dispatch_warm_if_ram30_b1_clr:
                JBR off(030h).1, ign_dispatch_warm_set_ramc5_2
                JBS off(030h).2, ign_dispatch_warm_cmp_ramc5_imm
ign_dispatch_warm_set_ramc5_2:
                MOVB off(0C5h), #0FFh
ign_dispatch_warm_cmp_ramc5_imm:
                CMPB off(0C5h), #000h
                JEQ ign_dispatch_warm_goto_next
                CMPB off(0B0h), #000h
                J corr_map_lookup_branch_2
ign_dispatch_warm_goto_next:
                J corr_map_lookup_if_ram2c_b4_set
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
ign_dispatch_warm_load_ram7a:
                L A, off(07Ah)
                JEQ ign_dispatch_warm_load_ramd8
                MOVB off(0D8h), #01Eh
ign_dispatch_warm_load_ramd8:
                LB A, off(0D8h)
                JNE to_injtimer_sub_common_goto_next
                JBS off(025h).1, to_injtimer_sub_common_goto_next
                J idle_ectvs_result3
to_injtimer_sub_common_goto_next:
                J ign_advance_scale_load_imm_2
ign_dispatch_warm_cmp_ram4a_imm:
                CMP off(04Ah), #00000h
                JNE ign_dispatch_warm_goto_injtimer_bank_b_zero
                JBR off(02Eh).4, ign_dispatch_warm_goto_next_2
                J corr_map_lookup_if_ram2c_b3_clr
ign_dispatch_warm_goto_injtimer_bank_b_zero:
                J injtimer_bank_b_zero
ign_dispatch_warm_goto_next_2:
                J corr_map_lookup_nop
ign_dispatch_warm_set_ramf8_b5:
                SB off(0F8h).5
                CLRB off(0C6h)
                J corr_map_lookup_set_ramc8
ign_dispatch_warm_set_ramf8_b5_2:
                SB off(0F8h).5
                CLRB off(0C6h)
                J corr_map_lookup_set_ramc8_2
ign_dispatch_warm_branch:
                JGE ign_dispatch_warm_clear_acc
                RB off(0F8h).5
                SJ ign_dispatch_warm_goto_o2_trim_bank_index_calc
ign_dispatch_warm_clear_acc:
                CLRB A
ign_dispatch_warm_store_ramc6:
                STB A, off(0C6h)
                SB off(0F8h).5
ign_dispatch_warm_goto_o2_trim_bank_index_calc:
                J o2_trim_bank_index_calc
ign_dispatch_warm_load_imm:
                LB A, #03Ch
                SJ ign_dispatch_warm_store_ramc6
to_injtimer_sub_common_load_ramc6:
                LB A, off(0C6h)
                JNE ign_dispatch_warm_goto_o2_trim_bank_index_calc
                J o2_trim_rate_table_select
ign_dispatch_warm_if_ram22_b6_set:
                JBS off(022h).6, cylinder_ign_correct_apply_cmp_acc_ram35
                LB A, #0D0h
cylinder_ign_correct_apply_cmp_acc_ram35:
                CMPB A, off(035h)
                MB off(022h).6, C
                LB A, #082h
                JBS off(020h).7, ign_dispatch_warm_goto_next_3
                LB A, #08Ah
ign_dispatch_warm_goto_next_3:
                J threshold_bank_cmp_acc_ram35_2
battery_voltage_check_flag_ram20_b7:
                MB off(020h).7, C
                JBS off(018h).0, dcode_gate_common_goto_next
                J housekeeping_call_branch
dcode_gate_common_goto_next:
                J div_scale_store_ram43
ign_dispatch_warm_set_dp:
                MOV DP, #003D9h
                JBS off(022h).6, threshold_bank_goto_next
                MOV DP, #003D6h
threshold_bank_goto_next:
                J housekeeping_call_load_ind_3
flag_dispatch_if_ram18_b7_set:
                JBS off(018h).7, ign_dispatch_warm_goto_next_4
                JBS off(026h).2, flag_dispatch_goto_next
                J sensor_fault_check_clear_acc
flag_dispatch_goto_next:
                J accut_check_load_ramc3
ign_dispatch_warm_goto_next_4:
                J sensor_fault_check_if_ram26_b5_set
ign_dispatch_warm_set_x1:
                MOV X1, #05DFDh
                JBR off(026h).4, ign_dispatch_warm_goto_next_5
                MOV X1, #065FDh
ign_dispatch_warm_goto_next_5:
                J ign_advance_corr_load_ramc2
                DB  0FFh,0FFh,03Fh,079h,0FFh,03Fh,055h,000h
                DB  034h,040h,000h,02Eh,039h,000h,020h,032h
                DB  000h,018h,02Bh,000h,014h,000h,000h,014h
ign_dispatch_warm_load_imm_2:
                LB A, #032h
                JBS off(01Eh).3, o2_trim_result_check_goto_next
                LB A, #032h
o2_trim_result_check_goto_next:
                J ign_dispatch_warm_store_ramcc
ign_dispatch_warm_clear_ram2b_b7:
                RB off(02Bh).7
                JBR off(01Ch).5, ign_dispatch_warm_goto_next_6
                LB A, #0E5h
                JBS off(024h).5, ign_dispatch_warm_cmp_acc_ram33
                LB A, #0E8h
ign_dispatch_warm_cmp_acc_ram33:
                CMPB A, off(033h)
                JLT o2_trim_rpm_alt_check_goto_next
ign_dispatch_warm_goto_next_6:
                J corr_map_lookup_if_ram1b_b5_set
o2_trim_rpm_alt_check_goto_next:
                J revlimiter_fuelcut_set_pswl_b5
ign_dispatch_warm_cmp_ram33_imm:
                CMPB off(033h), #0F0h
                JGE idle_state_defaults_goto_next
                SUBB A, #018h
                CMPB off(033h), #0C5h
                J fuel_map_lookup_b_branch
idle_state_defaults_goto_next:
                J accelenrich_result_store_ram88
;@ TipInEnrichRpm type=u8 count=54 formula=raw category="Tip-in" desc="Tip-in fuel: rpm rows (VCAL 3 triples, indexed by the throttle step)."
TipInEnrichRpm: DB  0FFh,0E8h,003h,030h,0E8h,003h,000h,07Dh
                DB  000h,000h,07Dh,000h,0FFh,0EEh,002h,040h
                DB  0EEh,002h,010h,0FAh,000h,000h,032h,000h
                DB  0FFh,033h,004h,040h,033h,004h,000h,032h
                DB  000h,000h,032h,000h,0FFh,0E8h,003h,040h
                DB  0E8h,003h,010h,0C8h,000h,000h,032h,000h
                DB  0FFh,0B0h,004h,040h,0B0h,004h,000h,04Bh
                DB  000h,000h,04Bh,000h,0FFh,0E8h,003h,040h
                DB  0E8h,003h,010h,05Eh,001h,000h,032h,000h
                DB  0FFh,0B0h,004h,040h,0B0h,004h,000h,0C8h
                DB  000h,000h,0C8h,000h,0FFh,0E8h,003h,030h
                DB  0E8h,003h,000h,07Dh,000h,000h,07Dh,000h
                DB  0FFh,0E8h,003h,030h,0E8h,003h,000h,07Dh
                DB  000h,000h,07Dh,000h,0FFh,0E8h,003h,030h
                DB  0E8h,003h,000h,07Dh,000h,000h,07Dh,000h
                DB  0FFh,0E8h,003h,030h,0E8h,003h,000h,07Dh
                DB  000h,000h,07Dh,000h
;@ TipInEnrich type=u16 count=27 formula=raw category="Tip-in" desc="Tip-in fuel amounts."
TipInEnrich:    DB  090h,001h,00Ah,001h
                DB  040h,000h,019h,000h,008h,000h,000h,000h
                DB  0C2h,001h,02Ch,001h,040h,000h,019h,000h
                DB  00Ah,000h,000h,000h,0C2h,001h,02Ch,001h
                DB  040h,000h,019h,000h,008h,000h,000h,000h
                DB  0C2h,001h,02Ch,001h,040h,000h,019h,000h
                DB  00Ah,000h,000h,000h,0C2h,001h,02Ch,001h
                DB  040h,000h,019h,000h,008h,000h,000h,000h
                DB  0C2h,001h,02Ch,001h,040h,000h,019h,000h
                DB  00Ch,000h,000h,000h,0C2h,001h,02Ch,001h
                DB  040h,000h,019h,000h,00Ch,000h,000h,000h
                DB  0C2h,001h,0FAh,000h,040h,000h,019h,000h
                DB  00Ch,000h,000h,000h,0C2h,001h,0FAh,000h
                DB  040h,000h,019h,000h,00Ch,000h,000h,000h
                DB  0C2h,001h,0FAh,000h,080h,000h,032h,000h
                DB  018h,000h,000h,000h,0C2h,001h,0FAh,000h
                DB  080h,000h,032h,000h,018h,000h,000h,000h
ign_dispatch_warm_store_ramcc:
                STB A, off(0CCh)
                J fuelcut_clear_ram24_b2
ign_dispatch_warm_cmp_acc_ram42:
                CMP A, off(042h)
                JGE ign_dispatch_warm_cmp_r3_imm
                L A, off(042h)
ign_dispatch_warm_cmp_r3_imm:
                CMPB r3, #000h
                J fuel_map_lookup_b_branch_2
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
;@ IgnitionLow2 type=u8 size=20x10 stride=10 formula=ign_advance rows.axis=RpmScalerLow rows.formula=rpm_axis_byte_log cols.axis=MapScaler cols.formula="x * 3.6105 + 114.3" cols.inverse="(x - 114.3) / 3.6105" cols.unit=mbar cols.decimals=0 category="Ignition" desc="Second low-cam ignition map: used in place of IgnitionLow on the conditions tested before the lookup (RAM 0EEh.3, 016h.4, 016h.2)."
IgnitionLow2:   DB  05Ah,05Ah,05Ah,05Ah,03Dh
                DB  019h,008h,002h,000h,000h,05Ah,05Ah,05Ah
                DB  05Ah,03Eh,01Dh,00Dh,006h,002h,000h,05Ah
                DB  05Ah,05Ah,05Ah,041h,021h,012h,00Bh,005h
                DB  000h,05Ah,05Ah,05Ah,05Ah,04Ah,031h,021h
                DB  019h,010h,009h,068h,068h,068h,068h,05Bh
                DB  046h,035h,02Bh,020h,018h,077h,077h,077h
                DB  077h,06Ah,053h,03Eh,035h,02Ah,022h,086h
                DB  086h,086h,086h,077h,05Eh,049h,040h,035h
                DB  02Dh,098h,098h,098h,094h,082h,069h,055h
                DB  04Bh,040h,038h,0A5h,0A5h,0A5h,099h,086h
                DB  06Fh,060h,056h,049h,041h,0AAh,0AAh,0AAh
                DB  097h,083h,073h,06Ch,062h,055h,049h,0AAh
                DB  0AAh,0AAh,093h,080h,077h,073h,06Bh,060h
                DB  058h,0AAh,0AAh,0AAh,092h,080h,07Bh,078h
                DB  072h,06Ah,062h,0AAh,0AAh,0AAh,096h,086h
                DB  082h,07Bh,079h,072h,06Ah,0AAh,0AAh,0AAh
                DB  098h,085h,07Eh,07Bh,075h,06Fh,06Ah,0AFh
                DB  0AFh,0AFh,0A9h,099h,08Eh,086h,07Ch,073h
                DB  06Ah,0B3h,0B3h,0B3h,0B3h,0A1h,094h,08Bh
                DB  081h,077h,06Fh,0B3h,0B3h,0B3h,0B3h,0A2h
                DB  097h,08Eh,083h,077h,06Fh,0B3h,0B3h,0B3h
                DB  0B3h,0A2h,097h,08Eh,083h,077h,06Fh,0B3h
                DB  0B3h,0B3h,0B3h,0A2h,097h,08Eh,083h,077h
                DB  06Fh,0B3h,0B3h,0B3h,0B3h,0A2h,097h,08Eh
                DB  083h,077h,06Fh
;@ IgnitionHigh2 type=u8 size=15x10 stride=10 formula=ign_advance rows.axis=RpmScalerHigh rows.formula="x * 1875000 / 53125" rows.inverse="x * 53125 / 1875000" rows.unit=rpm rows.decimals=0 cols.axis=MapScaler cols.formula="x * 3.6105 + 114.3" cols.inverse="(x - 114.3) / 3.6105" cols.unit=mbar cols.decimals=0 category="Ignition" desc="Second high-cam ignition map, as IgnitionLow2."
IgnitionHigh2:  DB  0ACh,0ACh,0ACh,0ACh,09Eh
                DB  091h,08Bh,083h,07Eh,07Ah,0ACh,0ACh,0ACh
                DB  0ACh,09Eh,091h,08Bh,083h,07Eh,07Ah,0ACh
                DB  0ACh,0ACh,0ACh,09Eh,091h,08Bh,083h,07Eh
                DB  07Ah,0B0h,0B0h,0B0h,0B0h,0A2h,093h,08Ch
                DB  083h,07Eh,07Ah,0B4h,0B4h,0B4h,0B4h,0A6h
                DB  091h,085h,07Bh,076h,072h,0B4h,0B4h,0B4h
                DB  0B4h,0A6h,091h,085h,07Bh,074h,06Fh,0B4h
                DB  0B4h,0B4h,0B4h,0A6h,091h,085h,07Bh,072h
                DB  06Dh,0B4h,0B4h,0B4h,0B4h,0A6h,095h,08Bh
                DB  084h,07Dh,078h,0B4h,0B4h,0B4h,0B4h,0A6h
                DB  09Dh,097h,091h,08Bh,086h,0B4h,0B4h,0B4h
                DB  0B4h,0A6h,09Dh,099h,095h,08Fh,08Ah,0B4h
                DB  0B4h,0B4h,0B4h,0A6h,09Dh,099h,095h,08Fh
                DB  08Ah,0B4h,0B4h,0B4h,0B4h,0A6h,09Dh,099h
                DB  095h,08Fh,08Ah,0B4h,0B4h,0B4h,0B4h,0A6h
                DB  09Dh,099h,095h,08Fh,08Ah,0B4h,0B4h,0B4h
                DB  0B4h,0A6h,09Dh,099h,095h,08Fh,08Ah,0B4h
                DB  0B4h,0B4h,0B4h,0A6h,09Dh,099h,095h,08Fh
                DB  08Ah
;@ MapScalerFuel type=u8 count=10 formula="x * 3.6105 + 114.3" inverse="(x - 114.3) / 3.6105" unit=mbar decimals=0 category="Axes" desc="Load axis of the fuel maps (the MAP byte, 00h-terminated)."
MapScalerFuel:  DB  000h,018h,030h,050h,080h,0B0h,0D0h
                DB  0E0h,0F0h,000h
;@ MapScaler type=u8 count=10 formula="x * 3.6105 + 114.3" inverse="(x - 114.3) / 3.6105" unit=mbar decimals=0 category="Axes" desc="Load axis of the ignition maps (the MAP byte, 00h-terminated)."
MapScaler:      DB  000h,018h,030h,050h,080h
                DB  0B0h,0D0h,0E0h,0F0h,000h
;@ MapScalerVE type=u8 count=10 formula="x * 3.6105 + 114.3" inverse="(x - 114.3) / 3.6105" unit=mbar decimals=0 category="Axes" desc="Load axis of the VE map."
MapScalerVE:    DB  000h,018h,030h
                DB  050h,080h,0B0h,0D0h,0E0h,0F0h,000h
;@ RpmScalerLow type=u8 count=20 formula=rpm_axis_byte_log category="Axes" desc="Rpm axis of the low-cam maps."
RpmScalerLow:   DB  000h
                DB  013h,020h,040h,050h,060h,070h,080h,088h
                DB  090h,098h,0A0h,0B0h,0C0h,0C8h,0D0h,0D8h
                DB  0E0h,0F0h,000h
;@ RpmScalerHigh type=u8 count=15 formula="x * 1875000 / 53125" inverse="x * 53125 / 1875000" unit=rpm decimals=0 category="Axes" desc="Rpm axis of the high-cam maps."
RpmScalerHigh:  DB  000h,064h,072h,080h,08Eh
                DB  095h,09Ch,0A4h,0ABh,0B9h,0C7h,0D5h,0E4h
                DB  0F2h,000h
;@ RpmScalerVE type=u8 count=15 formula="x * 1875000 / 53125" inverse="x * 53125 / 1875000" unit=rpm decimals=0 category="Axes" desc="Rpm axis of the VE map."
RpmScalerVE:    DB  000h,01Ch,039h,055h,072h,080h
                DB  08Eh,09Ch,0ABh,0B9h,0C7h,0D5h,0E4h,0F2h
                DB  000h
;@ FuelLow type=u8 size=20x10 stride=10 colscale=FuelLow+200 formula=honda_fuel rows.axis=RpmScalerLow rows.formula=rpm_axis_byte_log cols.axis=MapScalerFuel cols.formula="x * 3.6105 + 114.3" cols.inverse="(x - 114.3) / 3.6105" cols.unit=mbar cols.decimals=0 category="Fuel" desc="Low-cam fuel map; its column multipliers follow the last row."
FuelLow:        DB  046h,074h,085h,09Bh,09Eh,0B7h,0BEh
                DB  0B8h,0B5h,0C2h,059h,080h,08Dh,0A3h,0A3h
                DB  0BCh,0C2h,0BCh,0B8h,0C5h,064h,087h,094h
                DB  0A6h,0A6h,0BFh,0C5h,0BCh,0B9h,0C7h,077h
                DB  090h,098h,0AAh,0ABh,0C4h,0C8h,0C0h,0BAh
                DB  0C8h,078h,092h,09Ch,0AEh,0AEh,0C7h,0CDh
                DB  0C5h,0BFh,0CCh,07Bh,096h,0A1h,0B4h,0B3h
                DB  0CCh,0D1h,0CBh,0C4h,0D2h,07Fh,093h,09Eh
                DB  0B1h,0B2h,0CCh,0D3h,0CEh,0C8h,0D6h,072h
                DB  09Ch,0A3h,0B4h,0B4h,0CEh,0D4h,0CEh,0CAh
                DB  0D9h,07Ah,09Fh,0A7h,0B8h,0B7h,0D1h,0D6h
                DB  0D1h,0CBh,0DBh,07Ch,097h,0A5h,0BAh,0BBh
                DB  0D4h,0D8h,0D3h,0CEh,0DEh,078h,090h,0A3h
                DB  0BAh,0BEh,0D7h,0DAh,0D5h,0D0h,0E0h,082h
                DB  096h,0A3h,0BBh,0BEh,0D9h,0DDh,0D8h,0D4h
                DB  0E1h,09Bh,0A8h,0B1h,0C4h,0C4h,0DFh,0E5h
                DB  0E0h,0D8h,0E4h,0B9h,0B6h,0C1h,0D4h,0D3h
                DB  0EEh,0F2h,0E9h,0DDh,0E8h,0C1h,0BDh,0C4h
                DB  0D8h,0D5h,0F4h,0F8h,0EBh,0E0h,0EDh,0D3h
                DB  0BFh,0CAh,0E2h,0DCh,0FBh,0FFh,0F0h,0E5h
                DB  0F2h,09Eh,0AFh,0BAh,0D6h,0D5h,0F2h,0F7h
                DB  0EAh,0DEh,0E9h,0C2h,0BCh,0C8h,0E2h,0E2h
                DB  0FDh,0FEh,0F0h,0E7h,0F0h,092h,0A5h,0B3h
                DB  0D3h,0CFh,0E6h,0EAh,0DEh,0D3h,0DDh,035h
                DB  053h,07Ch,0A5h,0B2h,0C5h,0CBh,0C0h,0B8h
                DB  0C7h
;@ FuelLowMultipliers type=u8 count=10 formula=raw category="Fuel" desc="Column multipliers of the low-cam fuel map."
FuelLowMultipliers:DB  001h,002h,003h,004h,006h,007h,008h
                DB  009h,00Ah,00Ah
;@ FuelHigh type=u8 size=15x10 stride=10 colscale=FuelHigh+150 formula=honda_fuel rows.axis=RpmScalerHigh rows.formula="x * 1875000 / 53125" rows.inverse="x * 53125 / 1875000" rows.unit=rpm rows.decimals=0 cols.axis=MapScalerFuel cols.formula="x * 3.6105 + 114.3" cols.inverse="(x - 114.3) / 3.6105" cols.unit=mbar cols.decimals=0 category="Fuel" desc="High-cam fuel map; its column multipliers follow the last row."
FuelHigh:       DB  03Ah,07Ch,083h,083h,097h
                DB  0BAh,0BAh,0C9h,0C3h,0CFh,03Ah,07Ch,083h
                DB  083h,097h,0BAh,0BAh,0C9h,0C3h,0CFh,03Ah
                DB  07Ch,083h,083h,097h,0BAh,0BAh,0C9h,0C3h
                DB  0CFh,04Ah,093h,09Eh,099h,0A7h,0CBh,0C5h
                DB  0D3h,0CCh,0D6h,05Fh,0AEh,0BBh,0AFh,0BAh
                DB  0DFh,0D2h,0E1h,0D8h,0E2h,05Fh,0AFh,0BAh
                DB  0AFh,0BAh,0DFh,0D3h,0E3h,0D9h,0E5h,060h
                DB  0B1h,0B8h,0ACh,0B8h,0DFh,0D3h,0E3h,0DCh
                DB  0E8h,061h,0B5h,0BAh,0AEh,0BEh,0E5h,0D6h
                DB  0E5h,0DDh,0EAh,066h,0BFh,0BFh,0B2h,0C3h
                DB  0E9h,0D8h,0E7h,0DEh,0EBh,07Dh,0D5h,0CBh
                DB  0BDh,0CFh,0EFh,0DEh,0ECh,0E2h,0EDh,07Ah
                DB  0D9h,0D5h,0CAh,0DAh,0FCh,0E8h,0F4h,0E9h
                DB  0F4h,082h,0DDh,0D9h,0D3h,0DFh,0FFh,0E9h
                DB  0F9h,0EEh,0F9h,067h,0C5h,0CCh,0CCh,0DBh
                DB  0F9h,0E5h,0F7h,0EBh,0F6h,067h,0C5h,0CCh
                DB  0CCh,0DBh,0F9h,0E5h,0F7h,0EBh,0F6h,067h
                DB  0C5h,0CCh,0CCh,0DBh,0F9h,0E5h,0F7h,0EBh
                DB  0F6h
;@ FuelHighMultipliers type=u8 count=10 formula=raw category="Fuel" desc="Column multipliers of the high-cam fuel map."
FuelHighMultipliers:DB  002h,002h,003h,005h,007h,008h,00Ah
                DB  00Ah,00Bh,00Bh
;@ IgnitionLow type=u8 size=20x10 stride=10 formula=ign_advance rows.axis=RpmScalerLow rows.formula=rpm_axis_byte_log cols.axis=MapScaler cols.formula="x * 3.6105 + 114.3" cols.inverse="(x - 114.3) / 3.6105" cols.unit=mbar cols.decimals=0 category="Ignition" desc="Low-cam ignition map."
IgnitionLow:    DB  05Ah,05Ah,05Ah,05Ah,04Bh
                DB  033h,021h,013h,008h,000h,05Ah,05Ah,05Ah
                DB  05Ah,04Ch,036h,025h,017h,00Dh,002h,05Ah
                DB  05Ah,05Ah,05Ah,04Dh,03Ah,02Ah,01Ch,013h
                DB  007h,05Ah,05Ah,05Ah,05Ah,054h,046h,036h
                DB  02Bh,022h,015h,068h,068h,068h,068h,05Eh
                DB  053h,042h,039h,031h,027h,07Bh,07Bh,07Bh
                DB  07Bh,06Ah,060h,04Fh,048h,040h,037h,08Ah
                DB  08Ah,08Ah,08Ah,076h,067h,055h,04Eh,046h
                DB  03Eh,098h,098h,098h,098h,082h,06Eh,05Bh
                DB  055h,04Dh,044h,0A0h,0A0h,0A0h,09Ch,086h
                DB  075h,064h,05Eh,057h,04Dh,0A8h,0A8h,0A8h
                DB  0A0h,08Bh,07Ch,06Dh,067h,05Fh,056h,0ACh
                DB  0ACh,0ACh,09Dh,087h,07Ch,071h,06Bh,064h
                DB  05Ch,0AFh,0AFh,0AFh,09Bh,083h,07Ch,073h
                DB  06Eh,068h,062h,0AFh,0AFh,0AFh,09Bh,087h
                DB  07Dh,077h,073h,06Fh,06Bh,0AFh,0AFh,0AFh
                DB  09Ch,08Dh,085h,07Ch,076h,071h,06Bh,0AFh
                DB  0AFh,0AFh,0A3h,099h,08Ch,082h,07Ch,073h
                DB  06Bh,0AFh,0AFh,0AFh,0ABh,0A0h,090h,082h
                DB  07Ch,076h,06Fh,0AFh,0AFh,0AFh,0AFh,0A4h
                DB  099h,08Ch,088h,084h,080h,0AFh,0AFh,0AFh
                DB  0AFh,0A4h,099h,08Ch,088h,084h,080h,0AFh
                DB  0AFh,0AFh,0AFh,0A4h,099h,08Ch,088h,084h
                DB  080h,0AFh,0AFh,0AFh,0AFh,0A4h,099h,08Ch
                DB  088h,084h,080h
;@ IgnitionHigh type=u8 size=15x10 stride=10 formula=ign_advance rows.axis=RpmScalerHigh rows.formula="x * 1875000 / 53125" rows.inverse="x * 53125 / 1875000" rows.unit=rpm rows.decimals=0 cols.axis=MapScaler cols.formula="x * 3.6105 + 114.3" cols.inverse="(x - 114.3) / 3.6105" cols.unit=mbar cols.decimals=0 category="Ignition" desc="High-cam ignition map."
IgnitionHigh:   DB  0ABh,0ABh,0ABh,0ABh,09Eh
                DB  091h,084h,081h,07Dh,07Ah,0ABh,0ABh,0ABh
                DB  0ABh,09Eh,091h,084h,081h,07Dh,07Ah,0ABh
                DB  0ABh,0ABh,0ABh,09Eh,091h,084h,081h,07Dh
                DB  07Ah,0ABh,0ABh,0ABh,0ABh,09Eh,091h,084h
                DB  081h,07Dh,07Ah,0ABh,0ABh,0ABh,0ABh,09Eh
                DB  08Dh,084h,07Fh,079h,076h,0ABh,0ABh,0ABh
                DB  0ABh,09Eh,08Eh,083h,07Dh,077h,073h,0ABh
                DB  0ABh,0ABh,0ABh,09Eh,090h,081h,07Bh,074h
                DB  070h,0ABh,0ABh,0ABh,0ABh,0A1h,099h,08Eh
                DB  089h,085h,081h,0ABh,0ABh,0ABh,0ABh,0A2h
                DB  09Dh,098h,094h,090h,08Ch,0ABh,0ABh,0ABh
                DB  0ABh,0A2h,09Dh,098h,094h,090h,08Ch,0ABh
                DB  0ABh,0ABh,0ABh,0A2h,09Dh,098h,094h,090h
                DB  08Ch,0ABh,0ABh,0ABh,0ABh,0A2h,09Dh,098h
                DB  094h,090h,08Ch,0ABh,0ABh,0ABh,0ABh,0A2h
                DB  09Dh,098h,094h,090h,08Ch,0ABh,0ABh,0ABh
                DB  0ABh,0A2h,09Dh,098h,094h,090h,08Ch,0ABh
                DB  0ABh,0ABh,0ABh,0A2h,09Dh,098h,094h,090h
                DB  08Ch
;@ VEHigh type=u8 size=15x10 stride=10 formula=ve_percent rows.axis=RpmScalerVE rows.formula="x * 1875000 / 53125" rows.inverse="x * 53125 / 1875000" rows.unit=rpm rows.decimals=0 cols.axis=MapScalerVE cols.formula="x * 3.6105 + 114.3" cols.inverse="(x - 114.3) / 3.6105" cols.unit=mbar cols.decimals=0 category="VE" desc="VE map against the high-cam rpm byte."
VEHigh:         DB  08Bh,08Bh,08Bh,08Bh,08Bh,097h,097h
                DB  097h,097h,097h,08Bh,08Bh,08Bh,08Bh,08Bh
                DB  097h,097h,097h,097h,097h,08Bh,08Bh,08Bh
                DB  08Bh,08Bh,097h,097h,097h,097h,097h,08Bh
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h
                DB  097h,08Bh,08Bh,08Bh,08Bh,08Bh,097h,097h
                DB  097h,097h,097h,08Bh,08Bh,08Bh,08Bh,08Bh
                DB  097h,097h,097h,097h,097h,087h,087h,087h
                DB  087h,087h,093h,093h,093h,093h,093h,087h
                DB  087h,087h,087h,087h,093h,093h,093h,093h
                DB  093h,087h,087h,087h,087h,087h,093h,093h
                DB  093h,093h,093h,087h,087h,087h,087h,093h
                DB  093h,093h,093h,093h,093h,087h,087h,087h
                DB  087h,093h,093h,093h,093h,093h,093h,087h
                DB  087h,087h,087h,093h,093h,093h,097h,097h
                DB  097h,087h,087h,087h,087h,093h,093h,093h
                DB  097h,097h,097h,087h,087h,087h,087h,093h
                DB  093h,093h,097h,097h,097h,087h,087h,087h
                DB  087h,093h,093h,093h,097h,097h,097h
