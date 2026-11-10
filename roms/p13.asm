;==================================================================================================
; p13.asm -- the stock P13 (MSM66911), every ROM address a label; assembles to the original image byte for byte.
; The tables the code reads are annotated (;@): the app shows and edits them with their axes and scales - the maps,
; the VE slope/offset, the fuel and timing corrections, idle, tip-in, decel, knock, the rev limit, VTEC (its points
; are immediates in the code, annotated where they sit). Those whose role was not traced are under Internal
; (Stock_<label>). What each was found to do, and how it was checked in the simulator: roms/p13-skeleton.md.
; Naming: SFRs, vectors and the labels built from them use the 66911 names (ProcessorProfile.Msm66911), declared as
;   EQUs below so the bytes do not depend on the assembler's built-in SFR set.
;
; RAM map (verified uses; raw addresses stay numeric in the code):
;   09Bh      output latch: bit0 MIL(CEL), bit1 shift-light-style output [p13info CEL @1A4B]
;   0A4h      MAP sensor ADC word                  [p13info 0A4]
;   0ABh      TPS raw ADC byte (scaled -> 0178h)   [p13info 0AB]
;   0AEh      RPM word (FFFFh = invalid/no signal) [p13info 0AE]
;   0C6h/0CAh/0CCh  interpolated scalars: 0C6 MAP column, 0CA lo-cam RPM, 0CC hi-cam RPM
;   0D8h      IAT scaled (fault default 086h)      [HTS115-equiv]
;   0D9h      ECT scaled (fault default 062h; hot flags vs 61h/65h) [p13info 0D9 ?? -> confirmed]
;   0DBh      battery voltage (ADCR0 mux position 7, 03D7h): the injector dead time, the dwell, the code 17/20 gates
;   0DCh      ADCR2H copy (the idle's electrical-load compensation reads it; the simulator puts the battery there)
;   0DDh      electrical load detector (ADCR1 mux position 0, 03D8h; 25h fixed without the ELD, 220h bit 2)
;   0DFh      VSS km/h                             [p13info 0DF]
;   0EAh/0ECh/0EDh/0EEh/0EFh  table indices: 0ED=column(MAP), 0EE=row lo-cam, 0EF=row hi-cam
;   0E0h      barometric pressure, smoothed from 03D3h, on the map load's scale (fault default 0F9h); stands in
;             for the load while MAP has a fault
;   0E3h      the fuel map's load (288h with the tip-in prediction)  0E5h/0E6h/0E8h/0E9h sensor deltas
;   0FFh      time since start (the VTEC and other gates compare it with 32h)
;   0288h     the map load byte: (MAP word 0A4h - 1800h) >> 7, the ignition map's load (fuel: 0E3h)
;   0370h-037Ah  the last six CKP teeth's times (4 us); 0AEh = their sum / 4, worked out in the main loop;
;             037Ch the reading before 0AEh
;   0382h     the final injector pulse (4 us ticks, the dead time 0142h added); 0384h-038Ah the four cylinders'
;   02B8h/02B9h  the final advance bytes the spark timers are built from ((x - 24) / 4 degrees)
;   011Ah     fuel-cut flags: .0 cut, .2 overrun cut, .4 the rev limiter's
;   0224h/0227h  the 82C55's port A (8000h ^ C2h) and the second input buffer (1000h ^ 30h): 224h.0 A/C switch
;   0225h/0226h  copies of the 82C55's ports B (written inverted to A000h) and C (XOR 24h, C000h): B0 A/C clutch,
;             B1 fuel pump, B2 fan, B3 alternator, B7 purge; C2 A/T, C3 the lamp, C6/C7 VTEC
;   0214h.0   the starter signal (P4.5)  022Ch.2 power steering pressure (P4.6)
;   03F1h-03F6h  the stock serial link's poke values, copied by the main loop to 03F9h-03FEh
;   countdown timers (DP walks, decremented when not 0): 1A0h-1AAh, 1DCh-1FAh, 2CDh-2FFh, 3B7h-3B8h
;   0110h-0115h  CEL words er0-er3 (0110h.3, 0111h.7 read by rev limiter) [p13info 0110..]
;   016Ah     rev cut word    [p13info 016A]       016Ch rev resume word [p13info 016C]
;   0178h     TPS percent   0179h RPM byte         [p13info 0179]
;   0183h     final base injector pulse byte       0193h base fuel map value
;   0212h.5   rev-limit pair selector (pair A=5403/5407 when set)
;   021Dh.1   VTEC / high-cam active -- selects hi-cam maps everywhere [p13info 021D.1 confirmed]
;   0224h.0   A/C switch input (ACS)               [p13info 0224.0 confirmed]
;   022Eh.5   A/C request flag                     0289h RPM byte copy (VTEC pts 8Dh/93h) [p13info 0289]
;   02D0h     rev-limit hot/cold recheck timer
;   03A0h-03DFh raw ADC result area (03D0 O2, 03D2 IAT, 03D3 baro, 03D7 sens, 03DA ECT [p13info])
; ROM map (the annotations at each address give the detail):
;   0C1E/0C23 rev-limit boot defaults (immediates @0C21 FAh resume, @0C26 F4h cut) [p13info]
;   0D06  the ROM checksum sweep (0200h passes, counter 03A6h); 0D22 reads 07FF1h - past the image, 0 on a stock
;         EPROM - so the check is enforced; the factory/debug bytes 07FF0h-07FF2h read 0 the same way
; Datalogging: serial interrupt Int12, vector 0020h -> int_serial (0043h); STBUF=07Ch, SRBUF=07Dh,
;   SRSTAT=07Eh. The background task chain is entered at 00DBh from the same handler.
;==================================================================================================
; processor: MSM66911
; ---- MSM66911 SFRs. Defined here so the file assembles to the same bytes whatever SFR set the
;      assembler has loaded (the 66207 names used to be applied to these addresses, which made
;      e.g. the 66911 free-running counter TIMER read as SRSTAT and IGNB as ADCR2). Names as in
;      OkiRomSim ProcessorProfile.Msm66911; addresses with no known name stay numeric.
ASSP                 equ 000h
PSW                  equ 004h
ACC                  equ 006h
ACCH                 equ 007h
SBYCON               equ 010h
WDT                  equ 011h
STPACP               equ 013h
IRQ                  equ 018h
IRQH                 equ 019h
IE                   equ 01ah
IEH                  equ 01bh
P4IO                 equ 020h
P4                   equ 021h
P3SF                 equ 022h
P3IO                 equ 023h
P3                   equ 024h
P2A                  equ 025h
P2SF                 equ 026h
P2                   equ 028h
TRNSIT               equ 029h
PWM0CON              equ 02ah
PWM1CON              equ 02ch
PWMPRE               equ 02dh
PWM0CMP              equ 02eh
PWM0CNT              equ 030h
PWM1CMP              equ 03eh
PWM1CNT              equ 040h
OSIE                 equ 042h
OS1                  equ 046h
OS2                  equ 048h
INJ0                 equ 04ch
INJ1                 equ 04eh
INJ2                 equ 050h
TCON                 equ 054h
TCON2                equ 055h
TIMER                equ 056h
CAP0                 equ 058h
IGNCON               equ 061h
IGNA                 equ 062h
IGNB                 equ 064h
ADSCAN               equ 066h
ADSEL                equ 067h
ADCR0H               equ 069h
ADCR1H               equ 06bh
ADCR2H               equ 06dh
ADCR3H               equ 06fh
ADCR4                equ 070h
ADCR4H               equ 071h
ADCR5H               equ 073h
ADCR6                equ 074h
ADCR6H               equ 075h
ADCR7                equ 076h
ADCR7H               equ 077h
STTMR                equ 078h
SCONA                equ 07ah
PCLK                 equ 00fh
P4SF                 equ 01fh
P2IO                 equ 027h
PWMIE                equ 02bh
OS0                  equ 044h
INJ3                 equ 052h
CAP3                 equ 05eh
STTM                 equ 079h
SCONB                equ 07bh
STBUF                equ 07ch
SRBUF                equ 07dh
SRSTAT               equ 07eh
;==================================================================================================
                org 0000h
int_start_vec:            DW  int_start
int_break_vec:            DW  int_break
int_WDT_vec:              DW  int_WDT
int_NMI_vec:              DW  int_NMI
int_ckp_tdc_capture_vec:  DW  int_ckp_tdc_capture
int_crank_task_vec:       DW  int_crank_task
int_halt_timer_vec:       DW  int_spurious_irq_trap
int_vss_capture_vec:      DW  int_vss_capture
int_timer_overflow_vec:   DW  int_timer_overflow
int_pwm0_pin_vec:         DW  int_spurious_irq_trap
int_pwm0_software_vec:    DW  int_spurious_irq_trap
int_spare_2B0_vec:        DW  int_spurious_irq_trap
int_spare_2B4_vec:        DW  int_spurious_irq_trap
int_pwm1_pin_vec:         DW  int_spurious_irq_trap
int_tick_10ms_vec:        DW  int_tick_10ms
int_adc_complete_vec:     DW  int_spurious_irq_trap
int_serial_vec:           DW  int_serial
int_ignition_oneshot_vec: DW  int_spurious_irq_trap
int_oneshots_44_4A_vec:   DW  int_spurious_irq_trap
int_injector_oneshots_vec: DW int_spurious_irq_trap
vcal_0_vec:               DW  vcal_0
vcal_1_vec:               DW  vcal_1
vcal_2_vec:               DW  vcal_2
vcal_3_vec:               DW  vcal_3
vcal_4_vec:               DW  vcal_4
vcal_5_vec:               DW  vcal_5
vcal_6_vec:               DW  vcal_6
vcal_7_vec:               DW  vcal_7
code_start:     DB  004h,03Ch,05Ch,000h
int_NMI_set_sbycon_bit0:     SB      SBYCON.0
                NOP
                J       int_start
int_serial: MB      C, 0a0h.7
                JGE     int_serial_load_ie
                J       int_serial_load_ie_2
int_serial_load_ie:     L       A, IE
                PUSHS   A
                MOV     IE, #00001h
                SB      PSWH.0
                MOVB    PSWL, #002h
                MOV     LRB, #00011h
                MOV     DP, #003f0h
                SB      0a0h.3
                LB      A, SRBUF
                JBS     off(0007eh).3, int_serial_clear_ram07e_bit3
                STB     A, [DP]
                SJ      int_serial_store_ram07c
int_serial_clear_ram07e_bit3:     RB      SRSTAT.3
                JBS     off(ACC).7, int_serial_store_acch
                ANDB    A, #007h
                STB     A, ACCH
                LB      A, [DP]
                MOV     DP, A
                LB      A, [DP]
                SJ      int_serial_store_ram07c
int_serial_store_acch:     STB     A, ACCH
                ANDB    A, #0f0h
                CMPB    A, #0a0h
                JNE     int_serial_store_ram07c
                LB      A, ACCH
                ANDB    A, #007h
                CLRB    ACCH
                MOV     X1, A
                LB      A, [DP]
                STB     A, 003f1h[X1]
int_serial_store_ram07c:     STB     A, STBUF
                POPS    A
                RB      PSWH.0
                ST      A, IE
                RTI
                DB  0C5h,0A0h,02Fh,0CDh,003h,003h,0DBh,000h
                DB  0E5h,01Ah,055h,0B5h,01Ah,098h,001h,000h
                DB  0A2h,018h,0A3h,098h,002h,057h,060h,000h
                DB  0FAh,0C5h,07Eh,00Bh,0C9h,002h,086h,001h
                DB  0C5h,07Eh,00Ah,0C9h,002h,086h,002h,0D5h
                DB  007h,0F5h,07Dh,052h,042h,0C9h,00Ch,063h
                DB  0CAh,00Ch,0E2h,0F5h,006h,0C5h,007h,07Ch
                DB  0A0h,0CBh,004h,062h,0A0h,003h,0F2h,0D5h
                DB  07Ch,065h,0A2h,008h,0D5h,01Ah,002h
int_serial_load_ie_2:     L       A, IE
                PUSHS   A
                MOV     LRB, #00076h
                MOVB    PSWL, #002h
                MOV     IE, #00001h
                SB      PSWH.0
                JBS     off(003bch).0, int_serial_clear_ram3bc_bit1
                SJ      int_serial_load_r0
int_serial_clear_ram3bc_bit1:     RB      off(003bch).1
                JEQ     int_serial_cmp_r5
                RB      off(003bch).0
                SJ      int_serial_goto_0166
int_serial_cmp_r5:     CMPB    r5, #002h
                JNE     int_serial_load_r5
                LB      A, r2
                STB     A, STBUF
                SJ      int_serial_addb_acc
int_serial_load_r5:     LB      A, r5
                CMPB    A, r2
                JGT     int_serial_goto_0166
                JEQ     int_serial_set_ram3bc_bit1
                LB      A, off(003bah)
                CAL     int_serial_sub_cmp_acc
                INCB    off(003bah)
                STB     A, STBUF
int_serial_addb_acc:     ADDB    A, r6
                STB     A, r6
                SJ      int_serial_incb_r5
int_serial_set_ram3bc_bit1:     SB      off(003bch).1
                CLRB    A
                SUBB    A, r6
                STB     A, STBUF
int_serial_incb_r5:     INCB    r5
int_serial_goto_0166:     J       int_serial_clear_pswh_bit0
int_serial_load_r0:     MOVB    r0, SRBUF
                LB      A, r7
                JNE     int_serial_cmp_r5_2
                MOVB    off(003b9h), r1
                MOVB    r1, r0
                MOVB    r6, r0
                MOVB    r5, #001h
                SJ      int_serial_load_r7
int_serial_cmp_r5_2:     CMPB    r5, #001h
                JNE     int_serial_load_r2
                MOVB    r2, r0
                SJ      int_serial_load_r0_2
int_serial_load_r2:     LB      A, r2
                SUBB    A, #001h
                CMPB    A, r5
                JEQ     int_serial_load_r6
                CMPB    r5, #002h
                JNE     int_serial_load_r4
                MOVB    r3, r0
                SJ      int_serial_load_r0_2
int_serial_load_r4:     MOVB    r4, r0
int_serial_load_r0_2:     LB      A, r0
                ADDB    r6, A
                INCB    r5
int_serial_load_r7:     MOVB    r7, #002h
                SJ      int_serial_clear_pswh_bit0
int_serial_load_r6:     LB      A, r6
                ADDB    A, r0
                JNE     int_serial_clear_r7
                LB      A, r1
                ANDB    A, #0e0h
                CMPB    A, #020h
                JNE     int_serial_clear_r7
                SB      off(003bch).2
int_serial_clear_r7:     CLRB    r7
int_serial_clear_pswh_bit0:     RB      PSWH.0
                POPS    A
                ST      A, IE
                RTI
int_tick_10ms: SB      09eh.3
                RTI
int_timer_overflow: RB      09eh.1
                JNE     int_timer_overflow_clear_ram09e_bit2
                INCB    0f7h
int_timer_overflow_clear_ram09e_bit2:     RB      09eh.2
                JNE     int_timer_overflow_return
                INCB    0f6h
int_timer_overflow_return:     RTI
int_vss_capture: L       A, IE
                PUSHS   A
                MOV     IE, #00001h
                SB      PSWH.0
                L       A, CAP3
                CMP     A, #08000h
                JGE     int_vss_capture_xchg_acc
                MB      C, IRQ.4
                JGE     int_vss_capture_xchg_acc
                INCB    0f6h
                SB      09eh.2
int_vss_capture_xchg_acc:     XCHG    A, 0b8h
                ST      A, 0b6h
                LB      A, 0f6h
                STB     A, 0bah
                SB      0a0h.1
                CLRB    0f6h
                POPS    A
                RB      PSWH.0
                ST      A, IE
                RTI
int_ckp_tdc_capture:       MB      C, TCON.4
                JLT     int_ckp_tdc_capture_set_irq_bit1
                RB      0a0h.5
                JEQ     int_ckp_tdc_capture_clear_ram0a0_bit6
                L       A, CAP0
                SUB     A, TIMER
                ADD     A, 0c0h
                JLT     int_ckp_tdc_capture_store_ignb
                CLR     A
int_ckp_tdc_capture_store_ignb:     ST      A, IGNB
int_ckp_tdc_capture_clear_ram0a0_bit6:     RB      0a0h.6
                JEQ     int_ckp_tdc_capture_load_carry_ram09f_bit5
                L       A, CAP0
                SUB     A, TIMER
                ADD     A, 0beh
                JLT     int_ckp_tdc_capture_store_igna
                CLR     A
int_ckp_tdc_capture_store_igna:     ST      A, IGNA
int_ckp_tdc_capture_load_carry_ram09f_bit5:     MB      C, 09fh.5
                JLT     int_ckp_tdc_capture_set_irq_bit1
                RB      ADSCAN.4
                MOVB    ADSCAN, #056h
int_ckp_tdc_capture_set_irq_bit1:     SB      IRQ.1
                RTI
int_crank_task:  L       A, IE
                PUSHS   A
                MOV     IE, #00001h
                SB      PSWH.0
                MOVB    PSWL, #002h
                MOV     LRB, #00021h
                MOV     USP, #00280h
                L       A, (00214h-00280h)[USP]
                ST      A, off(00114h)
                JBR     off(00114h).7, int_crank_task_load_ram1a0
                SB      off(00127h).4
                JBS     off(00110h).7, int_crank_task_goto_0738
                JBS     off(00110h).3, int_crank_task_load_ram0bc
                RB      TRNSIT.7
                JEQ     dtc04_ckp_latch
                RB      09ch.0
                MOVB    off(001a0h), #02dh
int_crank_task_goto_0738:     J       crank_cycle_er2_store_load_ram11a
dtc04_ckp_latch:     SB      09ch.0
int_crank_task_load_ram0bc:     MOVB    0bch, #000h
                LB      A, #003h
                RB      TRNSIT.6
                JNE     crank_tooth_count_store
                LB      A, off(0013ch)
                ADDB    A, #006h
                CMPB    A, #018h
                JLT     crank_tooth_count_store
                LB      A, #003h
crank_tooth_count_store:     STB     A, off(0013ch)
                RB      P3.3
                CAL     crank_tooth_count_store_sub_clear_ram0a0_bit6
                J       crank_sync_exit_jump_clear_ram12c
int_crank_task_load_ram1a0:     MOVB    off(001a0h), #02dh
                JBR     off(00127h).3, int_crank_task_clear_trnsit_bit7_2
                J       int_crank_task_if_ram110_bit7_clr
int_crank_task_clear_trnsit_bit7:     RB      TRNSIT.7
                JNE     crank_sync_lost_path
                RB      09fh.2
                JNE     crank_sync_lost_path
int_crank_task_load_ram0bc_2:     LB      A, 0bch
                ADDB    A, #001h
                CMPB    A, #006h
                JLT     crank_sync_flag_high_store_ram0bc
                JBS     off(00110h).7, int_crank_task_incb_ram0bd
dtc08_tdc_latch_2: SB      09ch.1
                SB      off(00127h).6
int_crank_task_incb_ram0bd:     INCB    0bdh
                CLRB    A
                SJ      crank_sync_flag_high_store_ram0bc
int_crank_task_clear_trnsit_bit7_2:     RB      TRNSIT.7
                RB      09fh.2
                RB      TRNSIT.6
                MB      C, 09fh.1
                JGE     crank_sync_exit_jump
                SB      off(00127h).4
crank_sync_exit_jump:     J       crank_sync_exit_jump_clear_ram12c
crank_sync_lost_path:     SB      off(00127h).4
                RB      off(00127h).6
                MOVB    off(001a1h), #02dh
                L       A, 0bch
                CMP     A, #00005h
                JEQ     crank_sync_flag_high_clear_acc
                SB      off(0011ah).7
                JLT     crank_sync_flag_mid
                CMP     A, #00105h
                JGE     crank_sync_flag_high
                SB      09dh.0
                SJ      crank_sync_flag_high_clear_acc
crank_sync_flag_mid:     SB      off(00127h).5
                SJ      crank_sync_flag_high_clear_acc
crank_sync_flag_high:     SB      09dh.1
crank_sync_flag_high_clear_acc:     CLRB    A
                STB     A, 0bdh
crank_sync_flag_high_store_ram0bc:     STB     A, 0bch
                J       crank_sync_flag_high_if_ram111_bit0_clr
crank_sync_flag_high_clear_trnsit_bit6:     RB      TRNSIT.6
                JNE     crank_sync_flag_high_clear_ram127_bit7
crank_sync_flag_high_load_ram13c:     LB      A, off(0013ch)
                ADDB    A, #001h
                CMPB    A, #018h
                JLT     crank_sync_flag_common_store_ram13c
                JBS     off(00111h).0, crank_sync_flag_high_incb_ram13d
dtc09_cyp_latch: SB      09ch.2
                SB      off(00127h).7
crank_sync_flag_high_incb_ram13d:     INCB    off(0013dh)
                CLRB    A
                SJ      crank_sync_flag_common_store_ram13c
crank_window_flag_check2:     RB      off(00127h).5
                JGE     crank_sync_flag_common_clear_acc
                JEQ     crank_sync_flag_common
                SB      09dh.0
                SJ      crank_sync_flag_common_clear_acc
crank_sync_flag_low:     SB      09dh.1
                SJ      crank_sync_flag_common_clear_acc
crank_sync_flag_high_clear_ram127_bit7:     RB      off(00127h).7
                MOVB    off(001a2h), #007h
                L       A, off(0013ch)
                CMP     A, #00017h
                JNE     crank_window_flag_check2
                RB      off(00127h).5
                JNE     crank_sync_flag_low
                RB      off(0011ah).7
                CMPB    0bch, #003h
                JEQ     crank_sync_flag_common_clear_acc
crank_sync_flag_common:     SB      09dh.2
crank_sync_flag_common_clear_acc:     CLRB    A
                STB     A, off(0013dh)
crank_sync_flag_common_store_ram13c:     STB     A, off(0013ch)
                JBS     off(00110h).7, crank_tooth_mod6_calc
                JBR     off(00127h).6, crank_sync_flag_common_if_ram111_bit0_set
crank_tooth_mod6_calc:     CLR     A
                MOVB    r0, #006h
                LB      A, off(0013ch)
                ADDB    A, #003h
                DIVB
                LB      A, r1
                STB     A, 0bch
                JBS     off(00111h).0, crank_tooth_mod6_calc_set_ram11a_bit0
                JBR     off(00127h).7, crank_sync_flag_common_if_ram111_bit0_set
crank_tooth_mod6_calc_set_ram11a_bit0:     SB      off(0011ah).0
crank_sync_flag_common_if_ram111_bit0_set:     JBS     off(00111h).0, crank_tooth_wrap_calc
                JBR     off(00127h).7, crank_sync_exit_jump_clear_ram12c
crank_tooth_wrap_calc:     MOVB    r0, #006h
                LB      A, 0bch
                ADDB    A, #003h
                SUBB    A, r0
                JGE     crank_tooth_wrap_store
                ADDB    A, r0
crank_tooth_wrap_store:     STB     A, r2
                CLR     A
                LB      A, off(0013ch)
                DIVB
                MULB
                ADDB    A, r2
                STB     A, off(0013ch)
crank_sync_exit_jump_clear_ram12c:     CLRB    off(0012ch)
                JBS     off(00127h).2, crank_sync_exit_jump_clear_acc
                LB      A, off(0019dh)
                JEQ     crank_sync_exit_jump_load_ram0bc
                J       crank_sync_exit_jump_clear_carry
crank_sync_exit_jump_load_ram0bc:     LB      A, 0bch
                JBS     off(00128h).2, crank_sync_exit_jump_if_ram114_bit7_set
                JNE     crank_sync_exit_jump_clear_carry
                SB      off(00128h).2
crank_sync_exit_jump_if_ram114_bit7_set:     JBS     off(00114h).7, crank_sync_exit_jump_set_ram127_bit2
                CMPB    A, #001h
                JNE     crank_sync_exit_jump_clear_carry
crank_sync_exit_jump_set_ram127_bit2:     SB      off(00127h).2
crank_sync_exit_jump_clear_acc:     CLR     A
                LB      A, off(0013ch)
                MOV     X1, A
                LCB     A, crank_sync_exit_jump_tbl[X1]
                STB     A, r2
                ANDB    A, #003h
                STB     A, r0
                LB      A, r2
                SWAPB
                ANDB    A, #00fh
                STB     A, r1
                JNE     crank_sync_exit_jump_if_ram114_bit7_clr
                ANDB    off(00129h), #0b5h
crank_sync_exit_jump_if_ram114_bit7_clr:     JBR     off(00114h).7, crank_sync_exit_jump_if_ram129_bit6_set
                CMPB    A, #00bh
                JNE     crank_sync_exit_jump_if_ram129_bit6_set
                RB      off(00129h).6
                SJ      crank_sync_exit_jump_load_imm
crank_sync_exit_jump_if_ram129_bit6_set:     JBS     off(00129h).6, crank_sync_exit_jump_load_imm
                CMPB    A, off(0019bh)
                JLT     crank_sync_exit_jump_load_imm
                LB      A, r0
                SBR     off(0012ch)
                ADDB    A, #004h
                RBR     P3SF
                SB      off(00129h).6
crank_sync_exit_jump_load_imm:     LB      A, #003h
                CMPB    r1, #006h
                SBCB    A, r0
                STB     A, off(0019ch)
                LB      A, r1
                SUBB    A, #006h
                JGE     crank_sync_exit_jump_if_ne_goto_03a3
                ADDB    A, #00ch
crank_sync_exit_jump_if_ne_goto_03a3:     JNE     crank_sync_exit_jump_if_ram114_bit7_clr_2
                ANDB    off(00129h), #07ah
crank_sync_exit_jump_if_ram114_bit7_clr_2:     JBR     off(00114h).7, crank_sync_exit_jump_if_ram129_bit7_set
                CMPB    A, #00bh
                JNE     crank_sync_exit_jump_if_ram129_bit7_set
                RB      off(00129h).7
                SJ      crank_sync_exit_jump_clear_carry
crank_sync_exit_jump_if_ram129_bit7_set:     JBS     off(00129h).7, crank_sync_exit_jump_clear_carry
                CMPB    A, off(0019bh)
                JLT     crank_sync_exit_jump_clear_carry
                LB      A, r2
                ANDB    A, #00ch
                SRLB    A
                SRLB    A
                SBR     off(0012ch)
                ADDB    A, #004h
                RBR     P3SF
                SB      off(00129h).7
crank_sync_exit_jump_clear_carry:     RC
                LB      A, 0bch
                JNE     crank_sync_exit_jump_store_carry_ram12e_bit3
                JBR     off(00127h).4, crank_sync_exit_jump_store_carry_ram12e_bit3
                INCB    off(0019eh)
                JBS     off(00132h).2, crank_sync_exit_jump_store_carry_ram12e_bit3
                CLRB    A
                JBR     off(0011ah).6, crank_sync_exit_jump_andb_ram19e
                LB      A, #001h
                JBR     off(00128h).1, crank_sync_exit_jump_andb_ram19e
                LB      A, #003h
crank_sync_exit_jump_andb_ram19e:     ANDB    off(0019eh), A
                JNE     crank_sync_exit_jump_store_carry_ram12e_bit3
                SC
crank_sync_exit_jump_store_carry_ram12e_bit3:     MB      off(0012eh).3, C
                LB      A, 0bch
                SLLB    A
                EXTND
                MOV     X1, A
                MOV     er3, off(00138h)
                L       A, CAP0
                ST      A, off(00138h)
                MOVB    r0, 0f7h
                SB      off(00127h).3
                JEQ     rpm_period_reset_loop_clear_ram0f7
                CMP     A, #08000h
                JGE     crank_sync_exit_jump_sub_acc
                MB      C, IRQ.4
                JGE     crank_sync_exit_jump_sub_acc
                INCB    r0
                SB      09eh.1
crank_sync_exit_jump_sub_acc:     SUB     A, er3
                SBCB    r0, #000h
                JBR     off(00114h).7, crank_sync_exit_jump_if_eq_goto_0430
                CLRB    r1
                MOV     er2, #00006h
                DIV
                CMPB    r0, #000h
                JEQ     rpm_period_reset_calc
                CLR     A
rpm_period_reset_calc:     ST      A, off(00136h)
                MOV     X1, #0000ch
rpm_period_reset_loop:     DEC     X1
                DEC     X1
                ST      A, 00370h[X1]
                JGT     rpm_period_reset_loop
                SJ      rpm_period_reset_loop_clear_ram0f7
crank_sync_exit_jump_if_eq_goto_0430:     JEQ     crank_sync_exit_jump_store_ram136
                CLR     A
crank_sync_exit_jump_store_ram136:     ST      A, off(00136h)
                ST      A, 00370h[X1]
rpm_period_reset_loop_clear_ram0f7:     CLRB    0f7h
                LB      A, off(0013ch)
                CMPB    A, #002h
                JLT     rpm_period_reset_loop_store_carry_ram131_bit5
                MOVB    r0, #013h
                CMPB    r0, A
rpm_period_reset_loop_store_carry_ram131_bit5:     MB      off(00131h).5, C
                LB      A, 0bch
                CMPB    A, #005h
                JNE     rpm_period_reset_loop_load_carry_p3_bit3
                SLLB    off(001b3h)
rpm_period_reset_loop_load_carry_p3_bit3:     MB      C, P3.3
                JLT     rpm_period_reset_loop_load_dp
                JBR     off(0011ah).5, rpm_period_reset_loop_load_dp_2
rpm_period_reset_loop_load_dp:     MOV     DP, #00004h
rpm_period_reset_loop_nop_acc:     NOP
                JRNZ    DP, rpm_period_reset_loop_nop_acc
                SJ      crank_a0_update_set_ram09f_bit5
rpm_period_reset_loop_load_dp_2:     MOV     DP, #00396h
                MB      C, 09fh.0
                JBS     off(001b3h).2, rpm_period_reset_loop_store_carry_pswl_bit4
                MOV     DP, #0038eh
                MB      C, 09eh.6
                JBR     off(00131h).5, rpm_period_reset_loop_store_carry_pswl_bit4
                MOV     DP, #00392h
                MB      C, 09eh.7
rpm_period_reset_loop_store_carry_pswl_bit4:     MB      PSWL.4, C
                CMPB    A, #005h
                JEQ     crank_a0_update
                CMPB    A, #000h
                JLE     crank_a0_update_set_ram09f_bit5
                CMPB    A, #004h
                JGE     crank_a0_update_set_ram09f_bit5
                CMPB    A, 0c4h
                JGE     crank_a0_update_set_ram09f_bit5
                CMPB    A, [DP]
                JGE     crank_a0_update_set_ram09f_bit5
crank_a0_update:     L       A, [DP]
                ST      A, 0c4h
                DEC     DP
                LB      A, [DP]
                STB     A, 0c3h
                MB      C, PSWL.4
                MB      off(00132h).1, C
crank_a0_update_set_ram09f_bit5:     SB      09fh.5
                JNE     crank_a0_update_load_adcr6
                JBR     off(0012eh).3, crank_a0_update_clear_adscan_bit4
                LB      A, P3
                ANDB    A, #0f8h
                XORB    A, #0ffh
                ANDB    A, #00fh
                STB     A, P3
crank_a0_update_clear_adscan_bit4:     RB      ADSCAN.4
                MB      C, ADSCAN.5
                JGE     crank_a0_update_load_adscan
                SB      09fh.4
crank_a0_update_load_adscan:     MOVB    ADSCAN, #010h
crank_a0_update_load_adcr6:     L       A, ADCR6
                ST      A, 0a4h
                CLR     er1
                L       A, ADCR7
                ST      A, er0
                XCHG    A, 0a6h
                XCHG    A, 0a8h
                CMPB    off(00179h), #0a0h
                JGE     crankfuel_clamp_max_load_ram14a
                JBR     off(00127h).2, crankfuel_clamp_max_load_ram14a
                JBS     off(00114h).7, crankfuel_clamp_max_load_ram14a
                JBS     off(00110h).6, crankfuel_clamp_max_load_ram14a
                MB      C, 098h.2
                JLT     crankfuel_clamp_max_load_ram14a
                JBS     off(0011dh).0, crankfuel_clamp_max_load_ram14a
                JBS     off(00114h).0, crankfuel_clamp_max_load_ram14a
                JBR     off(0012dh).5, crankfuel_clamp_max_load_ram14a
                SUB     er0, A
                JLE     crankfuel_clamp_max_load_ram14a
                CMP     er0, #00400h
                JLE     crankfuel_clamp_max_load_ram14a
                L       A, #031cch
                MUL
                MOV     er0, #005a9h
                L       A, er1
                ADD     A, #000b5h
                JLT     crank_a0_update_load_er0
                CMP     A, er0
                JLT     crank_a0_update_load_r1
crank_a0_update_load_er0:     L       A, er0
crank_a0_update_load_r1:     MOVB    r1, off(00186h)
                CLRB    r0
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JLT     crankfuel_clamp_max
                ADD     A, off(00142h)
                JGE     crankfuel_clamp_max_store_er1
crankfuel_clamp_max:     L       A, #0ffffh
crankfuel_clamp_max_store_er1:     ST      A, er1
crankfuel_clamp_max_load_ram14a:     MOV     off(0014ah), er1
                LB      A, off(0012ch)
                JNE     crankfuel_clamp_max_store_r0
                J       crankfuel_clamp_max_load_ram14a_2
crankfuel_clamp_max_store_r0:     STB     A, r0
                J       crankfuel_clamp_max_clear_x1
                DB  000h
crankfuel_clamp_max_srlb_r0:     SRLB    r0
                JBS     off(0011ah).0, injtimer_countdown_store_load_r1
                JGE     crankfuel_clamp_max_load_ram14e
                JBR     off(0011dh).0, crankfuel_clamp_max_clear_acc
                LB      A, off(001b6h)
                SUBB    A, #001h
                JGE     injtimer_countdown_store
                LB      A, #007h
injtimer_countdown_store:     STB     A, off(001b6h)
                CMPB    A, #007h
                JGT     injtimer_countdown_store_clear_ram1b3_bit0
                MBR     C, off(001aeh)
                JLT     injtimer_countdown_store_sbr_ram1af
                SUBB    A, #004h
                ANDB    A, #007h
                RBR     off(001afh)
                JEQ     injtimer_countdown_store_load_tbl_x1
                L       A, off(001b0h)
                SJ      injtimer_countdown_store_store_tbl_x1
injtimer_countdown_store_load_tbl_x1:     L       A, 00398h[X1]
                SUB     A, #0ffffh
                JGE     injtimer_countdown_store_store_tbl_x1
                CLR     A
injtimer_countdown_store_store_tbl_x1:     ST      A, 00398h[X1]
                SJ      injtimer_countdown_store_clear_ram1b3_bit0
injtimer_countdown_store_sbr_ram1af:     SBR     off(001afh)
                SB      off(001b3h).0
                SJ      injtimer_countdown_store_load_r1
crankfuel_clamp_max_clear_acc:     CLR     A
                MOV     X2, A
                ST      A, 00398h[X2]
                ST      A, 0039ah[X2]
                ST      A, 0039ch[X2]
                ST      A, 0039eh[X2]
                ST      A, off(001aeh)
injtimer_countdown_store_clear_ram1b3_bit0:     RB      off(001b3h).0
                L       A, 00384h[X1]
                ADD     A, 00398h[X1]
                JGE     injtimer_countdown_store_store_tbl_x1_2
                L       A, #0ffffh
injtimer_countdown_store_store_tbl_x1_2:     ST      A, 0004ch[X1]
                CMP     A, #00003h
                JLT     injtimer_countdown_store_load_r1
                SB      off(00127h).1
injtimer_countdown_store_load_r1:     LB      A, r1
                SBR     P3SF
                SJ      injtimer_countdown_store_inc_x1
crankfuel_clamp_max_load_ram14e:     L       A, off(0014eh)
                JEQ     injtimer_countdown_store_inc_x1
                CMP     A, 0004ch[X1]
                JGE     crankfuel_clamp_max_store_tbl_x1
                CMP     0004ch[X1], #0ffffh
                JNE     injtimer_countdown_store_inc_x1
crankfuel_clamp_max_store_tbl_x1:     ST      A, 0004ch[X1]
injtimer_countdown_store_inc_x1:     INC     X1
                INC     X1
                INCB    r1
                CMPB    r1, #008h
                JGE     injtimer_countdown_store_clear_ram14e
                J       crankfuel_clamp_max_srlb_r0
injtimer_countdown_store_clear_ram14e:     CLR     off(0014eh)
crankfuel_clamp_max_load_ram14a_2:     L       A, off(0014ah)
                JEQ     crankfuel_clamp_max_load_ram0bc
                ST      A, er0
                LB      A, off(0019ch)
                EXTND
                MOV     X1, A
                SLL     X1
                SBR     off(00129h)
                JNE     crankfuel_clamp_max_load_ram19c
                L       A, er0
                CAL     crankfuel_clamp_max_sub_cmp_acc
crankfuel_clamp_max_load_ram19c:     LB      A, off(0019ch)
                ADDB    A, #001h
                ANDB    A, #003h
                EXTND
                MOV     X1, A
                SLL     X1
                SBR     off(00129h)
                JNE     crankfuel_clamp_max_load_ram0bc
                L       A, er0
                CAL     crankfuel_clamp_max_sub_cmp_acc
crankfuel_clamp_max_load_ram0bc:     LB      A, 0bch
                ADDB    A, #001h
                CMPB    A, 0c4h
                JEQ     crankfuel_clamp_max_load_ram0c5
                CMPB    A, #006h
                JNE     crankfuel_clamp_max_clear_ram127_bit1
                LB      A, 0c4h
                JEQ     crankfuel_clamp_max_load_ram0c5
                CMPB    A, #0ffh
                JNE     crankfuel_clamp_max_clear_ram127_bit1
crankfuel_clamp_max_load_ram0c5:     LB      A, 0c5h
                STB     A, ACCH
                CLRB    A
                MOV     er0, off(00136h)
                MUL
                CLR     A
                JBS     off(0011ah).5, crankfuel_clamp_max_set_ram0a0_bit6
                CMPB    0c4h, #0ffh
                JEQ     crankfuel_clamp_max_load_ram138
                L       A, er1
crankfuel_clamp_max_set_ram0a0_bit6:     SB      0a0h.6
                SJ      crankfuel_clamp_max_store_ram0be
crankfuel_clamp_max_load_ram138:     L       A, off(00138h)
                SUB     A, TIMER
                ADD     A, er1
                JLT     crankfuel_clamp_max_store_igna
                CLR     A
crankfuel_clamp_max_store_igna:     ST      A, IGNA
                L       A, er1
crankfuel_clamp_max_store_ram0be:     ST      A, 0beh
crankfuel_clamp_max_clear_ram127_bit1:     RB      off(00127h).1
                JEQ     crankfuel_clamp_max_if_ram114_bit7_clr
                JBS     off(0011fh).2, crankfuel_clamp_max_if_ram111_bit7_set
                JBR     off(0011fh).3, crankfuel_clamp_max_if_ram114_bit7_clr
crankfuel_clamp_max_if_ram111_bit7_set:     JBS     off(00111h).7, crankfuel_clamp_max_if_ram114_bit7_clr
                RB      TRNSIT.3
                JNE     crankfuel_clamp_max_if_ram114_bit7_clr
dtc16_injector_latch: SB      09ch.6
crankfuel_clamp_max_if_ram114_bit7_clr:     JBR     off(00114h).7, crankfuel_clamp_max_load_ram0bc_2
                J       crankfuel_clamp_max_load_imm_3
crankfuel_clamp_max_load_ram0bc_2:     LB      A, 0bch
                JEQ     crankfuel_clamp_max_load_imm
                CMPB    A, #003h
                JGE     crankfuel_clamp_max_cmp_acc
                J       crank_cycle_er2_store_set_carry
crankfuel_clamp_max_cmp_acc:     CMPB    A, #005h
                JNE     crankfuel_clamp_max_if_ram11a_bit5_set
                JBS     off(00132h).1, crankfuel_clamp_max_clear_acc_2
                SJ      crank_cycle_er2_store_goto_06e4
crankfuel_clamp_max_if_ram11a_bit5_set:     JBS     off(0011ah).5, crank_cycle_period_saturate
                CMPB    A, #003h
                MOV     DP, #00376h
                CLR     er2
                JBS     off(00132h).1, crank_cycle_alt_dp
                JEQ     crank_cycle_alt_dp_load_er0
crankfuel_clamp_max_clear_acc_2:     CLR     A
                SJ      crank_cycle_er2_store
crank_cycle_alt_dp:     MOV     DP, #00372h
                JNE     crank_cycle_alt_dp_load_er0
                MOV     er2, [DP]
crank_cycle_alt_dp_load_er0:     MOV     er0, [DP]
                LB      A, 0c3h
                STB     A, ACCH
                CLRB    A
                MUL
                L       A, er2
                ADD     A, er1
                JGE     crank_cycle_er2_store
crank_cycle_period_saturate:     L       A, #0ffffh
crank_cycle_er2_store:     ST      A, 0c0h
                SB      0a0h.5
crank_cycle_er2_store_goto_06e4:     SJ      crank_cycle_er2_store_set_carry
crankfuel_clamp_max_load_imm:     LB      A, #002h
                JBS     off(0011bh).5, crankfuel_clamp_max_srlb_acc
                CMPB    0f1h, #024h
                JNE     crankfuel_clamp_max_cmp_ram1a1
                SB      off(00132h).0
crankfuel_clamp_max_cmp_ram1a1:     CMPB    off(001a1h), #028h
                JLE     crankfuel_clamp_max_set_ram127_bit4
                MOV     DP, #00370h
crankfuel_clamp_max_load_dp_ind:     L       A, [DP]
                JEQ     crankfuel_clamp_max_clear_acc_3
                INC     DP
                INC     DP
                CMP     DP, #0037ch
                JLT     crankfuel_clamp_max_load_dp_ind
                JBS     off(00132h).0, crankfuel_clamp_max_load_imm_2
                JBS     off(00110h).5, crankfuel_clamp_max_clear_acc_3
                CMPB    0d9h, #028h
                JLT     crankfuel_clamp_max_load_imm_2
crankfuel_clamp_max_clear_acc_3:     CLRB    A
                SJ      crankfuel_clamp_max_srlb_acc
crankfuel_clamp_max_set_ram127_bit4:     SB      off(00127h).4
crankfuel_clamp_max_load_imm_2:     LB      A, #005h
                STB     A, 0c4h
                CLRB    A
                STB     A, 0c5h
                LB      A, #0ffh
                STB     A, 0c3h
                SB      off(00132h).1
                LB      A, #003h
crankfuel_clamp_max_srlb_acc:     SRLB    A
                MB      off(0011ah).5, C
                SRLB    A
                MB      P3.3, C
crankfuel_clamp_max_load_imm_3:     L       A, #000f3h
                CMP     A, 0aeh
                JGE     crankfuel_clamp_max_load_ram1a3
                JBS     off(00111h).6, crankfuel_clamp_max_clear_carry
                JBS     off(0011ah).7, crankfuel_clamp_max_clear_carry
                RB      TRNSIT.4
                JEQ     dtc15_ign_output_latch
crankfuel_clamp_max_clear_carry:     RC
crankfuel_clamp_max_load_ram1a3:     MOVB    off(001a3h), #006h
dtc15_ign_output_latch:     MB      09ch.3, C
crank_cycle_er2_store_set_carry:     SC
                JBS     off(00114h).7, crank_cycle_er2_store_store_carry_ram09f_bit5
                JBR     off(00127h).2, crank_cycle_er2_store_store_carry_ram09f_bit5
                RC
                JBR     off(00128h).0, crank_cycle_er2_store_store_carry_ram09f_bit5
                LB      A, 0bch
                CMPB    A, #005h
crank_cycle_er2_store_store_carry_ram09f_bit5:     MB      09fh.5, C
                JBS     off(00121h).1, crank_cycle_er2_store_load_ram176
                J       crank_cycle_er2_store_if_ram12e_bit3_clr
crank_cycle_er2_store_load_ram176:     L       A, off(00176h)
                MB      C, P4.1
                ROR     A
                MB      C, P4.2
                ROR     A
                CMPB    0bch, #000h
                JNE     crank_cycle_er2_store_store_ram176
                ST      A, 0d0h
                CLR     A
crank_cycle_er2_store_store_ram176:     ST      A, off(00176h)
                LB      A, 0bch
                CMPB    A, #001h
                JNE     crank_a8_p3sf_output
                L       A, 0ceh
                ST      A, off(00174h)
crank_a8_p3sf_output:     L       A, off(00174h)
                ST      A, er0
                SRL     A
                SRL     A
                ST      A, off(00174h)
                ANDB    r0, #003h
                MOV     DP, #0c000h
                LB      A, (00226h-00280h)[USP]
                ANDB    A, #0fch
                ORB     A, r0
                STB     A, (00226h-00280h)[USP]
                XORB    A, #024h
                STB     A, [DP]
crank_cycle_er2_store_if_ram12e_bit3_clr:     JBR     off(0012eh).3, crank_cycle_er2_store_load_ram11a
                J       crank_cycle_er2_store_set_ram132_bit2
crank_cycle_er2_store_load_ram11a:     L       A, off(0011ah)
                ST      A, (0021ah-00280h)[USP]
                POPS    A
                RB      PSWH.0
                ST      A, IE
                RTI
int_spurious_irq_trap:  MOVB    0d4h, #047h
                SJ      fault_retry_check
int_WDT:        MOVB    0d4h, #048h
fault_retry_check:     LB      A, 0d6h
                JEQ     fault_retry_check_set_ram09e_bit0
                DECB    0d6h
                JNE     fault_retry_check_nop_acc
fault_retry_check_set_ram09e_bit0:     SB      09eh.0
fault_retry_check_nop_acc:     NOP
                NOP
                NOP
                BRK
int_NMI:        MOV     LRB, #00041h
                RB      09fh.7
                JEQ     int_NMI_load_carry_pwm1con_bit4
                STB     A, [DP]
int_NMI_load_carry_pwm1con_bit4:     MB      C, PWM1CON.4
                JLT     int_start_clear_ram0d4
                SB      P2A.1
                RB      ADSCAN.4
                RB      ADSEL.3
                CLR     IE
                SB      SBYCON.2
                LB      A, #005h
                STB     A, STPACP
                SLLB    A
                STB     A, STPACP
                J       int_NMI_set_sbycon_bit0
int_start:      RB      09eh.0
                RB      09eh.5
int_start_clear_ram0d4:     CLRB    0d4h
                BRK
int_break:      MOV     SSP, #0047fh
                MB      C, PWM1CON.4
                JGE     int_NMI
                CLR     LRB
                LB      A, 0d4h
                JEQ     int_break_load_ram00f
                CMPB    A, #063h
                JNE     int_break_load_ram00f
                MOVB    0d4h, #049h
                J       fault_retry_check
int_break_load_ram00f:     MOVB    PCLK, #0a4h
                MOV     OS0, #0ffffh
                RB      PSWH.0
                CLR     A
                ST      A, IE
                ST      A, IRQ
                MB      C, PSWH.4
                JGE     int_break_load_ram0d4
                MB      C, PSWH.0
                JLT     int_break_load_ram0d4
                L       A, #05555h
                ST      A, ASSP
                CMP     SSP, #05555h
                JNE     int_break_load_ram0d4
                MOV     LRB, A
                CMP     A, LRB
                JNE     int_break_load_ram0d4
                ST      A, IE
                CMP     A, IE
                JNE     int_break_load_ram0d4
                SLL     A
                MB      PSWH.6, C
                JEQ     int_break_load_ram0d4
                ST      A, ASSP
                CMP     SSP, #0aaaah
                JNE     int_break_load_ram0d4
                MOV     SSP, #0047fh
                MOV     LRB, A
                CMP     A, LRB
                JNE     int_break_load_ram0d4
                ST      A, IE
                CMP     A, IE
                JNE     int_break_load_ram0d4
                MOVB    PSWL, #055h
                LB      A, PSW
                MB      C, PSWH.4
                JLT     int_break_load_ram0d4
                ANDB    A, #037h
                CMPB    A, #015h
                JNE     int_break_load_ram0d4
                MOVB    PSWL, #0aah
                LB      A, PSW
                ANDB    A, #037h
                CMPB    A, #022h
                JNE     int_break_load_ram0d4
                CLR     A
                ST      A, IE
                SB      PSWH.0
                MB      C, PSWH.0
                JLT     int_break_load_wdt
int_break_load_ram0d4:     MOVB    0d4h, #046h
                J       fault_retry_check_nop_acc
int_break_load_wdt:     MOVB    WDT, #03ch
                MOV     LRB, #00011h
                MOVB    PSWL, #000h
                MB      C, P4.5
                MB      09fh.1, C
                MOVB    P2A, #06fh
                MOVB    P4SF, #001h
                MOVB    P4IO, #011h
                MOVB    P4, #011h
                MOVB    P3SF, #0f0h
                MOVB    P3IO, #0ffh
                MOVB    P3, #007h
                MOVB    P2SF, #006h
                MOVB    P2IO, #006h
                MOVB    P2, #0f0h
                CLRB    043h
                MOVB    OSIE, #0f0h
                MOVB    TCON, #089h
                CLRB    TCON2
                MOVB    IGNCON, #010h
                L       A, #05555h
                MOV     X1, A
                CMP     A, X1
                JNE     int_break_load_ram0d4_2
                MOV     X2, A
                CMP     A, X2
                JNE     int_break_load_ram0d4_2
                MOV     DP, A
                CMP     A, DP
                JNE     int_break_load_ram0d4_2
                SLL     A
                MOV     X1, A
                CMP     A, X1
                JNE     int_break_load_ram0d4_2
                MOV     X2, A
                CMP     A, X2
                JNE     int_break_load_ram0d4_2
                MOV     DP, A
                CMP     A, DP
                JNE     int_break_load_ram0d4_2
                MOV     DP, #0e000h
                MOVB    [DP], #09bh
                MOV     DP, #00086h
int_break_load_dp_ind:     L       A, [DP]
                SB      09fh.7
                MOV     [DP], #05555h
                CMP     [DP], #05555h
                JNE     int_break_load_ram0d4_2
                MOV     [DP], #0aaaah
                CMP     [DP], #0aaaah
                JNE     int_break_load_ram0d4_2
                ST      A, [DP]
                RB      09fh.7
                INC     DP
                INC     DP
                CMP     DP, #0047fh
                JLT     int_break_load_dp_ind
                SJ      int_break_load_dp
int_break_load_ram0d4_2:     MOVB    0d4h, #04ah
                J       fault_retry_check_nop_acc
int_break_load_dp:     MOV     DP, #00300h
                CMPB    [DP], #05ah
                RC
                JNE     int_break_store_carry_ram09f_bit6
                MB      C, SBYCON.7
int_break_store_carry_ram09f_bit6:     MB      09fh.6, C
                JGE     int_break_clear_acc
                MOV     LRB, #00041h
                JBR     off(00233h).0, int_break_goto_6edd
                JBR     off(00233h).1, int_break_goto_6edd
                CMPB    r6, #018h
                JNE     int_break_call_456d
int_break_goto_6edd:     J       int_break_set_ram232_bit6
int_break_clear_dp_ind:     RB      [DP].7
                JNE     int_break_load_dp_3
                MOV     DP, #00348h
                RB      [DP].0
                JNE     int_break_load_dp_2
                SJ      int_break_clear_ram233_bit0
int_break_call_456d:     CAL     dtc_active_confirm_sub_clear_acc
                CAL     dtc_active_confirm_sub_load_dp
int_break_load_dp_2:     MOV     DP, #00332h
                RB      [DP].7
int_break_load_dp_3:     MOV     DP, #00348h
                RB      [DP].0
                CAL     cfgvariant_checksum_calc
                ST      A, [DP]
int_break_clear_ram233_bit0:     RB      off(00233h).0
                RB      off(00233h).1
                CAL     int_break_sub_clear_ram232_bit6
int_break_clear_acc:     CLRB    A
                MB      C, 09fh.1
                ROLB    A
                MB      C, 09eh.0
                ROLB    A
                MB      C, 09eh.5
                ROLB    A
                MB      C, 09fh.6
                ROLB    A
                STB     A, r0
                SRLB    A
                LB      A, 0d4h
                JGE     int_break_store_carry_pswl_bit4
                JEQ     int_break_store_carry_pswl_bit4
                RC
int_break_store_carry_pswl_bit4:     MB      PSWL.4, C
                STB     A, r1
                MOVB    r2, 0d6h
                MOV     DP, #00301h
                MOVB    r3, [DP]
                MOV     DP, #0035eh
                MOV     X1, [DP]
                INC     DP
                INC     DP
                MOV     X2, [DP]
                CLR     A
                MOV     DP, #00090h
                MOV     USP, #00300h
int_break_store_dp_ind:     ST      A, [DP]
                INC     DP
                INC     DP
                CMP     DP, off(00086h)
                JLT     int_break_store_dp_ind
                CMP     USP, #00480h
                JGE     int_break_load_r0
                MOV     USP, #00480h
                JBR     off(PSW).4, int_break_store_dp_ind
                MOV     DP, #00364h
                SJ      int_break_store_dp_ind
int_break_load_r0:     LB      A, r0
                SRLB    A
                MB      09fh.6, C
                SRLB    A
                MB      09eh.5, C
                SRLB    A
                MB      09eh.0, C
                SRLB    A
                MB      09fh.1, C
                LB      A, r1
                STB     A, 0d4h
                STB     A, 0d5h
                JBR     off(SBYCON).7, int_break_load_dp_4
                JNE     int_break_load_dp_4
                LB      A, r3
int_break_load_dp_4:     MOV     DP, #00301h
                STB     A, [DP]
                LB      A, r1
                JBR     off(0009fh).6, int_break_load_r2
                JNE     int_break_load_ram0d6
                JBS     off(0009eh).0, int_break_load_ram0d6
int_break_load_r2:     MOVB    r2, #010h
int_break_load_ram0d6:     MOVB    off(000d6h), r2
                MOVB    0d7h, #001h
                MOV     DP, #0035eh
                L       A, X1
                JBS     off(SBYCON).7, int_break_store_dp_ind_2
                CLR     A
                MOV     X2, A
int_break_store_dp_ind_2:     ST      A, [DP]
                INC     DP
                INC     DP
                L       A, X2
                ST      A, [DP]
                MB      C, 09fh.6
                JGE     int_break_clear_acc_2
                CMPB    0d4h, #04bh
                JEQ     int_break_clear_acc_2
                MOV     X1, #011c1h
int_break_dec_x1:     DEC     X1
                JNE     int_break_dec_x1
                L       A, OS0
                XOR     A, #0ffffh
                MOV     DP, #0032ah
                ST      A, [DP]
                SJ      int_break_load_adsel
int_break_clear_acc_2:     CLRB    A
                CLRB    r0
                MOV     DP, #07ffeh
int_break_rom_load_dp_ind:     LC      A, [DP]
                ADDB    A, ACCH
                ADDB    r0, A
                DEC     DP
                JRNZ    DP, int_break_rom_load_dp_ind
                MOVB    WDT, #03ch
                MOVB    WDT, #0c3h
                LB      A, 085h
                JNE     int_break_rom_load_dp_ind
                LC      A, [DP]
                ADDB    A, ACCH
                ADDB    A, r0
                JEQ     int_break_load_adsel
                LCB     A, 07ff1h
                JEQ     int_break_load_adsel
                MOVB    0d4h, #04bh
                J       fault_retry_check_nop_acc
int_break_load_adsel:     MOVB    ADSEL, #000h
                RB      ADSCAN.4
                MOVB    ADSCAN, #010h
                CLR     DP
int_break_store_carry_r0_bit0:     MB      r0.0, C
                JRNZ    DP, int_break_store_carry_r0_bit0
                CAL     vss_clamp_common_sub_clear_pswh_bit0
                LB      A, 0bbh
                JNE     int_break_store_carry_r0_bit0
                CAL     percyl_counter_gate_sub_load_dp
                LB      A, #020h
                STB     A, STTMR
                STB     A, STTM
                MOVB    SCONA, #080h
                MOVB    SCONB, #080h
                MOVB    SRSTAT, #020h
                LCB     A, 07ff1h
                JNE     int_break_load_dp_5
                LCB     A, 07ff3h
                SJ      int_break_sllb_acc
int_break_load_dp_5:     MOV     DP, #003dfh
                LB      A, [DP]
int_break_sllb_acc:     SLLB    A
                MB      0a0h.7, C
                JLT     int_break_clear_acc_3
                LB      A, #004h
                STB     A, STTMR
                STB     A, STTM
                MOVB    SCONA, #085h
                CLR     A
                CAL     int_break_sub_load_ram07b
                MOVB    SRSTAT, #020h
int_break_clear_acc_3:     CLR     A
                LCB     A, 07ff1h
                MB      C, PSWH.6
                LC      A, 00020h
                JGE     int_break_cmp_acc
                CMP     A, #00094h
                JEQ     int_break_set_ieh_bit4
int_break_cmp_acc:     CMP     A, #int_serial      ; (the stock serial handler: the vector must still point at it)
                JEQ     int_break_set_ieh_bit4
                MOVB    0d4h, #052h
                J       fault_retry_check_nop_acc
int_break_set_ieh_bit4:     SB      IEH.4
                NOP
                CLR     IE
                RB      IRQ.4
                MOV     TIMER, #0fffeh
                DIVB
                NOP
                DIVB
                NOP
                MULB
                NOP
                RB      IRQ.4
                JEQ     int_break_load_ram0d4_3
                L       A, TIMER
                CMP     A, #00006h
                JLT     int_break_load_igna
int_break_load_ram0d4_3:     MOVB    0d4h, #053h
                J       fault_retry_check_nop_acc
int_break_load_igna:     L       A, IGNA
                JNE     int_break_load_ram0d4_4
                L       A, IGNB
                JNE     int_break_load_ram0d4_4
                CMPB    IGNCON, #010h
                JNE     int_break_load_ram0d4_4
                MB      C, P2.2
                JGE     int_break_load_ram0d4_4
                MOV     IGNA, #00003h
                MOV     IGNB, #00007h
                MB      C, P2.2
                JGE     int_break_load_ram0d4_4
                MOV     DP, #00008h
int_break_loop_dp:     JRNZ    DP, int_break_loop_dp
                MB      C, P2.2
                JLT     int_break_load_ram0d4_4
                CMP     IGNA, #0ffffh
                JNE     int_break_load_ram0d4_4
                MOV     DP, #00006h
int_break_loop_dp_2:     JRNZ    DP, int_break_loop_dp_2
                MB      C, P2.2
                JGE     int_break_load_ram0d4_4
                CMP     IGNB, #0ffffh
                JEQ     int_break_load_ram0d4_5
int_break_load_ram0d4_4:     MOVB    0d4h, #054h
                J       fault_retry_check_nop_acc
int_break_load_ram0d4_5:     LB      A, 0d4h
                JEQ     int_break_load_p3
                CMPB    A, #055h
                JNE     int_break_load_lrb
int_break_load_p3:     LB      A, P3
                ANDB    A, #0f0h
                XORB    A, #0f0h
                JNE     int_break_load_ram0d4_6
                L       A, INJ0
                JNE     int_break_load_ram0d4_6
                L       A, INJ1
                JNE     int_break_load_ram0d4_6
                L       A, INJ2
                JNE     int_break_load_ram0d4_6
                L       A, INJ3
                JNE     int_break_load_ram0d4_6
                L       A, #00004h
                ST      A, INJ0
                ST      A, INJ1
                ST      A, INJ2
                ST      A, INJ3
                CMP     A, INJ0
                JLT     int_break_load_ram0d4_6
                CMP     A, INJ1
                JLT     int_break_load_ram0d4_6
                CMP     A, INJ2
                JLT     int_break_load_ram0d4_6
                CMP     A, INJ3
                JLT     int_break_load_ram0d4_6
                LB      A, P3
                ANDB    A, #0f0h
                JNE     int_break_load_ram0d4_6
                MUL
                DIV
                L       A, #0ffffh
                CMP     A, INJ0
                JNE     int_break_load_ram0d4_6
                CMP     A, INJ1
                JNE     int_break_load_ram0d4_6
                CMP     A, INJ2
                JNE     int_break_load_ram0d4_6
                CMP     A, INJ3
                JNE     int_break_load_ram0d4_6
                LB      A, P3
                ANDB    A, #0f0h
                XORB    A, #0f0h
                JEQ     int_break_load_lrb
int_break_load_ram0d4_6:     MOVB    0d4h, #055h
                J       fault_retry_check_nop_acc
int_break_load_lrb:     MOV     LRB, #00041h
                MOV     USP, #00380h
                SB      09fh.6
                JEQ     int_break_load_imm
                LB      A, 0d4h
                JEQ     int_break_load_stk
int_break_load_imm:     L       A, #0ffffh
                ST      A, (00316h-00380h)[USP]
                ST      A, (0031ch-00380h)[USP]
                ST      A, (00322h-00380h)[USP]
                ST      A, (00328h-00380h)[USP]
                L       A, #08000h
                ST      A, (00304h-00380h)[USP]
                ST      A, (00308h-00380h)[USP]
                ST      A, (0030ch-00380h)[USP]
                LC      A, rom_555a
                ST      A, (0030eh-00380h)[USP]
                SB      off(0022ah).7
                MOVB    (0032fh-00380h)[USP], #078h
                CLRB    (0032eh-00380h)[USP]
                NOP
                NOP
                NOP
int_break_load_stk:     MOVB    (00300h-00380h)[USP], #05ah
                MOV     USP, #00180h
                SB      SBYCON.7
                MOV     X2, #00336h
                LB      A, 00000h[X2]
                SLLB    A
                MB      PSWH.6, C
                SLLB    A
                JGE     int_break_andb_tbl_x2
                JNE     int_break_andb_tbl_x2
                CLR     A
                CAL     vcal_4_sub_clear_acc
int_break_andb_tbl_x2:     ANDB    00000h[X2], #03fh
                LB      A, ADCR2H
                STB     A, 0dch
                MOV     DP, #003d0h
                LB      A, [DP]
                STB     A, 0dah
                MOV     DP, #003d7h
                LB      A, [DP]
                STB     A, 0dbh
                MOVB    0d8h, #086h
                MOV     DP, #003dah
                LB      A, [DP]
                MOV     DP, #003a4h
                STB     A, [DP]
                CAL     ect_fault_range_check_sub_load_dp
                MOVB    0d9h, #062h
                MOVB    0e0h, #0f9h
                LB      A, #025h
                STB     A, 0ddh
                STB     A, off(0029eh)
                L       A, ADCR6
                ST      A, 0a4h
                LB      A, ACCH
                MOV     DP, #003a3h
                STB     A, [DP]
                LB      A, #0a0h
                STB     A, off(00288h)
                STB     A, (00178h-00180h)[USP]
                STB     A, 0e1h
                MOV     DP, #003a1h
                STB     A, [DP]
                INC     DP
                STB     A, [DP]
                L       A, #04d00h
                ST      A, 0aah
                ST      A, er0
                SLL     A
                JLT     int_break_load_imm_2
                SLL     A
                LB      A, ACCH
                JGE     clamp_result_store
int_break_load_imm_2:     LB      A, #0ffh
clamp_result_store:     STB     A, 0e8h
                LB      A, r1
                STB     A, 0e7h
                LB      A, 0d4h
                JNE     clamp_result_store_load_ram2e2
                LB      A, #014h
                STB     A, off(002efh)
                STB     A, off(002e1h)
                NOP
                NOP
                NOP
clamp_result_store_load_ram2e2:     MOVB    off(002e2h), #032h
                MOVB    off(0028ch), #078h
                MOVB    off(0028bh), #053h
                MOVB    off(002d0h), #01eh
                MOVB    off(00292h), ADCR3H
                MOVB    off(00293h), #03dh
                MOVB    off(002ebh), #01eh
                MOV     (0016ch-00180h)[USP], #000fah
                MOV     (0016ah-00180h)[USP], #000f4h
                CAL     clamp_result_store_sub_load_dp
                MOV     0ach, #0ffffh
                SB      off(00235h).1
                SB      off(0022ch).1
                SB      off(00235h).7
                RB      off(00215h).0
                LB      A, #0ffh
                STB     A, off(002edh)
                MOVB    off(002cfh), #005h
                NOP
                NOP
                NOP
                MOV     off(0027ch), #00086h
                CAL     vss_clamp_common_sub_load_dp
                MOVB    PWMPRE, #093h
                MOVB    PWM0CON, #003h
                MOVB    PWMIE, #000h
                MOV     PWM1CMP, #09ff6h
                MOVB    PWM1CON, #06fh
                MOV     PWM0CMP, #00001h
                MOVB    0d4h, #063h
                L       A, OS0
                XOR     A, #0ffffh
                MOV     DP, #0032ch
                ST      A, [DP]
                MOV     OS0, #0ffffh
                J       clamp_result_store_nop_acc
calchecksum_loop_nop_acc:     NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                CMP     off(0027ch), #0047eh
                JLE     calchecksum_loop_load_dp
                L       A, #05555h
                CAL     calchecksum_loop_sub_load_x1
                JNE     calchecksum_loop_load_ram0d4
                SLL     A
                CAL     calchecksum_loop_sub_load_x1
                JNE     calchecksum_loop_load_ram0d4
                MOV     off(0027ch), #00086h
calchecksum_loop_load_dp:     MOV     DP, off(0027ch)
                RB      PSWH.0
                MOV     er0, TIMER
                L       A, [DP]
                SB      09fh.7
                MOV     [DP], #05555h
                MOV     X1, [DP]
                MOV     [DP], #0aaaah
                MOV     X2, [DP]
                ST      A, [DP]
                RB      09fh.7
                L       A, TIMER
                MB      C, IRQ.4
                SB      PSWH.0
                MB      PSWL.4, C
                CMP     X1, #05555h
                JNE     calchecksum_loop_load_ram0d4
                CMP     X2, #0aaaah
                JEQ     calchecksum_loop_add_ram27c
calchecksum_loop_load_ram0d4:     MOVB    0d4h, #04ah
                J       fault_retry_check_nop_acc
calchecksum_loop_add_ram27c:     ADD     off(0027ch), #00002h
                SUB     A, er0
                JEQ     calchecksum_loop_load_ram0d4_2
                JGE     calchecksum_loop_cmp_acc
                MB      C, PSWL.4
                JGE     calchecksum_loop_load_ram0d4_2
calchecksum_loop_cmp_acc:     CMP     A, #00006h
                JLT     calchecksum_loop_vcal_4
calchecksum_loop_load_ram0d4_2:     MOVB    0d4h, #053h
                J       fault_retry_check_nop_acc
calchecksum_loop_vcal_4:     VCAL    4
                MOV     DP, #003a6h
                MOV     er0, [DP]
                CLR     A
                LB      A, #040h
                MUL
                MOV     X1, A
                MOV     DP, #00020h
                MOV     X2, #003a8h
                MOVB    r0, 00000h[X2]
calchecksum_loop_rom_load_tbl_x1:     LC      A, [X1]
                ADDB    A, ACCH
                ADDB    r0, A
                INC     X1
                INC     X1
                JRNZ    DP, calchecksum_loop_rom_load_tbl_x1
                LB      A, r0
                STB     A, 00000h[X2]
                MOV     DP, #003a6h
                INC     [DP]
                CMP     [DP], #00200h
                JNE     calchecksum_loop_vcal_4_2
                CLR     [DP]
                LCB     A, 07ff1h
                JEQ     calchecksum_loop_vcal_4_2
                LB      A, r0
                JEQ     calchecksum_loop_vcal_4_2
                CLRB    00000h[X2]
                MOVB    0d4h, #04bh
                J       fault_retry_check_nop_acc
calchecksum_loop_vcal_4_2:     VCAL    4
                RB      PSWH.0
                MB      C, P4SF.4
                JGE     calchecksum_loop_set_pswh_bit0
                L       A, PWM1CNT
                MB      C, P4.4
                MOV     er3, PWM1CNT
                SB      PSWH.0
                MB      PSWL.4, C
                CMP     A, er3
                JEQ     calchecksum_loop_load_r0
                CMP     A, #05ff6h
                JGT     calchecksum_loop_cmp_er3
                CMP     A, #0000ah
                JLT     calchecksum_loop_clear_pswh_bit0
                SB      off(00233h).2
                MB      C, PSWL.4
                JGE     calchecksum_loop_clear_pswh_bit0
                SJ      calchecksum_loop_load_r0
calchecksum_loop_cmp_er3:     CMP     er3, #0a00ah
                JLT     calchecksum_loop_clear_pswh_bit0
                CMP     er3, #0fff6h
                JGT     calchecksum_loop_clear_pswh_bit0
                RB      off(00233h).2
                JEQ     calchecksum_loop_load_carry_pswl_bit4
                MB      C, IRQH.1
                JBR     off(0022eh).2, calchecksum_loop_if_lt_goto_0d88
                RB      IRQH.1
calchecksum_loop_if_lt_goto_0d88:     JLT     calchecksum_loop_load_carry_pswl_bit4
                MOVB    r0, #059h
calchecksum_loop_load_dp_2:     MOV     DP, #0035eh
                ST      A, [DP]
                INC     DP
                INC     DP
                L       A, er3
                ST      A, [DP]
                SJ      calchecksum_loop_load_r0_2
calchecksum_loop_load_carry_pswl_bit4:     MB      C, PSWL.4
                JLT     calchecksum_loop_clear_pswh_bit0
calchecksum_loop_load_r0:     MOVB    r0, #058h
                SJ      calchecksum_loop_load_dp_2
calchecksum_loop_load_r0_2:     LB      A, r0
                CAL     idle_init_start_sub_cmp_ram0d7
                SJ      calchecksum_loop_clear_pswh_bit0
calchecksum_loop_set_pswh_bit0:     SB      PSWH.0
                NOP
calchecksum_loop_clear_pswh_bit0:     RB      PSWH.0
                L       A, PWM0CNT
                MB      C, P4.0
                MOV     er3, PWM0CNT
                SB      PSWH.0
                MB      PSWL.4, C
                CMP     A, er3
                JEQ     calchecksum_loop_load_dp_3
                CMP     A, #007f6h
                JGT     calchecksum_loop_cmp_er3_2
                CMP     A, #0000ah
                JLT     calchecksum_loop_load_ie
                MB      C, PSWL.4
                JGE     calchecksum_loop_load_ie
                SJ      calchecksum_loop_load_dp_3
calchecksum_loop_cmp_er3_2:     CMP     er3, #0f80ah
                JLT     calchecksum_loop_load_ie
                CMP     er3, #0fff6h
                JGT     calchecksum_loop_load_ie
                MB      C, PSWL.4
                JLT     calchecksum_loop_load_ie
calchecksum_loop_load_dp_3:     MOV     DP, #0035eh
                ST      A, [DP]
                INC     DP
                INC     DP
                L       A, er3
                ST      A, [DP]
                LB      A, #05ah
                CAL     idle_init_start_sub_cmp_ram0d7
calchecksum_loop_load_ie:     L       A, IE
                CMP     A, #0141bh
                JNE     calchecksum_loop_load_ram0d4_3
                RB      PSWH.0
                MOV     IE, #05555h
                MOV     X1, IE
                MOV     IE, #0aaaah
                MOV     X2, IE
                ST      A, IE
                SB      PSWH.0
                CMP     X1, #05555h
                JNE     calchecksum_loop_load_ram0d4_3
                CMP     X2, #0aaaah
                JEQ     calchecksum_loop_set_carry
calchecksum_loop_load_ram0d4_3:     MOVB    0d4h, #050h
                J       fault_retry_check
calchecksum_loop_set_carry:     SC
                RB      PSWH.0
                JBS     off(00210h).3, calchecksum_loop_if_ge_goto_0e30
                JBS     off(00214h).7, calchecksum_loop_set_pswh_bit0_2
                RB      TRNSIT.7
                JEQ     calchecksum_loop_set_pswh_bit0_2
                SB      09fh.2
dtc04_ckp_latch_2: SB      09ch.0
calchecksum_loop_set_pswh_bit0_2:     SB      PSWH.0
                CMPB    (001a0h-00180h)[USP], #029h
                RB      PSWH.0
calchecksum_loop_if_ge_goto_0e30:     JGE     calchecksum_loop_if_ram214_bit7_clr
                JBS     off(00214h).7, calchecksum_loop_store_carry_ram214_bit7
                RB      (0011ah-00180h)[USP].7
                RB      off(0021ah).7
                SJ      calchecksum_loop_store_carry_ram214_bit7
calchecksum_loop_if_ram214_bit7_clr:     JBR     off(00214h).7, calchecksum_loop_store_carry_ram214_bit7
                CAL     crank_tooth_count_store_sub_clear_ram0a0_bit6
calchecksum_loop_store_carry_ram214_bit7:     MB      off(00214h).7, C
                MB      TCON.4, C
                SB      PSWH.0
clamp_result_store_nop_acc:     NOP
                NOP
                NOP
                L       A, #05555h
                MB      C, PSWH.4
                JGE     clamp_result_store_load_ram0d4
                MOV     X1, #0aaaah
                CMP     SSP, #0047fh
                JNE     clamp_result_store_load_ram0d4
                RB      PSWH.0
                JEQ     clamp_result_store_load_ram0d4
                MOV     SSP, A
                MOV     A, SSP
                MOV     SSP, X1
                MOV     X1, SSP
                MOV     SSP, #0047fh
                SB      PSWH.0
                JNE     clamp_result_store_load_ram0d4
                CMP     A, #05555h
                JNE     clamp_result_store_load_ram0d4
                XCHG    A, X1
                CMP     A, #0aaaah
                JNE     clamp_result_store_load_ram0d4
                CMP     LRB, #00041h
                JNE     clamp_result_store_load_ram0d4
                RB      PSWH.0
                MOV     LRB, A
                MOV     A, LRB
                MOV     LRB, X1
                MOV     X1, LRB
                MOV     LRB, #00041h
                SB      PSWH.0
                CMP     A, #0aaaah
                JNE     clamp_result_store_load_ram0d4
                SRL     A
                CMP     A, X1
                JNE     clamp_result_store_load_ram0d4
                MOVB    A, PSWL
                MB      C, PSWH.4
                JLT     clamp_result_store_load_ram0d4
                ANDB    A, #007h
                CMPB    A, #000h
                JNE     clamp_result_store_load_ram0d4
                MOVB    PSWL, #055h
                LB      A, PSW
                ANDB    A, #037h
                CMPB    A, #015h
                JNE     clamp_result_store_load_ram0d4
                MOVB    PSWL, #0aah
                LB      A, PSW
                ANDB    A, #037h
                CMPB    A, #022h
                JEQ     clamp_result_store_load_pswl
clamp_result_store_load_ram0d4:     MOVB    0d4h, #046h
                J       fault_retry_check_nop_acc
clamp_result_store_load_pswl:     MOVB    PSWL, #000h
                CMPB    PCLK, #0a4h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, P4SF
                ANDB    A, #0efh
                CMPB    A, #001h
                JNE     clamp_result_store_load_ram0d4_2
                CMPB    P4IO, #011h
                JNE     clamp_result_store_load_ram0d4_2
                CMPB    P3SF, #0f0h
                JNE     clamp_result_store_load_ram0d4_2
                CMPB    P3IO, #0ffh
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, P2A
                ANDB    A, #060h
                CMPB    A, #060h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, P2SF
                ANDB    A, #00eh
                CMPB    A, #006h
                JNE     clamp_result_store_load_ram0d4_2
                CMPB    PWM0CON, #003h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, PWM1CON
                ANDB    A, #0efh
                CMPB    A, #06fh
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, PWMPRE
                CMPB    A, #093h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, TCON
                ANDB    A, #0efh
                CMPB    A, #089h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, TCON2
                ANDB    A, #077h
                CMPB    A, #000h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, IGNCON
                ANDB    A, #0b0h
                CMPB    A, #010h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, ADSCAN
                ANDB    A, #057h
                CMPB    A, #010h
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, ADSEL
                ANDB    A, #04fh
                CMPB    A, #000h
                JEQ     clamp_result_store_load_r0
clamp_result_store_load_ram0d4_2:     MOVB    0d4h, #04eh
                J       fault_retry_check_nop_acc
clamp_result_store_load_r0:     MOVB    r0, #020h
                MOVB    r1, #080h
                MOVB    r2, #080h
                MOVB    r3, #020h
                MB      C, 0a0h.7
                JLT     clamp_result_store_load_sttmr
                MOVB    r0, #004h
                CAL     clamp_result_store_sub_load_r1
                NOP
                MOVB    r3, #020h
clamp_result_store_load_sttmr:     LB      A, STTMR
                CMPB    A, r0
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, SCONA
                ANDB    A, #0f5h
                CMPB    A, r1
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, SCONB
                ANDB    A, #0e5h
                CMPB    A, r2
                JNE     clamp_result_store_load_ram0d4_2
                LB      A, SRSTAT
                ANDB    A, #030h
                CMPB    A, r3
                JNE     clamp_result_store_load_ram0d4_2
                SB      P4.4
                RB      P3.4
                RB      P3.5
                RB      P3.6
                RB      P3.7
                CLR     A
                CLRB    A
                LCB     A, 07ff1h
                STB     A, r1
                JNE     clamp_result_store_load_dp
                LCB     A, 07ff2h
                SJ      clamp_result_store_andb_acc
clamp_result_store_load_dp:     MOV     DP, #003d1h
                LB      A, [DP]
                ADDB    A, #020h
                JGE     clamp_result_store_srlb_acc
                LB      A, #004h
                SJ      clamp_result_store_load_r0_2
clamp_result_store_srlb_acc:     SRLB    A
                SRLB    A
                ANDB    A, #0f0h
                SWAPB
clamp_result_store_load_r0_2:     MOVB    r0, #005h
                MULB
                STB     A, r0
                MOV     DP, #003d9h
                LB      A, [DP]
                ADDB    A, #020h
                JGE     clamp_result_store_srlb_acc_2
                LB      A, #004h
                SJ      clamp_result_store_addb_acc
clamp_result_store_srlb_acc_2:     SRLB    A
                SRLB    A
                ANDB    A, #0f0h
                SWAPB
clamp_result_store_addb_acc:     ADDB    A, r0
                LCB     A, clamp_result_store_tbl_3[ACC]
                CMPB    A, #0ffh
                JNE     clamp_result_store_andb_acc
                MOVB    0d4h, #056h
                J       fault_retry_check_nop_acc
clamp_result_store_andb_acc:     ANDB    A, #03fh
                MOV     DP, #003a9h
                STB     A, [DP]
                SLLB    A
                SLLB    A
                MOV     X1, A
                ADD     X1, #clamp_result_store_tbl_2
                LB      A, r1
                JEQ     clamp_result_store_rom_load_ram7ff3
                MOV     DP, #003d5h
                LB      A, [DP]
                ADDB    A, #020h
                JGE     clamp_result_store_sllb_acc
                LB      A, #080h
clamp_result_store_sllb_acc:     SLLB    A
                MB      PSWL.4, C
                SLLB    A
                SJ      clamp_result_store_rom_load_tbl_x1
clamp_result_store_rom_load_ram7ff3:     LCB     A, 07ff3h
                SRLB    A
                MB      PSWL.4, C
                SRLB    A
                JLT     clamp_result_store_srlb_acc_3
                SC
                JBS     off(00224h).5, clamp_result_store_store_carry_pswl_bit4
                RC
                JBS     off(00214h).0, clamp_result_store_store_carry_pswl_bit4
                MB      C, off(00220h).0
clamp_result_store_store_carry_pswl_bit4:     MB      PSWL.4, C
clamp_result_store_srlb_acc_3:     SRLB    A
clamp_result_store_rom_load_tbl_x1:     LCB     A, 00002h[X1]
                ANDB    A, #05dh
                MB      ACC.6, C
                SRLB    A
                MB      C, PSWL.4
                ROLB    A
                STB     A, r0
                MOVB    r1, #0a2h
                RB      PSWH.0
                LB      A, off(00220h)
                ANDB    A, r1
                ORB     A, r0
                STB     A, off(00220h)
                LB      A, (00120h-00180h)[USP]
                ANDB    A, r1
                ORB     A, r0
                STB     A, (00120h-00180h)[USP]
                SB      PSWH.0
                LCB     A, 00001h[X1]
                ANDB    A, #02fh
                STB     A, r0
                MOVB    r1, #0d0h
                RB      PSWH.0
                LB      A, off(0021fh)
                ANDB    A, r1
                ORB     A, r0
                STB     A, off(0021fh)
                LB      A, (0011fh-00180h)[USP]
                ANDB    A, r1
                ORB     A, r0
                STB     A, (0011fh-00180h)[USP]
                SB      PSWH.0
                LCB     A, 00003h[X1]
                ANDB    A, #007h
                STB     A, r0
                MOVB    r1, #0f8h
                NOP
                RB      PSWH.0
                LB      A, off(00221h)
                ANDB    A, r1
                ORB     A, r0
                STB     A, off(00221h)
                LB      A, (00121h-00180h)[USP]
                ANDB    A, r1
                ORB     A, r0
                STB     A, (00121h-00180h)[USP]
                SB      PSWH.0
                LCB     A, 07ff1h
                JNE     clamp_result_store_load_dp_2
                LCB     A, 07ff3h
                SJ      clamp_result_store_sllb_acc_2
clamp_result_store_load_dp_2:     MOV     DP, #003dfh
                LB      A, [DP]
clamp_result_store_sllb_acc_2:     SLLB    A
                MB      0a0h.7, C
                VCAL    4
                MOVB    r0, #001h
                JBR     off(00214h).7, clamp_result_store_clear_pswh_bit0
                MOVB    r0, #006h
clamp_result_store_clear_pswh_bit0:     RB      PSWH.0
                RB      off(00235h).7
                JBR     off(00216h).0, warmcold_tm2_check
                J       warmcold_tm2_check_nop_acc
warmcold_tm2_check:     JNE     warmcold_tm2_check_set_ram216_bit0
                LB      A, r0
                CMPB    A, 0f7h
                JLT     warmcold_tm2_check_set_ram216_bit0
                JNE     warmcold_tm2_check_goto_1116
                L       A, TIMER
                CMP     A, (00138h-00180h)[USP]
                JGE     warmcold_tm2_check_set_ram216_bit0
warmcold_tm2_check_goto_1116:     J       warmcold_tm2_check_set_pswh_bit0
warmcold_tm2_check_set_ram216_bit0:     SB      off(00216h).0
                CLRB    A
                MOVB    0bch, #000h
                STB     A, 0bdh
                MOVB    (0013ch-00180h)[USP], #003h
                STB     A, (0013dh-00180h)[USP]
                MOVB    (0019dh-00180h)[USP], #004h
                MOV     USP, #00380h
                L       A, #0ffffh
                ST      A, (0037ch-00380h)[USP]
                ST      A, (0037eh-00380h)[USP]
                ST      A, (00380h-00380h)[USP]
                ST      A, 0aeh
                CLR     A
                ST      A, (00370h-00380h)[USP]
                ST      A, (00372h-00380h)[USP]
                ST      A, (00374h-00380h)[USP]
                ST      A, (00376h-00380h)[USP]
                ST      A, (00378h-00380h)[USP]
                ST      A, (0037ah-00380h)[USP]
                MOV     USP, #00180h
                ST      A, (00174h-00180h)[USP]
                ST      A, 0ceh
                ST      A, (00176h-00180h)[USP]
                ST      A, 0d0h
                CLRB    A
                STB     A, off(00289h)
                STB     A, (00179h-00180h)[USP]
                STB     A, 0eah
                STB     A, 0ech
                STB     A, 0edh
                STB     A, 0eeh
                STB     A, 0efh
                RB      P3.3
                CAL     crank_tooth_count_store_sub_clear_ram0a0_bit6
                MOVB    0c4h, #005h
                CLRB    0c5h
                SB      (00132h-00180h)[USP].1
                MOVB    0e2h, #0a0h
                CLRB    off(00298h)
                RB      off(00232h).3
                RB      off(00230h).5
                MOVB    off(0029ch), #003h
                CLRB    off(00238h)
                CLR     A
                ST      A, (0011ah-00180h)[USP]
                ST      A, off(0021ah)
                CLRB    A
                STB     A, (00127h-00180h)[USP]
                STB     A, (00128h-00180h)[USP]
                STB     A, (00129h-00180h)[USP]
                SB      09fh.5
                SB      ADSCAN.5
                J       warmcold_tm2_check_set_ram09f_bit4
warmcold_tm2_check_store_ram294:     STB     A, off(00294h)
                RB      P4SF.4
                MOV     off(0026eh), #00000h
                RB      0a0h.2
                MOVB    P4, #011h
                ANDB    off(00226h), #03fh
warmcold_tm2_check_nop_acc:     NOP
                NOP
                NOP
warmcold_tm2_check_set_pswh_bit0:     SB      PSWH.0
                SC
                JBS     off(00216h).0, warmcold_tm2_check_store_carry_ram216_bit1
                JBS     off(00214h).0, warmcold_tm2_check_load_imm
                JBR     off(00216h).1, warmcold_tm2_check_load_ram2df
warmcold_tm2_check_load_imm:     L       A, #0124fh
                JBS     off(00216h).1, warmcold_tm2_check_cmp_acc
                L       A, #01d4ch
warmcold_tm2_check_cmp_acc:     CMP     A, 0aeh
warmcold_tm2_check_store_carry_ram216_bit1:     MB      off(00216h).1, C
                JGE     warmcold_tm2_check_load_ram2df
                JBR     off(00214h).0, warmcold_msec_reset
                SB      off(00233h).4
warmcold_msec_reset:     ANDB    098h, #062h
                ANDB    099h, #085h
                ANDB    09ah, #00bh
                ANDB    09bh, #004h
                CLRB    A
                STB     A, 0ffh
                STB     A, 0feh
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                JBR     off(00216h).0, warmcold_tm2_check_if_ram220_bit0_clr
warmcold_tm2_check_load_ram2df:     MOVB    off(002dfh), #063h
warmcold_tm2_check_if_ram220_bit0_clr:     JBR     off(00220h).0, warmcold_tm2_check_load_adcr5h
                RB      off(0022ah).7
                JEQ     warmcold_tm2_check_load_adcr5h
                CLR     A
                LC      A, rom_5558
                MOV     DP, #0030eh
                ST      A, [DP]
warmcold_tm2_check_load_adcr5h:     LB      A, ADCR5H
                STB     A, r0
                CMPB    A, #004h
                JLT     warmcold_tm2_check_store_carry_ram22f_bit3
                LB      A, #0ffh
                CMPB    A, r0
warmcold_tm2_check_store_carry_ram22f_bit3:     MB      off(0022fh).3, C
                CMPB    r0, #004h
                JLT     warmcold_tm2_check_store_carry_ram22f_bit4
                LB      A, #0f6h
                CMPB    A, r0
warmcold_tm2_check_store_carry_ram22f_bit4:     MB      off(0022fh).4, C
                JBS     off(00215h).0, warmcold_tm2_check_if_ram221_bit0_clr
                L       A, 0aeh
                CMPC    A, warmcold_tm2_check_load_imm+1
                NOP
                JGE     warmcold_tm2_check_load_imm_2
                JBS     off(0022fh).3, warmcold_tm2_check_load_imm_2
                JBR     off(00224h).3, warmcold_tm2_check_load_ram2fe
warmcold_tm2_check_load_imm_2:     LB      A, #0ffh
                STB     A, off(002feh)
                SJ      warmcold_tm2_check_if_ram221_bit0_clr
warmcold_tm2_check_load_ram2fe:     LB      A, off(002feh)
                JNE     warmcold_tm2_check_if_ram221_bit0_clr
                SB      off(00215h).0
warmcold_tm2_check_if_ram221_bit0_clr:     JBR     off(00221h).0, warmcold_tm2_check_clear_carry
                MB      C, off(00227h).5
                JBS     off(0021ah).1, warmcold_tm2_check_load_ram2dd
                MOVB    off(002dch), #014h
                LB      A, off(002ddh)
                JLT     warmcold_tm2_check_if_ram212_bit4_set
warmcold_tm2_check_clear_carry:     RC
                SJ      dtc21_vtec_solenoid_latch
warmcold_tm2_check_load_ram2dd:     MOVB    off(002ddh), #014h
                LB      A, off(002dch)
                JLT     warmcold_tm2_check_clear_carry
warmcold_tm2_check_if_ram212_bit4_set:     JBS     off(00212h).4, warmcold_tm2_check_clear_carry
                SC
dtc21_vtec_solenoid_latch:     MB      09ah.0, C
                JBR     off(00221h).0, altvtec_vtps_result
                JNE     altvtec_vtps_result
                JBS     off(00212h).4, altvtec_vtps_result
                JLT     altvtec_vtps_result
                JBS     off(00212h).5, altvtec_vtps_result
                MB      C, off(00227h).4
                JBR     off(0021ah).1, dtc22_vtec_pressure_latch
                JLT     altvtec_vtps_result
                SC
                SJ      dtc22_vtec_pressure_latch
altvtec_vtps_result:     RC
dtc22_vtec_pressure_latch:     MB      09ah.1, C
                CMPB    off(00289h), #0c8h
                JGE     autotrans_gate_start_load_ram2eb
                LB      A, off(00294h)
                JEQ     autotrans_gate_start_load_ram2eb_2
autotrans_gate_start_load_ram2eb:     MOVB    off(002ebh), #01eh
autotrans_gate_start_load_ram2eb_2:     LB      A, off(002ebh)
                JNE     ect_step_store_if_ram210_bit2_set
                LB      A, off(00292h)
                MOVB    r0, #05ch
                CMPB    A, r0
                JGE     dwell_scale_default
                MOVB    r0, #031h
                CMPB    A, r0
                JGE     ect_step_store
dwell_scale_default:     LB      A, r0
ect_step_store:     STB     A, off(00293h)
ect_step_store_if_ram210_bit2_set:     JBS     off(00210h).2, sensor_check_clear
                JBS     off(00210h).4, sensor_check_clear
                MB      C, 09eh.5
                JLT     sensor_check_clear
                CMPB    off(00289h), #002h
                JGE     ect_step_store_if_ram233_bit4_clr
                MOVB    off(002dbh), #032h
ect_step_store_if_ram233_bit4_clr:     JBR     off(00233h).4, sensor_check_clear
                MOV     DP, #003a3h
                LB      A, [DP]
                SUBB    A, ADCR6H
                JGE     sensor_check_result
                VCAL    7
sensor_check_result:     CMPB    A, #002h
                JGE     sensor_check_result_set_ram09e_bit5
                LB      A, off(002dbh)
                JEQ     dtc05_map_range_latch
sensor_check_clear:     RC
                SJ      dtc05_map_range_latch
sensor_check_result_set_ram09e_bit5:     SB      09eh.5
dtc05_map_range_latch:     MB      098h.3, C
                RC
                JBS     off(00210h).7, dtc08_tdc_latch
                JBR     off(00216h).0, dtc08_tdc_latch
                MB      C, off(00214h).0
                JBR     off(00220h).0, dtc08_tdc_latch
                JGE     dtc08_tdc_latch
                MB      C, off(00224h).5
dtc08_tdc_latch:     MB      098h.5, C
                VCAL    4
                MOV     DP, #003dah
                LB      A, [DP]
                STB     A, r1
                RC
                JBS     off(00210h).5, dtc06_ect_latch
                LB      A, #0fch
                CMPB    A, r1
                JLT     dtc06_ect_latch
                LB      A, r1
                CMPB    A, #004h
dtc06_ect_latch:     MB      098h.1, C
                JBS     off(00210h).5, ect_simulate_ramp
                JLT     ect_simulate_ramp_load_ram0d9
                JBS     off(00224h).2, ect_fault_range_check_load_dp
                MOV     DP, #003a4h
                SUBB    A, [DP]
                JGE     ect_fault_delta_check
                VCAL    7
ect_fault_delta_check:     CMPB    A, #002h
                JGT     ect_fault_delta_check_load_r1
                LB      A, off(002deh)
                JNE     ect_simulate_ramp_load_ram0d9_2
                LB      A, r1
                JBS     off(00216h).0, ect_fault_range_check_load_dp
                MOV     DP, #003a5h
                CMPB    A, [DP]
                JGT     ect_simulate_ramp_load_ram2de
                SJ      ect_fault_range_check_load_dp
ect_simulate_ramp:     JBR     off(00216h).1, ect_simulate_ramp_load_ram0d9
                CLR     A
                LB      A, off(002dfh)
                MOVB    r0, #014h
                DIVB
                MOV     DP, #tbl_ect_simulate_ramp
                ADD     DP, A
                LCB     A, [DP]
                STB     A, 0d9h
                SJ      ect_simulate_ramp_load_ram2de
ect_simulate_ramp_load_ram0d9:     MOVB    0d9h, #062h
                SJ      ect_simulate_ramp_load_ram2de
ect_fault_range_check_load_dp:     MOV     DP, #000d9h
                CAL     ect_smooth_helper
                CAL     ect_fault_range_check_sub_load_dp
                MOV     DP, #003a4h
ect_fault_delta_check_load_r1:     LB      A, r1
                STB     A, [DP]
ect_simulate_ramp_load_ram2de:     MOVB    off(002deh), #005h
ect_simulate_ramp_load_ram0d9_2:     LB      A, 0d9h
                MOV     X1, #rom_5086
                MOV     X2, #rom_5094
                CMPB    A, #028h
                JLT     ect_simulate_ramp_store_carry_ram230_bit6
                MOV     X1, #rom_50a2
                MOV     X2, #rom_50b0
ect_simulate_ramp_store_carry_ram230_bit6:     MB      off(00230h).6, C
                VCAL    0
                STB     A, r3
                MOV     X1, X2
                LB      A, 0d9h
                VCAL    0
                STB     A, r2
                MOV     off(00278h), er1
                LB      A, 0d9h
                MOV     X1, #rom_5072
                VCAL    0
                STB     A, off(002b1h)
                JBR     off(0021fh).0, overrev_hardcap_compare_load_ram2ce
                LB      A, #07dh
                JBS     off(00220h).0, overrev_hardcap_compare
                LB      A, #073h
overrev_hardcap_compare:     CMPB    A, off(00289h)
                JLT     overrev_hardcap_compare_load_ram2ce
                LB      A, 0dfh
                CMPB    A, #032h
                JGE     overrev_hardcap_compare_load_ram2ce
                CMPB    A, #01eh
                JLT     overrev_hardcap_compare_load_ram2ce
                CMPB    0d9h, #000h
                JGE     overrev_hardcap_compare_load_ram2ce
                CMPB    off(00288h), #064h
                JGE     overrev_hardcap_compare_load_ram2ce
                J       overrev_hardcap_compare_if_ram216_bit6_set
overrev_hardcap_compare_cmp_ram2ce:     CMPB    off(002ceh), #0b4h
                JGE     overrev_hardcap_compare_vcal_4
                MOVB    r0, #000h
                LB      A, off(002ceh)
                JEQ     overrev_hardcap_compare_load_ram29a
                MOV     off(0029ah), #00100h
                SJ      overrev_hardcap_compare_load_r0
overrev_hardcap_compare_load_ram2ce:     MOVB    off(002ceh), #0f0h
                CLRB    r0
                SJ      overrev_hardcap_compare_clear_carry
overrev_hardcap_compare_load_ram29a:     L       A, off(0029ah)
                JNE     overrev_hardcap_compare_store_carry_ram230_bit3
overrev_hardcap_compare_clear_carry:     RC
overrev_hardcap_compare_store_carry_ram230_bit3:     MB      off(00230h).3, C
overrev_hardcap_compare_load_r0:     LB      A, r0
                VCAL    7
                STB     A, off(002afh)
overrev_hardcap_compare_vcal_4:     VCAL    4
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #rom_51c1
                VCAL    0
                STB     A, (0017ah-00180h)[USP]
                LB      A, r2
                MOV     X1, #rom_51cf
                VCAL    0
                STB     A, (0017bh-00180h)[USP]
                LB      A, r2
                MOV     X1, #rom_51dd
                VCAL    0
                STB     A, (0017ch-00180h)[USP]
                LB      A, r2
                MOV     X1, #rom_51eb
                VCAL    0
                STB     A, (0017dh-00180h)[USP]
                LB      A, r2
                MOV     X1, #rom_51f9
                VCAL    0
                STB     A, (0017eh-00180h)[USP]
                VCAL    4
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #rom_5207
                VCAL    0
                STB     A, (0017fh-00180h)[USP]
                LB      A, r2
                MOV     X1, #rom_534a
                VCAL    0
                STB     A, (00185h-00180h)[USP]
                LB      A, r2
                MOV     X1, #rom_5356
                VCAL    0
                STB     A, (00187h-00180h)[USP]
                LB      A, r2
                MOV     X1, #rom_5364
                VCAL    0
                STB     A, (00188h-00180h)[USP]
                LB      A, r2
                MOV     X1, #overrev_hardcap_compare_tbl_4
                VCAL    0
                STB     A, (00194h-00180h)[USP]
                VCAL    4
                L       A, off(00210h)
                AND     A, #0c3bch
                SC
                JNE     overrev_hardcap_compare_store_carry_ram232_bit4
                MB      C, off(00212h).5
overrev_hardcap_compare_store_carry_ram232_bit4:     MB      off(00232h).4, C
                MOVB    r0, #004h
                MOV     DP, #tbl_map_sign
                LB      A, 0d9h
overrev_hardcap_compare_dec_dp:     DEC     DP
                DECB    r0
                JEQ     overrev_hardcap_compare_clear_pswh_bit0
                CMPCB   A, [DP]
                JGE     overrev_hardcap_compare_dec_dp
overrev_hardcap_compare_clear_pswh_bit0:     RB      PSWH.0
                LB      A, off(00223h)
                ANDB    A, #0fch
                ORB     A, r0
                STB     A, off(00223h)
                SB      PSWH.0
                RC
                JBS     off(00212h).6, dtc23_knock_latch
                JBS     off(00238h).0, dtc23_knock_latch
                L       A, off(00210h)
                AND     A, #0c3bch
                JNE     dtc23_knock_latch
                JBS     off(00212h).5, dtc23_knock_latch
                LB      A, off(002fdh)
                JEQ     dtc23_knock_latch
                JBS     off(00238h).1, dtc23_knock_latch
                MB      C, off(00238h).2
dtc23_knock_latch:     MB      09ah.2, C
                LB      A, 0d9h
                MOV     X1, #rom_528b
                CMPCB   A, 00002h[X1]
                MB      off(00218h).7, C
                VCAL    0
                STB     A, (00199h-00180h)[USP]
                CMPB    off(00289h), #0ech
                JGE     overrev_hardcap_compare_load_x1
                MOVB    (001dch-00180h)[USP], #096h
overrev_hardcap_compare_load_x1:     MOV     X1, #overrev_hardcap_compare_tbl_3
                LB      A, 0d9h
                VCAL    1
                STB     A, (001b0h-00180h)[USP]
                MOV     X1, #rom_545f
                JBR     off(00220h).0, overrev_hardcap_compare_load_ram0d9
                MOV     X1, #rom_547a
overrev_hardcap_compare_load_ram0d9:     LB      A, 0d9h
                VCAL    1
                STB     A, off(00260h)
                VCAL    4
                MOV     X1, #rom_54cb
                JBR     off(00220h).0, overrev_hardcap_compare_load_ram0d9_2
                MOV     X1, #rom_54e6
overrev_hardcap_compare_load_ram0d9_2:     LB      A, 0d9h
                VCAL    1
                STB     A, off(00262h)
                MOV     X1, #overrev_hardcap_compare_tbl
                JBR     off(00220h).0, overrev_hardcap_compare_load_ram0d9_3
                MOV     X1, #overrev_hardcap_compare_tbl_2
overrev_hardcap_compare_load_ram0d9_3:     LB      A, 0d9h
                VCAL    1
                STB     A, off(00264h)
                MOV     X1, #rom_55da
                LB      A, 0d9h
                VCAL    1
                STB     A, off(0023eh)
                VCAL    4
                L       A, off(00210h)
                AND     A, #02074h
                JNE     overrev_hardcap_compare_set_ram216_bit2
                J       overrev_hardcap_compare_if_ram212_bit0_set
overrev_hardcap_compare_if_ram216_bit1_set:     JBS     off(00216h).1, overrev_hardcap_compare_cmp_ram0d8
                JBR     off(00220h).0, overrev_hardcap_compare_if_ram216_bit5_set
                JBR     off(00224h).5, overrev_hardcap_compare_set_ram216_bit2
overrev_hardcap_compare_if_ram216_bit5_set:     JBS     off(00216h).5, overrev_hardcap_compare_set_ram216_bit2
                CMPB    off(00289h), #090h
                JGE     overrev_hardcap_compare_set_ram216_bit2
                LB      A, #032h
                JBR     off(00239h).6, overrev_hardcap_compare_cmp_acc
                LB      A, #064h
overrev_hardcap_compare_cmp_acc:     CMPB    A, 0ffh
                JGE     overrev_hardcap_compare_load_x1_2
                CMPB    0d9h, #03ch
                JLT     overrev_hardcap_compare_set_ram216_bit2
                SJ      overrev_hardcap_compare_load_x1_2
overrev_hardcap_compare_cmp_ram0d8:     CMPB    0d8h, #030h
                MB      off(00239h).6, C
                RB      off(00216h).2
                SJ      overrev_hardcap_compare_load_x1_2
overrev_hardcap_compare_set_ram216_bit2:     SB      off(00216h).2
overrev_hardcap_compare_load_x1_2:     MOV     X1, #rom_5532
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram0d9_4
                JBR     off(00220h).2, overrev_hardcap_compare_cmp_ram0d9
code_1458:      CMPB    0d9h, #036h
                JGE     overrev_hardcap_compare_cmp_ram0d9
                LB      A, #070h
                JBS     off(00239h).4, overrev_hardcap_compare_cmp_ram0dd
                LB      A, #030h
overrev_hardcap_compare_cmp_ram0dd:     CMPB    0ddh, A
                MB      off(00239h).4, C
                JLT     overrev_hardcap_compare_load_imm
overrev_hardcap_compare_cmp_ram0d9:     CMPB    0d9h, #02eh
                JGE     overrev_hardcap_compare_load_x1_3
                L       A, #00a77h
                JBR     off(00220h).0, overrev_hardcap_compare_clear_er3
                JBS     off(00224h).5, overrev_hardcap_compare_clear_er3
overrev_hardcap_compare_load_x1_3:     MOV     X1, #rom_551d
overrev_hardcap_compare_load_ram0d9_4:     LB      A, 0d9h
                VCAL    1
overrev_hardcap_compare_clear_er3:     CLR     er3
                SJ      overrev_hardcap_compare_store_ram286
overrev_hardcap_compare_load_imm:     L       A, #00945h
                MOV     er3, #00200h
overrev_hardcap_compare_store_ram286:     ST      A, off(00286h)
                MOV     off(0026ah), er3
                MOV     X1, #rom_550f
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram0d9_5
                MOV     X1, #rom_5501
overrev_hardcap_compare_load_ram0d9_5:     LB      A, 0d9h
                VCAL    0
                STB     A, off(00295h)
                L       A, off(00264h)
                MOV     DP, #0030eh
                SUB     A, [DP]
                JLT     overrev_hardcap_compare_clear_acc
                MOVB    r1, off(00299h)
                SUBB    r1, #080h
                JLT     overrev_hardcap_compare_clear_acc
                CLRB    r0
                MUL
                SLL     A
                L       A, er1
                ROL     A
                SJ      overrev_hardcap_compare_store_ram266
overrev_hardcap_compare_clear_acc:     CLR     A
overrev_hardcap_compare_store_ram266:     ST      A, off(00266h)
                MOV     X1, #rom_5495
                JBR     off(00220h).0, vemapscalar_gate
                MOV     X1, #rom_54b0
vemapscalar_gate:     LB      A, 0d9h
                VCAL    1
                STB     A, off(00268h)
                VCAL    4
                MOV     DP, #0030eh
                L       A, [DP]
                CMPC    A, rom_5554
                JLT     vemapscalar_gate_rom_load_ram555a
                CMPC    A, rom_5556
                JLE     vemapscalar_gate_store_dp_ind
vemapscalar_gate_rom_load_ram555a:     LC      A, rom_555a
                JBR     off(00220h).0, vemapscalar_gate_store_dp_ind
                LC      A, rom_5558
vemapscalar_gate_store_dp_ind:     ST      A, [DP]
                MOV     X1, #rom_5397
                JBR     off(00220h).0, vemapscalar_gate_load_ram0d9
                MOV     X1, #rom_53a5
vemapscalar_gate_load_ram0d9:     LB      A, 0d9h
                VCAL    0
                STB     A, r2
                MOV     X1, #rom_53b3
                JBR     off(00220h).0, vemapscalar_gate_load_ram0d9_2
                MOV     X1, #rom_53c1
vemapscalar_gate_load_ram0d9_2:     LB      A, 0d9h
                VCAL    0
                STB     A, ACCH
                LB      A, r2
                MOV     (0016eh-00180h)[USP], A
                JBS     off(00212h).0, vemapscalar_gate_clear_acc
                LB      A, (001f4h-00180h)[USP]
                JNE     vemapscalar_gate_vcal_4
                MOVB    (001f4h-00180h)[USP], #00ah
                LB      A, #0a3h
                JBS     off(0022ah).1, vemapscalar_gate_cmp_acc
                LB      A, #0e0h
vemapscalar_gate_cmp_acc:     CMPB    A, off(00289h)
                MB      off(0022ah).1, C
                JGE     vemapscalar_gate_load_ram2d0
                LB      A, #065h
                JBS     off(00218h).5, vemapscalar_gate_cmp_ram0d9
                LB      A, #061h
vemapscalar_gate_cmp_ram0d9:     CMPB    0d9h, A
                MB      off(00218h).5, C
                JGE     vemapscalar_gate_load_ram2d0
                LB      A, off(002d0h)
                JNE     vemapscalar_gate_load_stk
                L       A, (0016ch-00180h)[USP]
                MOV     X1, #revlimit_p2_reset_540b
                MOV     X2, #revlimit_p2_set_540f
                J       vemapscalar_gate_if_ram212_bit5_set
vemapscalar_gate_load_x1:     MOV     X1, #revlimit_p1_reset_5403
                MOV     X2, #revlimit_p1_set_5407
vemapscalar_gate_call_add24_clamp_neg1:     CAL     add24_clamp_neg1
                MOV     DP, A
                L       A, (0016ah-00180h)[USP]
                MOV     X1, X2
                CAL     add24_clamp_neg1
                SJ      vemapscalar_gate_clear_pswh_bit0
vemapscalar_gate_clear_acc:     CLR     A
                LC      A, revlimit_p1_reset_5403
                MOV     DP, A
                LC      A, revlimit_p1_set_5407
                SJ      vemapscalar_gate_clear_pswh_bit0
vemapscalar_gate_load_ram2d0:     MOVB    off(002d0h), #01eh
vemapscalar_gate_load_stk:     L       A, (0016ch-00180h)[USP]
                MOV     X1, #revlimit_p2_reset_540b
                MOV     X2, #revlimit_p2_set_540f
                J       vemapscalar_gate_if_ram212_bit5_set_2
vemapscalar_gate_load_x1_2:     MOV     X1, #revlimit_p1_reset_5403
                MOV     X2, #revlimit_p1_set_5407
vemapscalar_gate_call_4977:     CAL     vemapscalar_gate_sub_sub_acc
                MOV     DP, A
                L       A, (0016ah-00180h)[USP]
                MOV     X1, X2
                CAL     vemapscalar_gate_sub_sub_acc
vemapscalar_gate_clear_pswh_bit0:     RB      PSWH.0
                ST      A, (0016ah-00180h)[USP]
                L       A, DP
                ST      A, (0016ch-00180h)[USP]
                SB      PSWH.0
vemapscalar_gate_vcal_4:     VCAL    4
                JBR     off(00220h).3, sensor_bank_stamp_bc
                JBR     off(00211h).4, sensor_bank_bc_alt
sensor_bank_stamp_bc:     MOVB    0e0h, #0f9h
                SJ      dcode14_return
sensor_bank_bc_alt:     CLR     A
                LB      A, #0e6h
                MOV     DP, #003d3h
                CMPB    A, [DP]
                JLT     dtc13_baro_latch
                LB      A, [DP]
                CMPB    A, #050h
                JLT     dtc13_baro_latch
                CAL     subtract24_clamp_byte
                MOV     DP, #000e0h
                CAL     ect_smooth_helper
dcode14_return:     RC
dtc13_baro_latch:     MB      099h.2, C
                LB      A, 0e0h
                MOV     X1, #rom_52e3
                VCAL    0
                STB     A, (00189h-00180h)[USP]
                LB      A, 0e0h
                MOV     X1, #rom_5346
                VCAL    2
                STB     A, (00186h-00180h)[USP]
                LB      A, 0e0h
                MOV     X1, #rom_5287
                VCAL    2
                STB     A, (0019ah-00180h)[USP]
                MOV     X1, #dcode14_check_tbl
                LB      A, 0e0h
                VCAL    2
                STB     A, off(00299h)
                MOV     X1, #rom_53ff
                LB      A, 0e0h
                VCAL    2
                STB     A, (00197h-00180h)[USP]
                VCAL    4
                JBR     off(00211h).1, iat_range_check
                MOVB    0d8h, #086h
                SJ      iat_check_return
iat_range_check:     LB      A, #0fch
                MOV     DP, #003d2h
                CMPB    A, [DP]
                JLT     dtc10_iat_latch
                LB      A, [DP]
                CMPB    A, #004h
                JLT     dtc10_iat_latch
                MOV     DP, #000d8h
                CAL     ect_smooth_helper
iat_check_return:     RC
dtc10_iat_latch:     MB      098h.6, C
                LB      A, 0d8h
                CMPB    A, #028h
                MB      off(00223h).2, C
                LB      A, 0d8h
                MOV     X1, #rom_5215
                VCAL    1
                STB     A, (00152h-00180h)[USP]
                LB      A, #000h
                JBS     off(00230h).4, sensor_bank_gate3_cmp_acc
                LB      A, #001h
sensor_bank_gate3_cmp_acc:     CMPB    A, off(00289h)
                MB      off(00230h).4, C
                J       sensor_bank_gate3_clear_acc
sensor_bank_gate3_if_ram211_bit1_set:     JBS     off(00211h).1, sensor_bank_gate3_store_ram280
                CMPB    off(00288h), #000h
                JLE     sensor_bank_gate3_store_ram280
                LB      A, 0d8h
                MOV     X1, #sensor_bank_gate3_tbl
                CAL     sensor_bank_gate3_sub_vcal_0
                VCAL    0
                STB     A, r2
                L       A, er1
sensor_bank_gate3_store_ram280:     ST      A, off(00280h)
                LB      A, 0d8h
                MOV     X1, #sensor_bank_gate3_tbl_4
                VCAL    2
                STB     A, off(002cbh)
                MOV     X1, #rom_55c1
                LB      A, 0d8h
                VCAL    1
                STB     A, off(00242h)
                VCAL    4
                LB      A, #044h
                CMPB    A, 0dbh
                JGE     dtc17_vss_latch
                CMPB    off(00289h), #0c0h
                JGE     dtc17_vss_latch
                RC
                JBS     off(00212h).0, dtc17_vss_latch
                JBR     off(00235h).5, dtc17_vss_latch
                MB      C, off(0021ah).2
dtc17_vss_latch:     MB      099h.4, C
                CLRB    A
                JBS     off(00220h).0, sensor_bank_gate3_store_ram2a4
                JBS     off(00216h).1, sensor_bank_gate3_store_ram2a4
                JBS     off(00212h).0, sensor_bank_gate3_store_ram2a4
                MOVB    r1, 0dfh
                CLRB    r0
                L       A, 0aeh
                MUL
                LB      A, r3
                JEQ     sensor_bank_gate3_load_r2
                MOVB    r2, #0ffh
sensor_bank_gate3_load_r2:     LB      A, r2
                CLR     X1
                MOV     DP, #00004h
sensor_bank_gate3_cmp_acc_2:     CMPCB   A, rom_545b[X1]
                JLT     sensor_bank_gate3_load_dp
                INC     X1
                JRNZ    DP, sensor_bank_gate3_cmp_acc_2
sensor_bank_gate3_load_dp:     L       A, DP
                LB      A, ACC
sensor_bank_gate3_store_ram2a4:     STB     A, off(002a4h)
                LCB     A, rom_5176[ACC]
                STB     A, off(002a5h)
                JBS     off(0021bh).7, sensor_bank_gate3_clear_carry
                JBS     off(00210h).3, sensor_bank_gate3_clear_carry
                JBS     off(0021eh).1, sensor_bank_gate3_clear_carry
                JBS     off(00225h).6, sensor_bank_gate3_clear_carry
                MB      C, 099h.3
                JLT     sensor_bank_gate3_if_ram21a_bit4_set
                JBR     off(00211h).5, sensor_bank_gate3_if_ram217_bit0_set
sensor_bank_gate3_if_ram21a_bit4_set:     JBS     off(0021ah).4, sensor_bank_gate3_clear_carry
sensor_bank_gate3_if_ram217_bit0_set:     JBS     off(00217h).0, sensor_bank_gate3_clear_carry
                J       sensor_bank_gate3_if_ram216_bit1_set
sensor_bank_gate3_load_imm:     L       A, #0bc30h
                CMP     A, (00160h-00180h)[USP]
                JLT     sensor_bank_gate3_store_carry_ram09d_bit7
                CMP     (00160h-00180h)[USP], #05d80h
                JLT     sensor_bank_gate3_store_carry_ram09d_bit7
sensor_bank_gate3_clear_carry:     RC
sensor_bank_gate3_store_carry_ram09d_bit7:     MB      09dh.7, C
                MOV     DP, #00304h
fueltbl_sanitize_check:     JBR     off(0021fh).0, fueltbl_range_check
                MB      C, 0a0h.0
                JLT     fueltbl_default_value
fueltbl_range_check:     CMP     [DP], #09a99h
                JGT     fueltbl_default_value
                CMP     [DP], #06566h
                JGE     fueltbl_sanitize_advance
fueltbl_default_value:     MOV     [DP], #08000h
fueltbl_sanitize_advance:     ADD     DP, #00004h
                CMP     DP, #00310h
                JLT     fueltbl_sanitize_check
                VCAL    4
                MOV     X1, #rom_523f
                LB      A, 0dfh
                CMPB    A, #00fh
                JLT     fueltbl_sanitize_advance_load_ram0d8
                MOV     X1, #rom_5243
fueltbl_sanitize_advance_load_ram0d8:     LB      A, 0d8h
                VCAL    2
                CMPB    0d9h, A
                MB      off(00218h).2, C
                JBR     off(0021eh).1, fueltbl_sanitize_advance_if_ram22f_bit5_set
                SB      off(00218h).0
                RB      off(00218h).1
                J       injidx_flag_clear_set_ram22e_bit3
fueltbl_sanitize_advance_if_ram22f_bit5_set:     JBS     off(0022fh).5, injidx_flag_clear
                JBS     off(00218h).3, injidx_flag_clear
                JBS     off(0021dh).0, injidx_flag_clear
                LB      A, off(002e2h)
                JEQ     fueltbl_sanitize_advance_if_ram216_bit1_set
                RB      off(00218h).0
                RB      off(00218h).1
fueltbl_sanitize_advance_clear_ram22e_bit3:     RB      off(0022eh).3
                MOVB    off(002d8h), #064h
                SJ      vss_ect_gate_load_ram2d4
fueltbl_sanitize_advance_if_ram216_bit1_set:     JBS     off(00216h).1, fueltbl_sanitize_advance_clear_ram22e_bit3
                JBS     off(00218h).0, vss_ect_gate
                JBR     off(00218h).1, fueltbl_sanitize_advance_if_ram218_bit0_set
                JBR     off(0021bh).2, vss_ect_gate
                RB      off(00218h).1
                SB      off(0022eh).3
fueltbl_sanitize_advance_if_ram218_bit0_set:     JBS     off(00218h).0, closeloopnarrow_check
                JBS     off(00218h).1, closeloopnarrow_check
                JBS     off(0022eh).3, closeloopnarrow_check
                JBR     off(0022ah).0, injidx_stamp_c2
                JBR     off(00218h).2, injidx_stamp_c2
                JBS     off(0021bh).2, injidx_c2_check
injidx_stamp_c2:     MOVB    off(002d8h), #064h
                SJ      closeloopnarrow_check
injidx_c2_check:     LB      A, off(002d8h)
                JNE     closeloopnarrow_check
                LB      A, #02eh
                SJ      closeloopnarrow_result
closeloopnarrow_check:     LB      A, #019h
closeloopnarrow_result:     CMPB    A, 0dah
                JLT     vss_ect_gate
                SB      off(00218h).0
vss_ect_gate:     CMPB    0d9h, #028h
                JGE     vss_ect_gate_load_ram2d4
                CMPB    0dfh, #005h
                JGE     vss_ect_gate_load_ram2d4
                CMPB    off(00289h), #080h
                JLT     vss_ect_gate_load_ram2d4
                JBR     off(0021bh).2, vss_ect_gate_load_ram2d4
                LB      A, off(002d4h)
                JNE     vss_ect_gate_load_carry_ram21e_bit1
                SB      off(00218h).0
                RB      off(00218h).1
                SJ      vss_ect_gate_load_carry_ram21e_bit1
injidx_flag_clear:     RB      off(00218h).0
                SB      off(00218h).1
injidx_flag_clear_set_ram22e_bit3:     SB      off(0022eh).3
vss_ect_gate_load_ram2d4:     MOVB    off(002d4h), #005h
vss_ect_gate_load_carry_ram21e_bit1:     MB      C, off(0021eh).1
                MB      off(0022fh).5, C
                MOVB    r0, #014h
                MOVB    r1, #019h
                MOVB    r2, #032h
                MOVB    r3, #01ah
                J       vss_ect_gate_load_r4
                DB  0D8h,017h,024h
vss_ect_gate_load_ram2d6:     MOVB    off(002d6h), r1
                MOVB    off(002d7h), r2
                J       vss_ect_gate_if_ram218_bit0_clr
vss_ect_gate_goto_711d:     J       vss_ect_gate_load_stk
;@ Stock_rom_17a8 type=u16 count=2 formula=raw category="Internal" desc="Stock data, 5 bytes, read by the code at vss_ect_gate_load_stk; its role not traced."
rom_17a8:       DB  044h,0BCh,0CDh,03Fh,0C6h ; 17A8
;@ Stock_rom_17ad type=u16 count=2 formula=raw category="Internal" desc="Stock data, 4 bytes, read by the code at vss_ect_gate_load_stk; its role not traced."
rom_17ad:       DB  070h,05Dh,0CFh ; 17AD
                DB  03Ah
vss_ect_gate_load_r3:     LB      A, r3
                CMPB    A, 0dah
                JLT     vss_ect_gate_load_ram2d3_2
vss_ect_gate_load_ram2d3:     MOVB    off(002d3h), r0
vss_ect_gate_load_ram2d3_2:     LB      A, off(002d3h)
                JEQ     idle_stage_c0_load_clear_ram218_bit0
                SJ      idle_stage_c0_load_nop_acc
idle_stage_alt_start:     MOVB    off(002d3h), r0
                JBR     off(0021ah).0, idle_stage_c0_start
                MOVB    off(002d7h), r2
                JBR     off(00218h).0, idle_stage_bf_store
                LB      A, r3
                CMPB    A, 0dah
                JLT     idle_stage_bf_load
idle_stage_bf_store:     MOVB    off(002d6h), r1
idle_stage_bf_load:     LB      A, off(002d6h)
                JEQ     idle_stage_c0_load_clear_ram218_bit0
                SJ      idle_stage_c0_load_nop_acc
idle_stage_c0_start:     MOVB    off(002d6h), r1
                JBR     off(00218h).0, idle_stage_c0_store
                JBR     off(0021bh).6, idle_stage_c0_load
idle_stage_c0_store:     MOVB    off(002d7h), r2
idle_stage_c0_load:     LB      A, off(002d7h)
                JNE     idle_stage_c0_load_nop_acc
idle_stage_c0_load_clear_ram218_bit0:     RB      off(00218h).0
                SB      off(00218h).1
idle_stage_c0_load_nop_acc:     NOP
                NOP
                NOP
                JBS     off(00216h).1, dcode14_clear
                JBS     off(00211h).5, dcode14_clear
                LB      A, 0dbh
                MOV     X1, #tbl_dcode14_lo
                VCAL    3
                CMPB    A, off(0026eh)
                JLT     dcode14_clear
                LB      A, 0dbh
                MOV     X1, #tbl_dcode14_hi
                VCAL    3
                CMPB    A, off(0026eh)
                JGE     dcode14_clear
                LB      A, off(002e3h)
                JEQ     dtc14_iacv_latch
dcode14_clear:     RC
dtc14_iacv_latch:     MB      099h.3, C
                LB      A, off(002f5h)
                JNE     dcode_threshold_check_clear_carry
                MOVB    off(002f5h), #006h
                LB      A, #0fah
                JBS     off(00216h).0, dcode_threshold_check_store_ram28b
                STB     A, r0
                LB      A, #078h
                STB     A, r1
                STB     A, r2
                JBS     off(00216h).4, tps_learn_table_store_load_r0
                JBS     off(00216h).5, tps_learn_table_store_load_r0
                LB      A, 0e8h
                CMPB    A, r1
                JGE     tps_learn_table_store_load_r0
                STB     A, r1
                MOVB    r3, off(0028ch)
                SUBB    A, r3
                JLT     tps_learn_table_store
                CMPB    A, #004h
                JGE     tps_learn_table_store_load_r0
                SUBB    off(0028bh), #001h
                JNE     tps_learn_table_store_load_dp
                MOV     DP, #0032fh
                LB      A, r3
                STB     A, [DP]
                MOV     DP, #0032eh
                LB      A, #0ffh
                STB     A, [DP]
                SJ      tps_learn_table_store_load_dp
tps_learn_table_store:     MOV     DP, #0032eh
                LB      A, [DP]
                JNE     tps_learn_table_store_load_r0
                MOVB    r0, #053h
tps_learn_table_store_load_r0:     LB      A, r0
                STB     A, off(0028bh)
                LB      A, r1
                STB     A, off(0028ch)
tps_learn_table_store_load_dp:     MOV     DP, #0032fh
                LB      A, [DP]
                CMPB    A, r2
                JLT     dcode_threshold_check_clear_carry
                LB      A, r2
                STB     A, [DP]
                SJ      dcode_threshold_check_clear_carry
dcode_threshold_check_store_ram28b:     STB     A, off(0028bh)
dcode_threshold_check_clear_carry:     RC
                LB      A, #025h
                JBR     off(00220h).2, dcode_threshold_check_store_ram0dd
                JBS     off(00212h).3, dcode_threshold_check_store_ram0dd
                LB      A, #05eh
                CMPB    A, 0dbh
                JGE     dtc20_eld_latch
                LB      A, #0dch
                MOV     DP, #003d8h
                CMPB    A, [DP]
                JLT     dtc20_eld_latch
                LB      A, [DP]
                CMPB    A, #00eh
                JLT     dtc20_eld_latch
dcode_threshold_check_store_ram0dd:     STB     A, 0ddh
dtc20_eld_latch:     MB      099h.7, C
                RC
                JBS     off(00220h).2, dcode_threshold_check_store_carry_ram218_bit3
                JBR     off(00221h).2, dcode_threshold_check_store_carry_ram218_bit3
                MOV     DP, #003d8h
                LB      A, [DP]
                CMPB    A, #09ah
dcode_threshold_check_store_carry_ram218_bit3:     MB      off(00218h).3, C
                VCAL    4
                MOV     DP, #003d7h
                LB      A, [DP]
                STB     A, 0dbh
                LB      A, 0dbh
                MOV     X1, #rom_502c
                VCAL    0
                STB     A, off(002a8h)
                LB      A, 0dbh
                MOV     X1, #rom_52fb
                VCAL    1
                STB     A, (00142h-00180h)[USP]
                LB      A, #09ah
                JBS     off(00231h).6, dcode_threshold_check_cmp_acc
                LB      A, #0a6h
dcode_threshold_check_cmp_acc:     CMPB    A, off(00289h)
                MB      off(00231h).6, C
                LB      A, #0cdh
                JBS     off(00231h).7, dcode_threshold_check_cmp_acc_2
                LB      A, #0d3h
dcode_threshold_check_cmp_acc_2:     CMPB    A, off(00289h)
                MB      off(00231h).7, C
                LB      A, #064h
                JBS     off(00232h).0, dcode_threshold_check_cmp_acc_3
                LB      A, #077h
dcode_threshold_check_cmp_acc_3:     CMPB    A, off(00288h)
                CLRB    A
                MB      off(00232h).0, C
                JGE     div_scale_mul_final_store_ram2ac
                CLR     A
                MOV     DP, #003dch
                LB      A, [DP]
                SUBB    A, #007h
                JGE     div_scale_calc1
                CLRB    A
div_scale_calc1:     MOVB    r0, #051h
                DIVB
                JBR     off(00231h).6, div_scale_gate_common
                MOVB    r0, #01bh
                LB      A, r1
                DIVB
                JBR     off(00231h).7, div_scale_gate_common
                MOVB    r0, #009h
                LB      A, r1
                DIVB
div_scale_gate_common:     CMPB    A, #003h
                JLT     div_scale_mul_final
                LB      A, #002h
div_scale_mul_final:     MOVB    r0, #009h
                MULB
                JBS     off(00224h).4, div_scale_mul_final_store_ram2ac
                VCAL    7
div_scale_mul_final_store_ram2ac:     STB     A, off(002ach)
                CLR     A
                LB      A, #0cbh
                JBS     off(0022ah).2, div_scale_mul_final_cmp_acc
                LB      A, #0d0h
div_scale_mul_final_cmp_acc:     CMPB    A, off(00289h)
                MB      off(0022ah).2, C
                LCB     A, 07ff0h
                SRLB    A
                SRLB    A
                CLRB    r2
                MOV     DP, #003d4h
                LB      A, [DP]
                JLT     div_scale_mul_final_call_4a84
                CMPB    A, #0f0h
                JLT     knock_div_calc1
                LB      A, #076h
knock_div_calc1:     MOVB    r0, #030h
                DIVB
                JBS     off(0022ah).2, knock_div_calc1_sllb_acc
                SRLB    A
                LB      A, r1
                JGE     knock_div_calc2
                LB      A, #02fh
                SUBB    A, r1
knock_div_calc2:     MOVB    r0, #009h
                DIVB
                CMPB    A, #004h
                JLE     knock_div_calc2_addb_acc
                LB      A, #004h
knock_div_calc2_addb_acc:     ADDB    A, #006h
knock_div_calc1_sllb_acc:     SLLB    A
                EXTND
                LC      A, rom_5413[ACC]
                SJ      knock_div_calc1_store_stk
div_scale_mul_final_call_4a84:     CAL     div_scale_mul_final_sub_subb_acc
                ADDB    A, #080h
                STB     A, r2
                L       A, #08000h
knock_div_calc1_store_stk:     ST      A, (00162h-00180h)[USP]
                MOVB    off(002b3h), r2
                VCAL    4
                CLRB    A
                MOV     DP, #003ddh
                LCB     A, 07ff0h
                SRLB    A
                SRLB    A
                SRLB    A
                JGE     knock_div_calc1_srlb_acc
                LB      A, [DP]
                CAL     div_scale_mul_final_sub_subb_acc
                ADDB    A, #080h
                CLR     er0
                SJ      knock_div_calc1_store_ram290
knock_div_calc1_srlb_acc:     SRLB    A
                JGE     knock_div_calc1_clear_acc
                LB      A, [DP]
                CAL     div_scale_mul_final_sub_subb_acc
                MOVB    r0, #080h
                MULB
                L       A, ACC
                ADD     A, #0c000h
                ST      A, er0
                CLRB    A
knock_div_calc1_store_ram290:     STB     A, off(00290h)
                MOV     off(0026ch), er0
                CLR     A
                SJ      knock_div_calc1_load_imm
knock_div_calc1_clear_acc:     CLRB    A
                STB     A, off(00290h)
                CLR     A
                ST      A, off(0026ch)
                LB      A, [DP]
                CMPB    A, #0f0h
                JLT     knock_div_calc3
knock_div_calc1_load_imm:     LB      A, #076h
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
                CMPB    A, #004h
                JLE     knock_div_calc4_addb_acc
                LB      A, #004h
knock_div_calc4_addb_acc:     ADDB    A, #006h
                SLLB    A
                EXTND
                MOV     X1, #rom_542b
                MOV     X2, #tbl_knock_retard_6a9f
                JBS     off(00220h).0, knock_div_calc4_if_ram21f_bit3_clr
                MOV     X1, #rom_5443
                MOV     X2, #tbl_knock_ptr_6ab7
knock_div_calc4_if_ram21f_bit3_clr:     JBR     off(0021fh).3, knock_div_calc4_load_x2
                MOV     X1, X2
knock_div_calc4_load_x2:     MOV     X2, X1
                ADD     X1, A
                LC      A, [X1]
                ST      A, (00166h-00180h)[USP]
                LB      A, r2
                SLLB    A
                EXTND
                ADD     X2, A
                LC      A, [X2]
                ST      A, (00164h-00180h)[USP]
                MOV     DP, #003deh
                LB      A, [DP]
                SUBB    A, #07eh
                CAL     div_scale_mul_final_sub_if_le_goto_4a8d
                ADDB    A, #080h
                STB     A, r0
                LCB     A, 07ff1h
                JEQ     knock_div_calc4_store_stk
                LB      A, r0
knock_div_calc4_store_stk:     STB     A, (0018bh-00180h)[USP]
                CLRB    ACC
                JNE     knock_div_calc4_store_stk_2
                LCB     A, 07ff0h
                SRLB    A
                CLRB    A
                JGE     knock_div_calc4_store_stk_2
                LB      A, r0
knock_div_calc4_store_stk_2:     STB     A, (00184h-00180h)[USP]
                CLR     A
                MOV     DP, #003d6h
                LB      A, [DP]
                ADDB    A, #020h
                JGE     knock_div_calc4_srlb_acc
                LB      A, #004h
                SJ      knock_div_calc4_rom_load_tbl_6a46_acc
knock_div_calc4_srlb_acc:     SRLB    A
                SRLB    A
                ANDB    A, #0f0h
                SWAPB
knock_div_calc4_rom_load_tbl_6a46_acc:     LCB     A, tbl_knock_6a46[ACC]
                STB     A, (00195h-00180h)[USP]
                VCAL    4
                SC
                LB      A, off(002efh)
                JNE     knock_div_calc4_store_carry_ram225_bit1
                JBS     off(00214h).0, knock_div_calc4_store_carry_ram225_bit1
                JBR     off(00216h).0, knock_div_calc4_store_carry_ram225_bit1
                RC
knock_div_calc4_store_carry_ram225_bit1:     MB      off(00225h).1, C
                JBS     off(00224h).2, knock_div_calc4_clear_carry_2
                JBS     off(00233h).6, knock_div_calc4_set_carry
                JBS     off(00233h).7, knock_div_calc4_set_carry
                LCB     A, 07ff1h
                JNE     knock_div_calc4_if_ram214_bit0_set
                LB      A, 0d5h
                JNE     knock_div_calc4_set_carry
knock_div_calc4_if_ram214_bit0_set:     JBS     off(00214h).0, knock_div_calc4_clear_ram2e1
                JBS     off(00216h).0, knock_div_calc4_clear_carry
knock_div_calc4_clear_ram2e1:     CLRB    off(002e1h)
knock_div_calc4_clear_carry:     RC
                LB      A, off(002e1h)
                JEQ     knock_div_calc4_store_carry_ram226_bit3
knock_div_calc4_set_carry:     SC
knock_div_calc4_store_carry_ram226_bit3:     MB      off(00226h).3, C
knock_div_calc4_clear_carry_2:     RC
                JBR     off(00220h).4, dtc25_code25_latch
                JBS     off(00216h).1, dtc25_code25_latch
                JBS     off(00213h).0, dtc25_code25_latch
                JBS     off(00213h).1, dtc25_code25_latch
                JBS     off(0022fh).4, dtc25_code25_latch
                LB      A, #07dh
                CMPB    A, 0dbh
                JGE     dtc25_code25_latch
                MB      C, off(00224h).3
                JBR     off(0022fh).3, dtc25_code25_latch
                XORB    PSWH, #080h
dtc25_code25_latch:     MB      09bh.0, C
                RC
                JBR     off(00220h).4, dtc26_code26_latch
                JBS     off(00216h).1, dtc26_code26_latch
                JBS     off(00213h).1, dtc26_code26_latch
                LB      A, #07dh
                CMPB    A, 0dbh
                JGE     dtc26_code26_latch
                MB      C, off(0022fh).4
dtc26_code26_latch:     MB      09bh.1, C
                JBS     off(00215h).1, knock_div_calc4_if_ram215_bit1_set
                JBS     off(00216h).1, knock_div_calc4_if_ram211_bit0_set
                JBS     off(00215h).0, knock_div_calc4_if_ram22a_bit3_clr
knock_div_calc4_if_ram211_bit0_set:     JBS     off(00211h).0, knock_div_calc4_set_ram215_bit1
                SJ      knock_div_calc4_load_imm
knock_div_calc4_if_ram22a_bit3_clr:     JBR     off(0022ah).3, knock_div_calc4_load_imm
                J       knock_div_calc4_if_ram21d_bit0_set
knock_div_calc4_load_imm:     LB      A, #0ffh
                STB     A, off(002edh)
                SJ      knock_div_calc4_if_ram215_bit1_set
knock_div_calc4_load_ram2ed:     LB      A, off(002edh)
                JNE     knock_div_calc4_if_ram215_bit1_set
knock_div_calc4_set_ram215_bit1:     SB      off(00215h).1
knock_div_calc4_if_ram215_bit1_set:     JBS     off(00215h).1, knock_div_calc4_if_ram215_bit1_set_2
                J       knock_div_calc4_if_ram215_bit0_clr
knock_div_calc4_if_ram213_bit1_set:     JBS     off(00213h).1, knock_div_calc4_if_ram224_bit3_clr
                JBR     off(0022fh).4, knock_div_calc4_load_imm_2
knock_div_calc4_if_ram224_bit3_clr:     JBR     off(00224h).3, knock_div_calc4_load_imm_2
                JBS     off(00217h).0, knock_div_calc4_load_ram2ee
                JBS     off(0021dh).3, knock_div_calc4_load_imm_2
knock_div_calc4_load_ram2ee:     LB      A, off(002eeh)
                JNE     knock_div_calc4_if_ram215_bit1_set_2
                SB      off(00215h).1
                SJ      knock_div_calc4_if_ram215_bit1_set_2
knock_div_calc4_load_imm_2:     LB      A, #0ffh
                STB     A, off(002eeh)
knock_div_calc4_if_ram215_bit1_set_2:     JBS     off(00215h).1, accut_check_c3_vcal_4
                J       knock_div_calc4_if_ram215_bit0_clr_2
knock_div_calc4_if_ram22f_bit4_set:     JBS     off(0022fh).4, knock_div_calc4_load_imm_3
                JBR     off(00213h).0, knock_div_calc4_load_imm_3
                JBS     off(00217h).0, knock_div_calc4_if_ram22f_bit3_set
                JBS     off(0021dh).3, knock_div_calc4_load_imm_3
knock_div_calc4_if_ram22f_bit3_set:     JBS     off(0022fh).3, accut_check_c3
knock_div_calc4_load_imm_3:     LB      A, #0ffh
                STB     A, off(002f0h)
                SJ      accut_check_c3_vcal_4
accut_check_c3:     LB      A, off(002f0h)
                JNE     accut_check_c3_vcal_4
                SB      off(00215h).1
accut_check_c3_vcal_4:     VCAL    4
                CMPB    0ffh, #019h
                JLT     accut_check_c3_clear_ram2da
                CMPB    0d9h, #015h
                JLT     accut_check_c3_load_imm
accut_check_c3_if_ram215_bit6_set:     JBS     off(00215h).6, accut_check_c3_if_ram224_bit0_clr
                LB      A, #033h
                JBS     off(0022fh).0, accut_check_c3_cmp_acc
                LB      A, #09ah
accut_check_c3_cmp_acc:     CMPB    A, 0abh
                MB      off(0022fh).0, C
                JLT     accut_check_c3_load_ram2da
                LB      A, #010h
                JBS     off(0022eh).7, accut_check_c3_cmp_acc_2
                LB      A, #020h
accut_check_c3_cmp_acc_2:     CMPB    A, 0dfh
                MB      off(0022eh).7, C
                CLRB    A
                JLT     accut_check_c3_store_ram2da
                LB      A, #028h
accut_check_c3_store_ram2da:     STB     A, off(002dah)
                SJ      accut_check_c3_if_ram224_bit0_clr
accut_check_c3_clear_ram2da:     CLRB    off(002dah)
                SJ      accut_check_c3_clear_ram2f8
accut_check_c3_load_imm:     LB      A, #07dh
                JBS     off(0022eh).6, accut_check_c3_cmp_acc_3
                LB      A, #082h
accut_check_c3_cmp_acc_3:     CMPB    A, 0dfh
                MB      off(0022eh).6, C
                JGE     accut_check_c3_if_ram215_bit6_set
                LB      A, #0cdh
                JBS     off(0022eh).4, accut_check_c3_cmp_acc_4
                LB      A, #0d0h
accut_check_c3_cmp_acc_4:     CMPB    A, off(00289h)
                MB      off(0022eh).4, C
                JGE     accut_check_c3_if_ram215_bit6_set
accut_check_c3_clear_ram2f8:     CLRB    off(002f8h)
                SJ      accut_check_c3_clear_ram22e_bit5
accut_check_c3_load_ram2da:     LB      A, off(002dah)
                JNE     accut_check_c3_clear_ram2f8
accut_check_c3_if_ram224_bit0_clr:     JBR     off(00224h).0, accut_check_c3_clear_ram22e_bit5
                SB      off(0022eh).5
                LB      A, off(002f7h)
                JNE     accut_check_c3_clear_carry
                MOVB    off(002f8h), #028h
accut_check_c3_set_carry:     SC
                SJ      accut_check_c3_store_carry_ram225_bit0
accut_check_c3_clear_ram22e_bit5:     RB      off(0022eh).5
                LB      A, off(002f8h)
                JNE     accut_check_c3_set_carry
                MOVB    off(002f7h), #02dh
accut_check_c3_clear_carry:     RC
accut_check_c3_store_carry_ram225_bit0:     MB      off(00225h).0, C
                MB      off(00215h).2, C
                SC
                JBS     off(00216h).1, purge_counter_check_store_carry_ram225_bit7
                JBS     off(00210h).5, purge_counter_check
                LB      A, #038h
                CMPB    A, 0d9h
                JLT     purge_counter_check_store_carry_ram225_bit7
purge_counter_check:     CMP     (00172h-00180h)[USP], #005d7h
                JLT     purge_counter_check_store_carry_ram225_bit7
                CMPB    off(002bfh), #005h
                JNE     purge_counter_check_clear_carry
                CMPB    off(002d9h), #019h
                JLT     purge_counter_check_store_carry_ram225_bit7
purge_counter_check_clear_carry:     RC
purge_counter_check_store_carry_ram225_bit7:     MB      off(00225h).7, C
                LB      A, #0c7h
                JBR     off(00225h).4, purge_counter_check_cmp_ram289
                LB      A, #0cah
purge_counter_check_cmp_ram289:     CMPB    off(00289h), A
                MB      off(00225h).4, C
                LB      A, #0bah
                JBR     off(00225h).5, purge_counter_check_cmp_ram289_2
                LB      A, #0bfh
purge_counter_check_cmp_ram289_2:     CMPB    off(00289h), A
                MB      off(00225h).5, C
                CLRB    A
                RC
                JBS     off(00215h).6, purge_counter_check_store_ram2d1
                JBS     off(0021dh).4, purge_counter_check_cmp_ram0d8
                LB      A, off(002d1h)
                JEQ     purge_counter_check_store_ram2d1
                SC
                SJ      purge_counter_check_store_ram2d1
purge_counter_check_cmp_ram0d8:     CMPB    0d8h, #000h
                JGE     purge_counter_check_store_ram2d1
                CMPB    0d9h, #000h
                JGE     purge_counter_check_store_ram2d1
                LB      A, #000h
purge_counter_check_store_ram2d1:     STB     A, off(002d1h)
                MB      off(00225h).6, C
                MB      off(00215h).3, C
                MOVB    r0, 0dfh
                LB      A, #00dh
                JBS     off(00234h).2, purge_counter_check_cmp_acc
                LB      A, #00fh
purge_counter_check_cmp_acc:     CMPB    A, r0
                MB      off(00234h).2, C
                LB      A, #044h
                JBS     off(00234h).3, purge_counter_check_cmp_acc_2
                LB      A, #046h
purge_counter_check_cmp_acc_2:     CMPB    A, r0
                MB      off(00234h).3, C
                LB      A, #044h
                JBS     off(00234h).4, purge_counter_check_cmp_acc_3
                LB      A, #046h
purge_counter_check_cmp_acc_3:     CMPB    A, r0
                MB      off(00234h).4, C
                MOVB    r0, off(00289h)
                LB      A, #053h
                JBS     off(00234h).5, purge_counter_check_cmp_acc_4
                LB      A, #066h
purge_counter_check_cmp_acc_4:     CMPB    A, r0
                MB      off(00234h).5, C
                LB      A, #0a0h
                JBS     off(00234h).6, purge_counter_check_cmp_acc_5
                LB      A, #0b0h
purge_counter_check_cmp_acc_5:     CMPB    A, r0
                MB      off(00234h).6, C
                LB      A, #070h
                JBS     off(00234h).7, purge_counter_check_cmp_ram0dd
                LB      A, #060h
purge_counter_check_cmp_ram0dd:     CMPB    0ddh, A
                MB      off(00234h).7, C
                JBR     off(00220h).2, purge_counter_check_clear_ram225_bit2
                JBS     off(00215h).6, purge_counter_check_clear_ram225_bit2
                JBS     off(00224h).2, purge_counter_check_clear_ram225_bit2
                JBR     off(00216h).0, state_dispatch2
purge_counter_check_clear_ram225_bit2:     RB      off(00225h).2
                J       state_dispatch4_set_ram225_bit3
state_dispatch2:     JBR     off(00234h).2, state_dispatch3_load_ram2e6_2
                JBS     off(0021ah).0, state_dispatch3
                JBR     off(00220h).0, state_dispatch3_load_ram2e6_2
                JBR     off(0021ch).1, state_dispatch3_load_ram2e6_2
state_dispatch3:     JBR     off(00234h).5, state_dispatch3_load_ram2e6_2
                JBS     off(00234h).4, state_dispatch3_load_ram2e6
                CMPB    0d9h, #028h
                JGE     state_dispatch3_load_ram2e6
                JBS     off(00235h).0, state_dispatch3_load_ram2e6
                LB      A, off(002e6h)
                JNE     state_dispatch3_load_ram2e7
                MOVB    off(002e7h), #003h
state_dispatch3_set_carry:     SC
                SJ      state_dispatch3_store_carry_ram225_bit2
state_dispatch3_load_ram2e6:     MOVB    off(002e6h), #003h
                RC
state_dispatch3_store_carry_ram225_bit2:     MB      off(00225h).2, C
                MOVB    off(002e8h), #00ah
                SJ      state_dispatch3_load_ram2cd
state_dispatch3_load_ram2e6_2:     MOVB    off(002e6h), #003h
state_dispatch3_load_ram2e7:     LB      A, off(002e7h)
                JNE     state_dispatch3_set_carry
                SC
                JBS     off(00230h).3, state_dispatch3_store_carry_ram225_bit2_2
                RC
state_dispatch3_store_carry_ram225_bit2_2:     MB      off(00225h).2, C
                LB      A, off(002e8h)
                JEQ     state_dispatch3_if_ram234_bit7_set
                JBS     off(00235h).0, state_dispatch3_load_ram2cd
                SJ      state_dispatch4
state_dispatch3_if_ram234_bit7_set:     JBS     off(00234h).7, state_dispatch3_load_ram2e9_2
                JBR     off(00220h).0, state_dispatch3_load_ram2e9
                JBS     off(00224h).5, state_dispatch3_set_ram235_bit0
state_dispatch3_load_ram2e9:     LB      A, off(002e9h)
                JNE     state_dispatch3_load_ram2cd
                JBS     off(00234h).2, state_dispatch3_clear_ram235_bit0
                JBS     off(00235h).0, state_dispatch3_load_ram2cd
state_dispatch3_clear_ram235_bit0:     RB      off(00235h).0
state_dispatch4:     JBS     off(00234h).3, state_dispatch4_if_ram235_bit1_set
                JBS     off(00234h).6, state_dispatch4_if_ram235_bit1_set
                CMPB    0d9h, #02eh
                JGE     state_dispatch4_if_ram235_bit1_set
                CMPB    0d8h, #0a1h
                JGE     state_dispatch4_if_ram235_bit1_set
                JBS     off(00224h).0, state_dispatch4_if_ram235_bit1_set
                LB      A, off(002cdh)
                JEQ     state_dispatch4_if_ram235_bit1_set
                RB      off(00235h).1
state_dispatch4_clear_ram225_bit3:     RB      off(00225h).3
                SJ      state_dispatch4_load_dp
state_dispatch3_load_ram2e9_2:     MOVB    off(002e9h), #028h
state_dispatch3_set_ram235_bit0:     SB      off(00235h).0
state_dispatch3_load_ram2cd:     MOVB    off(002cdh), #028h
state_dispatch4_if_ram235_bit1_set:     JBS     off(00235h).1, state_dispatch4_load_ram2ea
                SB      off(00235h).1
                MOVB    off(002eah), #003h
state_dispatch4_load_ram2ea:     LB      A, off(002eah)
                JNE     state_dispatch4_clear_ram225_bit3
                CMPB    off(00298h), #003h
                JGT     state_dispatch4_clear_ram225_bit3
state_dispatch4_set_ram225_bit3:     SB      off(00225h).3
state_dispatch4_load_dp:     MOV     DP, #0a000h
                LB      A, off(00225h)
                XORB    A, #0ffh
                STB     A, [DP]
                MOV     DP, #00044h
                MOV     X1, #00312h
                CAL     learn_table2_check_sub_load_dp_ind
                MOV     OS0, #0ffffh
                VCAL    4
                MOV     er1, 098h
                MOV     er2, 09ah
                MB      C, 09eh.0
                JGE     dtc_scan_init
                CLR     A
                ST      A, 098h
                ST      A, 09ah
                ST      A, er1
                ST      A, er2
dtc_scan_init:     MOVB    r7, #001h
                MOV     DP, #002d9h
dtc_scan_loop:     SRL     er2
                ROR     er1
                JLT     dtc_scan_found_check
                LB      A, r7
                SUBB    A, off(002bfh)
                JNE     dtc_scan_f4_check
                STB     A, off(002bfh)
                STB     A, [DP]
dtc_scan_f4_check:     LB      A, r7
                SUBB    A, 0f1h
                JNE     dtc_scan_advance
                STB     A, 0f1h
dtc_scan_advance:     INCB    r7
                CMPB    r7, #01ch
                JLT     dtc_scan_loop
                SJ      dtc_debounce_init
dtc_scan_found_check:     LB      A, off(002bfh)
                JEQ     dtc_scan_new_code
                CMPB    A, r7
                JNE     dtc_scan_advance
                LB      A, [DP]
                JNE     dtc_debounce_init
                SJ      dtc_debounce2_check_set_ram233_bit5
dtc_scan_new_code:     CLR     A
                LB      A, r7
                STB     A, off(002bfh)
                LCB     A, dtc_scan_new_code_tbl[ACC]
                STB     A, [DP]
dtc_debounce_init:     VCAL    4
                MOVB    r7, #021h
                CLR     A
                XCHG    A, 09ch
                JBS     off(0021bh).6, dtc_debounce_mask_apply
                AND     A, #0f8ffh
dtc_debounce_mask_apply:     ST      A, er0
                MB      C, 09eh.0
                JGE     dtc_debounce_loop_start
                CLR     er0
dtc_debounce_loop_start:     MOV     DP, #001a0h
dtc_debounce_loop:     SRL     er0
                JLT     dtc_debounce_loop_load_dp_ind
                CLR     A
                LB      A, r7
                CMPB    A, 0f1h
                JNE     dtc_debounce_loop_inc_dp
                LCB     A, dtc_scan_new_code_tbl[ACC]
                SUBB    A, [DP]
                JNE     dtc_debounce_loop_inc_dp
                STB     A, 0f1h
                SJ      dtc_debounce_loop_inc_dp
dtc_debounce_loop_load_dp_ind:     LB      A, [DP]
                JEQ     dtc_debounce2_check_set_ram233_bit5
                DECB    [DP]
dtc_debounce_loop_inc_dp:     INC     DP
                INCB    r7
                CMPB    r7, #02ch
                JLT     dtc_debounce_loop
                MOVB    r7, #030h
                MOV     DP, #00172h
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                JLT     dtc_debounce2_check
                MOV     [DP], #00bb3h
                LB      A, 0f1h
                SUBB    A, r7
                JNE     dtc_active_confirm_goto_6f00
                STB     A, 0f1h
                SJ      dtc_active_confirm_goto_6f00
dtc_debounce2_check:     L       A, [DP]
                JNE     dtc_active_confirm_goto_6f00
dtc_debounce2_check_set_ram233_bit5:     SB      off(00233h).5
                L       A, DP
                PUSHS   A
                L       A, er3
                PUSHS   A
                VCAL    4
                POPS    A
                ST      A, er3
                POPS    A
                MOV     DP, A
                JBR     off(00233h).5, dtc_active_confirm_goto_6f00
                LB      A, #005h
                STB     A, [DP]
                LB      A, 0f1h
                JNE     dtc_active_confirm
                LB      A, r7
                STB     A, 0f1h
                SJ      dtc_active_confirm_goto_6f00
dtc_active_confirm:     SUBB    A, r7
                JNE     dtc_active_confirm_goto_6f00
                RB      PSWH.0
                STB     A, 0f1h
                CLR     A
                LB      A, r7
                CMPB    A, #030h
                JNE     dtc_active_confirm_rom_load_tbl_577f_acc
                MOV     (00172h-00180h)[USP], #00bb3h
                JBR     off(0021fh).0, dtc_active_confirm_rom_load_tbl_577f_acc
                SB      0a0h.0
                SJ      dtc_active_confirm_set_pswh_bit0
dtc_active_confirm_rom_load_tbl_577f_acc:     LCB     A, dtc_active_confirm_tbl[ACC]
                JEQ     dtc_active_confirm_set_pswh_bit0
                STB     A, r6
                MOV     DP, #003e0h
                LB      A, ADCR2H
                STB     A, [DP]
                INC     DP
                LB      A, ADCR3H
                STB     A, [DP]
                INC     DP
                LB      A, ADCR4H
                STB     A, [DP]
                INC     DP
                LB      A, ADCR5H
                STB     A, [DP]
                INC     DP
                LB      A, ADCR6H
                STB     A, [DP]
                INC     DP
                LB      A, ADCR7H
                STB     A, [DP]
                SB      off(00233h).0
                SB      off(00233h).1
                CAL     dtc_active_confirm_sub_clear_acc
                CAL     dtc_active_confirm_sub_load_dp
                CAL     cfgvariant_checksum_calc
                ST      A, [DP]                ; (a word: the sum and the xor, 362h-363h)
                RB      off(00233h).0
                RB      off(00233h).1
dtc_active_confirm_set_pswh_bit0:     SB      PSWH.0
dtc_active_confirm_goto_6f00:     J       dtc_active_confirm_vcal_4
dtc_active_confirm_load_x1:     MOV     X1, #00114h
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
                JNE     calchecksum_loop_load_ram0d4_4
                CMP     DP, #00330h
                JNE     calchecksum_loop
                LB      A, [DP]
                ANDB    A, #002h
                JNE     calchecksum_loop_load_ram0d4_4
                INC     DP
                LB      A, [DP]
                ANDB    A, #004h
                JNE     calchecksum_loop_load_ram0d4_4
                INC     DP
                LB      A, [DP]
                ANDB    A, #006h
                JNE     calchecksum_loop_load_ram0d4_4
                INC     DP
                LB      A, [DP]
                ANDB    A, #088h
                JNE     calchecksum_loop_load_ram0d4_4
                INC     DP
                L       A, [DP]
                CMP     A, er0
                JEQ     calchecksum_loop_call_4afe
calchecksum_loop_load_ram0d4_4:     MOVB    0d4h, #04fh
                J       fault_retry_check_nop_acc
calchecksum_loop_call_4afe:     CAL     cfgvariant_checksum_loop_load_dp
                CMP     A, [DP]
                JNE     calchecksum_loop_load_ram0d4_4
                L       A, off(00210h)
                AND     A, #08075h
                JNE     calchecksum_loop_set_ram218_bit6
                LB      A, off(00213h)
                ANDB    A, #014h
                JEQ     calchecksum_loop_load_ram210
calchecksum_loop_set_ram218_bit6:     SB      off(00218h).6
calchecksum_loop_load_ram210:     L       A, off(00210h)
                ORB     A, off(00212h)
                ADD     A, #0ffffh
                MB      off(00215h).6, C
                L       A, off(00210h)
                AND     A, #0fbfdh
                JNE     calchecksum_loop_set_ram233_bit6
                L       A, off(00212h)
                AND     A, #014f1h
                JEQ     calchecksum_loop_vcal_4_3
calchecksum_loop_set_ram233_bit6:     SB      off(00233h).6
calchecksum_loop_vcal_4_3:     VCAL    4
                JBS     off(00213h).2, calchecksum_loop_clear_carry
                JBS     off(00210h).5, calchecksum_loop_clear_carry
                MB      C, 098h.1
                JLT     calchecksum_loop_clear_carry
                JBS     off(00216h).0, calchecksum_loop_clear_carry
                CMPB    0d9h, #0c5h
                JGE     calchecksum_loop_clear_carry
                CMPB    0dbh, #0a7h
                JLT     calchecksum_loop_store_carry_ram22a_bit0
calchecksum_loop_clear_carry:     RC
calchecksum_loop_store_carry_ram22a_bit0:     MB      off(0022ah).0, C
                XORB    PSWH, #080h
                JGE     calchecksum_loop_nop_acc_2
                MB      P2A.2, C
calchecksum_loop_nop_acc_2:     NOP
                NOP
                NOP
                NOP
                SB      off(00233h).3
                JNE     calchecksum_loop_goto_0c7e
                CAL     learn_table2_check_sub_load_imm
                MB      C, 09eh.0
                JLT     calchecksum_loop_load_timer
                MOVB    0d7h, #010h
                DIV
                CAL     calchecksum_loop_sub_div_acc
calchecksum_loop_load_timer:     L       A, TIMER
                ST      A, 0d2h
                AND     IRQ, #00600h
                CLRB    TRNSIT
                MOV     OS1, #0f63bh
                MOV     IE, #0141bh
calchecksum_loop_goto_0c7e:     J       calchecksum_loop_nop_acc
crank_cycle_er2_store_set_ram132_bit2:     SB      off(00132h).2
                L       A, off(0011ah)
                ST      A, (0021ah-00280h)[USP]
                J       crank_cycle_er2_store_load_imm
                DW  00000h
crank_cycle_er2_store_load_lrb:     MOV     LRB, #00040h
                MOVB    PSWL, #001h
                MOV     USP, #00180h
                MOV     OS2, #0ffffh
                LB      A, 0abh
                STB     A, 0e7h
                MOV     er0, #04d00h
                JBS     off(00210h).6, crank_cycle_er2_store_load_er0
                MOV     er0, 0a6h
                LB      A, #0fah
                CMPB    A, r1
                JLT     dtc07_tps_latch
                CMPB    r1, #005h
                JLT     dtc07_tps_latch
crank_cycle_er2_store_load_er0:     L       A, er0
                SLL     A
                JLT     tps_delta_clamp1
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store1
tps_delta_clamp1:     LB      A, #0ffh
tps_delta_store1:     STB     A, 0e8h
                L       A, er0
                XCHG    A, 0aah
                RC
dtc07_tps_latch:     MB      098h.2, C
                JLT     tps_delta_store1_load_er0
                JBR     off(00210h).6, tps_delta_check1
tps_delta_store1_load_er0:     L       A, er0
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
                RB      off(00219h).0
                MB      off(00219h).0, C
                XCHGB   A, 0e9h
                JEQ     tps_delta_store2_if_ge_goto_1f50
                XORB    PSWH, #080h
tps_delta_store2_if_ge_goto_1f50:     JGE     tps_delta_store2_subb_acc
                ADDB    A, r0
                JGE     tps_delta_store2_set_ram219_bit1
                LB      A, #0ffh
tps_delta_store2_set_ram219_bit1:     SB      off(00219h).1
                SJ      tps_delta_store2_store_ram0f0
tps_delta_store2_subb_acc:     SUBB    A, r0
                MB      off(00219h).1, C
                JGE     tps_delta_store2_store_ram0f0
                VCAL    7
tps_delta_store2_store_ram0f0:     STB     A, 0f0h
                JBS     off(00210h).2, map_sign_flag_clear
                L       A, 0a4h
                SWAP
                LB      A, ACC
                CMPB    A, #0a1h
                JGT     dtc03_map_latch
                CMPB    A, #00bh
                JGE     map_neg_helper_call
dtc03_map_latch:     SB      098h.0
                LB      A, off(00288h)
                SJ      map_sign_gate2
map_neg_helper_call:     CAL     subtract24_clamp_byte
map_sign_flag_clear:     RB      098h.0
                JBS     off(00210h).2, map_sign_gate3
map_sign_gate2:     JBR     off(00210h).4, map_sign_gate4
map_sign_gate3:     LB      A, 0abh
                MOV     X1, #tbl_tps_5736
                VCAL    2
map_sign_gate4:     STB     A, r0
                STB     A, (00178h-00180h)[USP]
                XCHGB   A, off(00288h)
                STB     A, r1
                XCHGB   A, 0e1h
                MOV     DP, #003a1h
                XCHGB   A, [DP]
                INC     DP
                XCHGB   A, [DP]
                SUBB    A, r0
                MB      off(00219h).3, C
                JGE     map_sign_gate4_store_ram0e6
                VCAL    7
map_sign_gate4_store_ram0e6:     STB     A, 0e6h
                LB      A, r1
                SUBB    A, r0
                MB      off(00219h).2, C
                JGE     map_sign_gate4_store_ram0e5
                VCAL    7
map_sign_gate4_store_ram0e5:     STB     A, 0e5h
                MOV     DP, #00370h
                CLR     A
                ST      A, er0
                ST      A, er1
map_sign_gate4_load_dp_ind:     L       A, [DP]
                JEQ     map_sign_gate4_set_ram235_bit7
                ADD     er0, A
                ADCB    r2, #000h
                INC     DP
                INC     DP
                CMP     DP, #0037ch
                JLT     map_sign_gate4_load_dp_ind
                RB      off(00216h).0
                RB      off(00235h).7
                SRLB    r2
                ROR     er0
                SRLB    r2
                ROR     er0
                LB      A, r2
                JEQ     map_sign_gate4_load_er0
map_sign_gate4_set_ram235_bit7:     SB      off(00235h).7
                L       A, #0ffffh
                ST      A, er0
map_sign_gate4_load_er0:     L       A, er0
                MOV     DP, #0037ch
                XCHG    A, 0aeh
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
                MB      off(00219h).5, C
                JGE     map_sign_gate4_store_ram0b2
                VCAL    7
map_sign_gate4_store_ram0b2:     ST      A, 0b2h
                L       A, er0
                SUB     A, er1
                MB      off(00219h).4, C
                JGE     rpm_decel_limit_check
                VCAL    7
rpm_decel_limit_check:     ST      A, 0b0h
                L       A, 0aeh
                CMP     A, #000eah
                JLT     rpm_decel_limit_check_cmp_acc_2
                CMP     A, #00ea6h
                JGE     rpm_decel_limit_check_clear_acc
                ST      A, er2
                MOV     X2, #00080h
                CLR     er0
                MOV     X1, #0ea60h
                MOV     DP, #rpm_decel_limit_check_tbl
rpm_decel_limit_check_cmp_acc:     CMPC    A, [DP]
                JLT     rpm_decel_limit_check_load_x1
                SLL     X1
                ROL     er0
                INC     DP
                INC     DP
                SUB     X2, #00040h
                JGE     rpm_decel_limit_check_cmp_acc
rpm_decel_limit_check_load_x1:     L       A, X1
                DIV
                SRL     A
                ADD     A, X2
                ST      A, er3
                LB      A, r7
                JNE     rpm_decel_limit_check_load_imm_2
                LB      A, r6
                JEQ     rpm_decel_limit_check_load_imm
                INCB    r6
                JEQ     rpm_decel_limit_check_load_imm_2
                SJ      rpm_decel_limit_check_store_stk
rpm_decel_limit_check_clear_acc:     CLRB    A
                JBS     off(00216h).0, rpm_decel_limit_check_store_stk
rpm_decel_limit_check_load_imm:     LB      A, #001h
                SJ      rpm_decel_limit_check_store_stk
rpm_decel_limit_check_cmp_acc_2:     CMP     A, #000bbh
                LB      A, #0ffh
                JLT     rpm_decel_limit_check_store_stk
rpm_decel_limit_check_load_imm_2:     LB      A, #0feh
rpm_decel_limit_check_store_stk:     STB     A, (00179h-00180h)[USP]
                XCHGB   A, off(00289h)
                STB     A, 0eah
                LB      A, off(00289h)
                CMPB    A, #000h
                JGT     rpm_decel_limit_check_load_ram2a6
                JBS     off(00210h).6, rpm_decel_limit_check_load_ram2a6
                JBS     off(00211h).4, rpm_decel_limit_check_load_ram2a6
                JBS     off(0021dh).2, rpm_decel_limit_check_load_ram2a6
                MOV     X1, #rom_50f0
                VCAL    0
                JBR     off(00231h).5, rpm_decel_limit_check_cmp_acc_3
                SUBB    A, #002h
                JGE     rpm_decel_limit_check_cmp_acc_3
                CLRB    A
rpm_decel_limit_check_cmp_acc_3:     CMPB    A, 0abh
                MB      off(00231h).5, C
                JGE     rpm_decel_limit_check_load_ram2a6
                LB      A, off(002a6h)
                JEQ     rpm_decel_limit_check_clear_ram231_bit4
                SUBB    A, #001h
                STB     A, off(002a6h)
                JEQ     rpm_decel_limit_check_clear_ram231_bit4
                SB      off(00231h).4
                SB      off(00232h).2
                SJ      rpm_decel_limit_check_load_ram0e0
rpm_decel_limit_check_load_ram2a6:     MOVB    off(002a6h), #005h
                RB      off(00232h).2
rpm_decel_limit_check_clear_ram231_bit4:     RB      off(00231h).4
rpm_decel_limit_check_load_ram0e0:     LB      A, 0e0h
                JBS     off(00210h).2, rpm_decel_limit_check_store_r0
                JBS     off(00210h).4, rpm_decel_limit_check_store_r0
                JBS     off(00231h).4, rpm_decel_limit_check_store_r0
                LB      A, off(00288h)
rpm_decel_limit_check_store_r0:     STB     A, r0
                MB      C, PSWH.6
                MB      off(0022bh).3, C
                MOVB    r6, 0ech
                CAL     tps_interp_exact_match_sub_clear_acc
                MB      C, PSWL.4
                MB      off(0022bh).2, C
                STB     A, 0c8h
                LB      A, r6
                STB     A, 0ech
                MOVB    r1, #00fh
                JBS     off(00232h).4, rpm_decel_limit_check_clear_carry
                LB      A, 0ech
                ADDB    A, #001h
                JBR     off(0022bh).3, rpm_decel_limit_check_if_ram22b_bit2_clr
                CLRB    A
rpm_decel_limit_check_if_ram22b_bit2_clr:     JBR     off(0022bh).2, rpm_decel_limit_check_store_r1
                LB      A, #00ah
rpm_decel_limit_check_store_r1:     STB     A, r1
rpm_decel_limit_check_clear_carry:     RC
                JBR     off(00221h).0, rpm_decel_limit_check_store_carry_ram223_bit3
                JBS     off(00212h).5, rpm_decel_limit_check_store_carry_ram223_bit3
                MB      C, off(00227h).4
rpm_decel_limit_check_store_carry_ram223_bit3:     MB      off(00223h).3, C
                SC
                LB      A, (001b4h-00180h)[USP]
                JNE     rpm_decel_limit_check_store_carry_ram223_bit5
                J       rpm_decel_limit_check_if_ram230_bit1_set
                DB  077h ; 20D8
;@ Stock_rom_20d9 type=u8 count=3 formula=raw category="Internal" desc="Stock data, 3 bytes, read by the code at rpm_decel_limit_check_if_ram230_bit1_set; its role not traced."
rom_20d9:       DB  0F4h,0C7h,0BAh ; 20D9
rpm_decel_limit_check_store_carry_ram223_bit5:     MB      off(00223h).5, C
                MB      C, off(0021ah).0
                MB      off(00223h).4, C
                LB      A, off(00223h)
                SWAPB
                STB     A, r5
                ANDB    r5, #00fh
                ANDB    A, #0f0h
                ORB     A, r1
                STB     A, r4
                L       A, er2
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
                L       A, er2
                ST      A, 0ceh
                MOV     X1, #003d0h
                LB      A, 00000h[X1]
                JBS     off(00214h).7, scale_div32_loop_store_ram0da
                LB      A, ADCR1H
                STB     A, 00008h[X1]
                LB      A, ADCR0H
                STB     A, 00000h[X1]
scale_div32_loop_store_ram0da:     STB     A, 0dah
                MOVB    r0, 0bbh
                CAL     scale_div32_loop_sub_clear_pswh_bit0
                SC
                JBR     off(0022ah).0, scale_div32_loop_store_carry_p2a_bit2
                MB      C, off(00238h).3
scale_div32_loop_store_carry_p2a_bit2:     MB      P2A.2, C
                LB      A, ADCR5H
                STB     A, 0deh
                LB      A, #0a0h
                JBS     off(00210h).2, tps_custom_clamp_store
                JBS     off(00210h).4, tps_custom_clamp_store
                JBS     off(00211h).4, tps_custom_clamp_store
                LB      A, 0e0h
                SUBB    A, off(00288h)
                JGE     tps_custom_clamp_store
                CLRB    A
tps_custom_clamp_store:     STB     A, 0e2h
                MOVB    r0, off(00295h)
                LB      A, #00ah
                ADDB    A, r0
                STB     A, r1
                JBR     off(00216h).4, tps_custom_clamp_store_cmp_acc
                LB      A, r0
tps_custom_clamp_store_cmp_acc:     CMPB    A, off(00289h)
                MB      off(00216h).4, C
                MOV     DP, #0032fh
                MOVB    r4, [DP]
                LB      A, #003h
                STB     A, r2
                MOVB    r3, #004h
                MB      C, off(00217h).2
                MB      off(00217h).3, C
                JLT     tps_window_calc2
                LB      A, r3
tps_window_calc2:     ADDB    A, r4
                CMPB    A, 0e8h
                MB      off(00217h).2, C
                LB      A, #004h
                JBS     off(00217h).4, tps_window_calc3
                LB      A, #005h
tps_window_calc3:     ADDB    A, r4
                CMPB    A, 0e8h
                MB      off(00217h).4, C
                LB      A, r2
                MB      C, off(00217h).0
                MB      off(00217h).1, C
                JGE     tps_window_calc4
                MOVB    r0, r1
                LB      A, r3
tps_window_calc4:     ADDB    A, r4
                CMPB    0e8h, A
                JGE     tps_window_store2
                LB      A, off(00289h)
                CMPB    A, r0
tps_window_store2:     MB      off(00217h).0, C
                MOVB    r0, 0e5h
                MOVB    r1, off(00288h)
                JBS     off(0021ah).6, tps_interp_exact_match
                JBS     off(00224h).2, tps_interp_exact_match
                JBS     off(00210h).2, tps_interp_exact_match
                JBS     off(00210h).4, tps_interp_exact_match
                MOVB    r4, #0ffh
                LB      A, 0e1h
                MOV     DP, #rom_51ac
                MOV     X1, #rom_51b3
                JBS     off(00217h).0, tps_table_lookup
                INC     DP
                INC     X1
                INC     X1
                CMPB    A, #060h
                JGE     tps_table_offset_check
                INC     DP
                INC     DP
                CMPB    A, #040h
                JGE     tps_table_offset_check
                INC     DP
                INC     DP
tps_table_offset_check:     JBS     off(00219h).2, tps_table_lookup
                INC     X1
                INC     X1
tps_table_lookup:     LC      A, [X1]
                CMPB    A, r0
                JLT     tps_interp_clamp_check
tps_interp_exact_match:     LB      A, r1
                SJ      tps_interp_exact_match_store_ram0e3
tps_interp_clamp_check:     LB      A, ACCH
                CMPB    A, r0
                JGE     tps_interp_clamp_check_clear_acc
                STB     A, r0
tps_interp_clamp_check_clear_acc:     CLR     A
                LC      A, [DP]
                JBS     off(00217h).0, tps_interp_clamp_check_mulb_acc
                JBS     off(00219h).2, tps_interp_clamp_check_mulb_acc
                SWAP
tps_interp_clamp_check_mulb_acc:     MULB
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ST      A, er1
                LB      A, r3
                JNE     tps_interp_clamp_check_clear_acc_2
                LB      A, r2
                JBS     off(00219h).2, tps_interp_clamp_check_addb_acc
                VCAL    7
tps_interp_clamp_check_addb_acc:     ADDB    A, r1
                JBS     off(00219h).2, tps_interp_clamp_check_if_lt_goto_2202
                XORB    PSWH, #080h
tps_interp_clamp_check_if_lt_goto_2202:     JLT     tps_interp_clamp_check_clear_acc_2
                CMPB    A, r4
                JLE     tps_interp_exact_match_store_ram0e3
                SJ      tps_interp_clamp_check_load_r4
tps_interp_clamp_check_clear_acc_2:     CLRB    A
                JBR     off(00219h).2, tps_interp_exact_match_store_ram0e3
tps_interp_clamp_check_load_r4:     LB      A, r4
tps_interp_exact_match_store_ram0e3:     STB     A, 0e3h
                STB     A, r0
                MOVB    r6, 0edh
                CAL     tps_interp_exact_match_sub_clear_acc
                STB     A, 0c6h
                LB      A, r6
                STB     A, 0edh
                L       A, 0aeh
                SUB     A, off(00286h)
                MB      off(00216h).7, C
                JGE     tps_interp_exact_match_store_ram0b4
                VCAL    7
tps_interp_exact_match_store_ram0b4:     ST      A, 0b4h
                LB      A, #08dh
                JBS     off(00234h).0, tps_interp_exact_match_cmp_acc
                LB      A, #093h
tps_interp_exact_match_cmp_acc:     CMPB    A, off(00289h)
                MB      off(00234h).0, C
                MOV     DP, #tbl_rpm_scalar_lo40
                MOVB    r6, 0eeh
                CAL     tps_interp_exact_match_sub_rom_load_00026h_dp
                MB      C, PSWL.4
                MB      off(0022bh).1, C
                MB      C, PSWL.5
                MB      off(0022bh).0, C
                STB     A, 0cah
                LB      A, r6
                STB     A, 0eeh
                MOV     DP, #tbl_rpm_scalar_hi40
                MOVB    r6, 0efh
                CAL     tps_interp_exact_match_sub_rom_load_00026h_dp
                MB      C, PSWL.4
                MB      off(0022bh).5, C
                MB      C, PSWL.5
                MB      off(0022bh).4, C
                STB     A, 0cch
                LB      A, r6
                STB     A, 0efh
                MB      C, off(00229h).6
                MB      off(00229h).7, C
                LB      A, #002h
                JGE     tps_interp_exact_match_cmp_acc_2
                SUBB    A, #001h
tps_interp_exact_match_cmp_acc_2:     CMPB    A, off(00291h)
                MB      off(00229h).6, C
                CLR     er1
                JBS     off(0021dh).2, tps_interp_exact_match_clear_ram218_bit4
                JBS     off(00211h).3, tps_interp_exact_match_clear_ram218_bit4
                JBR     off(0021bh).4, tps_interp_exact_match_load_ram28d
                MOVB    off(0028dh), #050h
                SJ      tps_interp_exact_match_load_er1
tps_interp_exact_match_load_ram28d:     LB      A, off(0028dh)
                JEQ     tps_interp_exact_match_clear_ram218_bit4
                DECB    off(0028dh)
tps_interp_exact_match_load_er1:     MOV     er1, off(0028eh)
                LB      A, off(00288h)
                JBR     off(00229h).6, tps_interp_exact_match_if_ram229_bit7_clr
                JBS     off(00229h).7, tps_interp_exact_match_load_r2
                MOV     X1, #rom_5372
                VCAL    2
                STB     A, r2
tps_interp_exact_match_load_r2:     LB      A, r2
                JEQ     tps_interp_exact_match_set_ram218_bit4
                DECB    r2
                SJ      tps_interp_exact_match_clear_ram218_bit4
tps_interp_exact_match_set_ram218_bit4:     SB      off(00218h).4
                SJ      tps_interp_exact_match_load_ram28e
tps_interp_exact_match_if_ram229_bit7_clr:     JBR     off(00229h).7, tps_interp_exact_match_load_r3
                MOV     X1, #rom_5376
                VCAL    2
                STB     A, r3
tps_interp_exact_match_load_r3:     LB      A, r3
                JEQ     tps_interp_exact_match_clear_ram218_bit4
                DECB    r3
                SJ      tps_interp_exact_match_load_r2
tps_interp_exact_match_clear_ram218_bit4:     RB      off(00218h).4
tps_interp_exact_match_load_ram28e:     MOV     off(0028eh), er1
                MB      C, 0a0h.7
                JLT     tps_interp_exact_match_load_r0
                J       tps_interp_exact_match_load_ie
                DB  000h,000h,000h
tps_interp_exact_match_load_r0:     MOVB    r0, off(0022bh)
                LB      A, #03ch
                JBS     off(0021dh).1, tps_interp_exact_match_andb_acc
                LB      A, #00fh
tps_interp_exact_match_andb_acc:     ANDB    A, r0
                JEQ     tps_interp_exact_match_if_ram21d_bit1_set
                MOV     DP, #tbl_aux_63f2
                MOVB    r0, #004h
                JBR     off(0021dh).1, tps_interp_exact_match_srlb_acc
                SWAPB
tps_interp_exact_match_srlb_acc:     SRLB    A
                JLT     tps_interp_exact_match_clear_acc
                CLRB    r0
                CMPB    off(00288h), #080h
                JLT     tps_interp_exact_match_srlb_acc_2
                INCB    r0
tps_interp_exact_match_srlb_acc_2:     SRLB    A
                JLT     tps_interp_exact_match_clear_acc
                MOVB    r0, #005h
                JBS     off(0022bh).2, tps_interp_exact_match_clear_acc
                MOVB    r0, #002h
                CMPB    off(00289h), #080h
                JLT     tps_interp_exact_match_clear_acc
                INCB    r0
tps_interp_exact_match_clear_acc:     CLR     A
                LB      A, r0
                ADD     DP, A
                LCB     A, [DP]
                J       tps_interp_exact_match_store_r0
tps_interp_exact_match_if_ram21d_bit1_set:     JBS     off(0021dh).1, tps_interp_exact_match_load_dp
                MOV     DP, #tbl_ign_lo_cam
                MOV     X1, 0cah
                LB      A, 0eeh
                JBS     off(00211h).3, tps_interp_exact_match_cmp_acc_3
                JBR     off(00218h).4, tps_interp_exact_match_load_r1
tps_interp_exact_match_cmp_acc_3:     CMPB    A, #00eh
                JGE     tps_interp_exact_match_load_r1
                CMPB    A, #004h
                JLT     tps_interp_exact_match_load_r1
                SUBB    A, #004h
                MOV     DP, #tbl_ign_lo_cam_alt1
                JBS     off(00220h).0, tps_interp_exact_match_load_r1
                MOV     DP, #tbl_ign_lo_cam_alt2
                SJ      tps_interp_exact_match_load_r1
tps_interp_exact_match_load_dp:     MOV     DP, #tbl_ign_hi_cam
                MOV     X1, 0cch
                LB      A, 0efh
                JBS     off(00211h).3, tps_interp_exact_match_cmp_acc_4
                JBR     off(00218h).4, tps_interp_exact_match_load_r1
tps_interp_exact_match_cmp_acc_4:     CMPB    A, #00eh
                JGE     tps_interp_exact_match_load_r1
                CMPB    A, #004h
                JLT     tps_interp_exact_match_load_r1
                SUBB    A, #004h
                MOV     DP, #tbl_ign_hi_cam_alt1
                JBS     off(00220h).0, tps_interp_exact_match_load_r1
                MOV     DP, #tbl_ign_hi_cam_alt2
tps_interp_exact_match_load_r1:     MOVB    r1, 0ech
                MOV     X2, 0c8h
                CAL     tipin_gate_common_sub_load_r0
tps_interp_exact_match_store_r0:     STB     A, r0
                LB      A, off(002bah)
                JEQ     tps_interp_exact_match_if_ram231_bit4_set
                MULB
                MOVB    r0, ACCH
tps_interp_exact_match_if_ram231_bit4_set:     JBS     off(00231h).4, tps_interp_exact_match_load_ram2c9
                JBR     off(00232h).2, tps_interp_exact_match_load_ram2aa
                LB      A, #002h
                ADDB    A, off(002c9h)
                JGE     tps_interp_exact_match_store_ram2c9
                LB      A, #0ffh
tps_interp_exact_match_store_ram2c9:     STB     A, off(002c9h)
                CMPB    A, r0
                MB      off(00232h).2, C
                JGE     tps_interp_exact_match_load_ram2aa
                STB     A, r0
                SJ      tps_interp_exact_match_load_ram2aa
tps_interp_exact_match_load_ram2c9:     MOVB    off(002c9h), r0
tps_interp_exact_match_load_ram2aa:     MOVB    off(002aah), r0
                CLRB    A
                JBR     off(00217h).0, idleign_result_store
                JBS     off(0022ch).6, idleign_result_store
                CMPB    0d9h, #044h
                JGE     idleign_result_store
                JBS     off(00224h).2, idleign_result_store
                L       A, 0b4h
                MOV     X1, #rom_50c8
                JBS     off(00216h).7, idleign_table_lookup
                MOV     X1, #rom_50dc
idleign_table_lookup:     CAL     idleign_table_lookup_sub_load_acc
                LB      A, ACC
                MOVB    r0, #015h
                CMPB    A, r0
                JLT     idleign_vcal6_check
                LB      A, r0
idleign_vcal6_check:     JBR     off(00216h).7, idleign_result_store
                VCAL    7
idleign_result_store:     STB     A, off(002adh)
                LB      A, #01dh
                JBS     off(00230h).7, idleign_result_store_cmp_ram0af
                LB      A, #00ch
idleign_result_store_cmp_ram0af:     CMPB    0afh, A
                MB      off(00230h).7, C
                LB      A, #03ah
                JBS     off(00231h).0, idleign_result_store_cmp_acc
                LB      A, #040h
idleign_result_store_cmp_acc:     CMPB    A, off(00289h)
                MB      off(00231h).0, C
                CLRB    A
                MOV     X1, #rom_5082
                JBS     off(00230h).6, knockretard_table_gate
                INC     X1
                MB      C, off(00230h).7
knockretard_table_gate:     JGE     knockretard_store
                L       A, off(00278h)
                ST      A, er3
                LB      A, off(00288h)
                CAL     knockretard_table_gate_sub_load_acc
                JBR     off(00230h).6, knockretard_store
                VCAL    7
knockretard_store:     STB     A, off(002b2h)
                J       knockretard_store_if_ram21d_bit2_clr
knockretard_store_load_ram289:     LB      A, off(00289h)
                MOV     X1, #rom_50be
                VCAL    0
                CMPB    A, 0e7h
                JLT     knockretard_store_goto_4f3e
                CMPB    A, 0abh
                JGE     knockretard_store_goto_4f3e
                CMPB    0e9h, #010h
                JLE     knockretard_store_goto_4f3e
                SB      off(00230h).5
                DECB    off(0029ch)
                J       knockretard_store_load_imm_2
                DB  000h
knockretard_store_goto_4f3e:     J       knockretard_store_load_ram280
knockretard_store_load_ram29c:     LB      A, off(0029ch)
                JEQ     knockretard_store_load_ram2ae
                DECB    off(0029ch)
                SJ      knockretard_store_goto_2422
knockretard_store_load_ram2ae:     LB      A, off(002aeh)
                JEQ     knockretard_store_goto_6e90
                ADDB    A, #004h
                JLT     knockretard_store_goto_6e90
                CMPB    A, r0
                J       knockretard_store_if_lt_goto_6dca
knockretard_store_goto_6e90:     J       knockretard_store_clear_ram230_bit5
                DB  0C4h,09Ch,098h,003h
knockretard_store_load_r0:     LB      A, r0
                NOP
knockretard_store_store_ram2ae:     STB     A, off(002aeh)
knockretard_store_goto_2422:     J       knockretard_store_load_imm
                DB  000h,0EDh,01Fh,035h
knockretard_store_load_imm:     LB      A, #03ah
                JBS     off(00230h).2, knockretard_store_cmp_acc
                LB      A, #040h
knockretard_store_cmp_acc:     CMPB    A, off(00289h)
                MB      off(00230h).2, C
                CLRB    A
                JGE     knockretard_store_store_ram2b0
                JBS     off(00211h).1, knockretard_store_store_ram2b0
                JBS     off(0021ch).3, knockretard_store_store_ram2b0
                JBS     off(00216h).6, knockretard_store_store_ram2b0
                J       knockretard_store_if_ram216_bit5_clr
knockretard_store_clear_acc:     CLR     A
                LB      A, off(002b1h)
                MOV     er3, A
                LB      A, off(00288h)
                MOV     X1, #rom_507e
                CAL     knockretard_table_gate_sub_load_acc
                STB     A, r6
                LB      A, off(002b0h)
                ADDB    A, #001h
                JGE     knockretard_store_cmp_acc_2
                LB      A, #0ffh
knockretard_store_cmp_acc_2:     CMPB    A, r6
                JLT     knockretard_store_store_ram2b0
                LB      A, r6
knockretard_store_store_ram2b0:     STB     A, off(002b0h)
                MOVB    r0, off(002cbh)
                MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     knockretard_store_call_4f90
                LB      A, #0ffh
knockretard_store_call_4f90:     CAL     knockretard_store_sub_vcal_7
                LB      A, (001e5h-00180h)[USP]
                JNE     knockretard_store_if_ram21d_bit5_clr
                JBS     off(0021ch).7, knockretard_store_load_ram2ab
knockretard_store_if_ram21d_bit5_clr:     JBR     off(0021dh).5, knockretard_store_load_ram2ab
                MOV     DP, #rom_517b
                MOV     X1, 0cch
                LB      A, 0efh
                JBS     off(0021dh).1, knockretard_store_call_4523
                MOV     DP, #rom_518f
                MOV     X1, 0cah
                LB      A, 0eeh
knockretard_store_call_4523:     CAL     scale_result_common_sub_extnd_acc
                VCAL    7
                JEQ     knockretard_store_load_r6
                STB     A, r6
                LB      A, off(002abh)
                SUBB    A, #002h
                JGT     knockretard_store_cmp_acc_3
                LB      A, #001h
knockretard_store_cmp_acc_3:     CMPB    A, r6
                JGE     knockretard_store_store_ram2ab
knockretard_store_load_r6:     LB      A, r6
                SJ      knockretard_store_store_ram2ab
knockretard_store_load_ram2ab:     LB      A, off(002abh)
                JEQ     knockretard_store_store_ram2ab
                ADDB    A, #002h
                JGE     knockretard_store_store_ram2ab
                CLRB    A
knockretard_store_store_ram2ab:     STB     A, off(002abh)
                LB      A, off(00289h)
                CMPB    A, #0f0h
                JGE     knockretard_store_goto_253c
                CMPB    A, #02dh
                JLT     knockretard_store_goto_253c
                LB      A, 0dfh
                CMPB    A, #064h
                JGE     knockretard_store_goto_253c
                CMPB    A, #00ch
                JLT     knockretard_store_goto_253c
                L       A, off(00210h)
                AND     A, #08074h
                JNE     knockretard_store_goto_253c
                JBS     off(00212h).0, knockretard_store_goto_253c
                JBS     off(00220h).0, knockretard_store_goto_253c
                JBS     off(0021dh).2, knockretard_store_goto_253c
                CMPB    0d9h, #034h
                JGE     knockretard_store_goto_253c
                SJ      knockretard_store_if_ram230_bit0_set
knockretard_store_goto_253c:     J       knockretard_store_clear_ram230_bit0
knockretard_store_if_ram230_bit0_set:     JBS     off(00230h).0, knockretard_store_if_ram219_bit4_set
                MOV     X1, #rom_515a
                LB      A, off(00289h)
                VCAL    0
                CMPB    A, 0e7h
                LB      A, off(002a2h)
                JLT     knockretard_store_if_eq_goto_253c
                JNE     knockretard_store_store_r0
                JBR     off(00219h).0, tipin_decay_zero
                CMPB    0e9h, #010h
                JLT     tipin_decay_zero
                SB      off(00230h).0
knockretard_store_if_ram219_bit4_set:     JBS     off(00219h).4, knockretard_store_load_x1
                CMP     0b0h, #0ffffh
                JGE     tipin_decay_zero
knockretard_store_load_x1:     MOV     X1, #rom_5168
                LB      A, off(00289h)
                VCAL    0
                MOVB    r0, off(002a5h)
                MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     knockretard_store_vcal_7
                LB      A, #0ffh
knockretard_store_vcal_7:     VCAL    7
                RB      off(00230h).0
                MOVB    off(002a3h), #018h
                SJ      knockretard_store_store_r0
knockretard_store_if_eq_goto_253c:     JEQ     knockretard_store_clear_ram230_bit0
knockretard_store_store_r0:     STB     A, r0
                LB      A, off(002a3h)
                JEQ     knockretard_store_load_r0_2
                DECB    off(002a3h)
                JBS     off(00219h).4, knockretard_store_load_r0_2
                CMP     0b0h, #00004h
                LB      A, r0
                JGE     tipin_decay_zero_clear_carry
knockretard_store_load_r0_2:     LB      A, r0
                JEQ     knockretard_store_set_carry
                ADDB    A, #001h
                JGE     knockretard_store_set_carry
                CLRB    A
knockretard_store_set_carry:     SC
                SJ      tipin_decay_zero_store_carry_ram230_bit1
knockretard_store_clear_ram230_bit0:     RB      off(00230h).0
tipin_decay_zero:     CLRB    A
tipin_decay_zero_clear_carry:     RC
tipin_decay_zero_store_carry_ram230_bit1:     MB      off(00230h).1, C
                STB     A, off(002a2h)
                CLRB    A
                JBR     off(0021bh).3, tipin_decay_zero_store_ram2cc
                JBS     off(00217h).0, tipin_decay_zero_store_ram2cc
                CMPB    0d9h, #000h
                JGE     tipin_decay_zero_store_ram2cc
                JBR     off(0021ch).0, tipin_decay_zero_store_ram2cc
                LB      A, #015h
tipin_decay_zero_store_ram2cc:     STB     A, off(002cch)
                LB      A, #0d0h
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc
                LB      A, #0cdh
tipin_decay_zero_cmp_acc:     CMPB    A, off(00289h)
                JLT     tipin_decay_zero_clear_carry_2
                JBS     off(00220h).0, tipin_decay_zero_clear_carry_2
                LB      A, off(00210h)
                ANDB    A, #0b4h
                JNE     tipin_decay_zero_clear_carry_2
                JBS     off(00211h).0, tipin_decay_zero_clear_carry_2
                JBS     off(00212h).0, tipin_decay_zero_clear_carry_2
                JBS     off(0021dh).2, tipin_decay_zero_clear_carry_2
                LB      A, #07ah
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc_2
                LB      A, #080h
tipin_decay_zero_cmp_acc_2:     CMPB    A, off(00289h)
                JGE     tipin_decay_zero_store_carry_ram231_bit1
                LB      A, #09ch
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc_3
                LB      A, #092h
tipin_decay_zero_cmp_acc_3:     CMPB    A, off(00288h)
                JLT     tipin_decay_zero_clear_carry_2
                LB      A, #02ch
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc_4
                LB      A, #033h
tipin_decay_zero_cmp_acc_4:     CMPB    A, off(00288h)
                JGE     tipin_decay_zero_store_carry_ram231_bit1
                LB      A, off(002a2h)
                JNE     tipin_decay_zero_clear_carry_2
                CMPB    0d9h, #034h
                JGE     tipin_decay_zero_store_carry_ram231_bit1
                JBR     off(00216h).5, tipin_decay_zero_clear_carry_2
                SJ      tipin_decay_zero_store_carry_ram231_bit1
tipin_decay_zero_clear_carry_2:     RC
tipin_decay_zero_store_carry_ram231_bit1:     MB      off(00231h).1, C
                MOV     DP, #tipin_decay_zero_tbl
                JBS     off(0021dh).0, tipin_decay_zero_load_ram0ef
                LB      A, (001b4h-00180h)[USP]
                JEQ     tipin_decay_zero_store_ram2c4
                MOV     DP, #tipin_decay_zero_tbl_2
tipin_decay_zero_load_ram0ef:     LB      A, 0efh
                MOV     X1, 0cch
                JBS     off(0021dh).1, tipin_decay_zero_call_4523
                LB      A, 0eeh
                MOV     X1, 0cah
                SUB     DP, #00014h
tipin_decay_zero_call_4523:     CAL     scale_result_common_sub_extnd_acc
                SUBB    A, #080h
tipin_decay_zero_store_ram2c4:     STB     A, off(002c4h)
                SC
                JBR     off(00221h).1, tipin_decay_zero_store_carry_ram238_bit0
                LB      A, (001a2h-00180h)[USP]
                CMPB    A, #007h
                JLT     tipin_decay_zero_store_carry_ram238_bit0
                LB      A, (001aah-00180h)[USP]
                CMPB    A, #019h
                JLT     tipin_decay_zero_store_carry_ram238_bit0
                MB      C, off(0021ah).7
tipin_decay_zero_store_carry_ram238_bit0:     MB      off(00238h).0, C
                CLRB    A
                RC
                JBS     off(00238h).0, scale_result_common_store_carry_ram238_bit1
                JBS     off(00210h).3, scale_result_common_store_carry_ram238_bit1
                JBS     off(00211h).0, scale_result_common_store_carry_ram238_bit1
                L       A, 0d0h
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
scale_result_common_store_carry_ram238_bit1:     MB      off(00238h).1, C
                SRLB    A
                MB      off(00238h).2, C
                STB     A, r5
                CLRB    A
                JBR     off(00221h).1, scale_result_common_store_ram2b4
                CMPB    off(00289h), #00dh
                JLT     scale_result_common_vcal_7
                JBS     off(00232h).4, scale_result_common_load_ram0ef
                NOP
                NOP
                NOP
                JBS     off(00212h).7, scale_result_common_load_ram0ef
                JBS     off(00238h).0, scale_result_common_load_ram289
                JBS     off(00238h).1, scale_result_common_load_ram289
                LB      A, r5
                SJ      scale_result_common_vcal_7
scale_result_common_load_ram0ef:     LB      A, 0efh
                MOV     X1, 0cch
                MOV     DP, #scale_result_common_tbl_2
                JBS     off(0021dh).1, scale_result_common_call_4523
                LB      A, 0eeh
                MOV     X1, 0cah
                MOV     DP, #scale_result_common_tbl_3
scale_result_common_call_4523:     CAL     scale_result_common_sub_extnd_acc
scale_result_common_vcal_7:     VCAL    7
scale_result_common_store_ram2b4:     STB     A, off(002b4h)
scale_result_common_load_ram289:     LB      A, off(00289h)
                MOV     X1, #rom_5046
                VCAL    0
                STB     A, off(002b7h)
                LB      A, #0ffh
                JBS     off(00232h).1, scale_result_common_cmp_acc
                LB      A, #0ffh
scale_result_common_cmp_acc:     CMPB    A, off(00289h)
                MB      off(00232h).1, C
                LB      A, off(00289h)
                MOV     X1, #rom_5000
                VCAL    0
                STB     A, off(002a7h)
                STB     A, r0
                LB      A, off(002a8h)
                MULB
                L       A, ACC
                MOVB    r0, #0d0h
                MOVB    r1, #015h
                SLL     A
                JLT     scale_result_common_load_r0
                SLL     A
                JLT     scale_result_common_load_r0
                LB      A, ACCH
                CMPB    A, r0
                JGE     scale_result_common_load_r0
                CMPB    A, r1
                JGE     scale_result_common_store_ram2a9
                MOVB    r0, r1
scale_result_common_load_r0:     LB      A, r0
scale_result_common_store_ram2a9:     STB     A, off(002a9h)
                JBS     off(00232h).1, scale_result_common_srlb_acc
                SRLB    A
scale_result_common_srlb_acc:     SRLB    A
                CMPB    A, r1
                JGE     scale_result_common_store_ram2c7
                LB      A, r1
scale_result_common_store_ram2c7:     STB     A, off(002c7h)
                LB      A, #0c8h
                JBS     off(00231h).2, scale_result_common_cmp_acc_2
                LB      A, #0d0h
scale_result_common_cmp_acc_2:     CMPB    A, off(002a9h)
                MB      off(00231h).2, C
                MOV     DP, #rom_511e
                MOV     X1, 0cch
                LB      A, 0efh
                JBS     off(0021dh).1, scale_result_common_if_ram231_bit2_set
                MOV     DP, #rom_5146
                MOV     X1, 0cah
                LB      A, 0eeh
scale_result_common_if_ram231_bit2_set:     JBS     off(00231h).2, scale_result_common_call_4523_2
                SUB     DP, #00014h
                JBR     off(0021dh).0, scale_result_common_call_4523_2
                MOV     DP, #scale_result_common_tbl
                JBS     off(0021dh).1, scale_result_common_call_4523_2
                ADD     DP, #00014h
scale_result_common_call_4523_2:     CAL     scale_result_common_sub_extnd_acc
                STB     A, off(002b6h)
                CLR     er3
                JBS     off(00210h).5, scale_result_common_load_ram2b4
                JBR     off(00230h).1, scale_result_common_load_ram2ca
                LB      A, off(002a2h)
                CAL     scale_result_common_sub_extnd_acc_2
scale_result_common_load_ram2ca:     LB      A, off(002cah)
                CAL     scale_result_common_sub_extnd_acc_2
                LB      A, off(002afh)
                CAL     scale_result_common_sub_extnd_acc_2
                LB      A, off(002abh)
                CAL     scale_result_common_sub_extnd_acc_2
                LB      A, off(002b2h)
                EXTND
                ADD     er3, A
                LB      A, off(002aeh)
                EXTND
                ADD     er3, A
                LB      A, off(002adh)
                CAL     scale_result_common_sub_extnd_acc_3
                LB      A, off(002c4h)
                EXTND
                ADD     er3, A
                CLR     A
                LB      A, off(002cch)
                L       A, ACC
                ADD     er3, A
                LB      A, off(002b3h)
                EXTND
                ADD     er3, A
scale_result_common_load_ram2b4:     LB      A, off(002b4h)
                EXTND
                ADD     er3, A
                LB      A, off(002ach)
                EXTND
                ADD     er3, A
                CLR     A
                LB      A, off(002aah)
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
                JBR     off(00231h).1, ign_sum_result_store_r5
                LB      A, #0b3h
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
                SC
                JBS     off(00210h).5, ign_p40_toggle_store_carry_ram231_bit3
                CMPB    0d9h, #0c5h
                JLT     ign_p40_toggle_store_carry_ram231_bit3
                LB      A, #037h
                MB      C, P3.3
                JLT     ign_p40_clamp_store_r4
                LB      A, #000h
                MB      C, off(0021ah).5
                JLT     ign_p40_clamp_store_r4
                JBS     off(00231h).3, ign_p40_toggle_load_r4
                JBR     off(00217h).0, ign_p40_toggle
                LB      A, off(002b5h)
                ADDB    A, #004h
                JGE     ign_p40_clamp
                LB      A, #0ffh
ign_p40_clamp:     CMPB    A, r4
                JGE     ign_p40_toggle
ign_p40_clamp_store_r4:     STB     A, r4
                STB     A, r5
                STB     A, off(002b5h)
ign_p40_toggle:     XORB    PSWH, #080h
ign_p40_toggle_store_carry_ram231_bit3:     MB      off(00231h).3, C
ign_p40_toggle_load_r4:     LB      A, r4
                CMPB    A, off(002b6h)
                JGE     ign_p40_toggle_store_r4
                LB      A, off(002b6h)
ign_p40_toggle_store_r4:     STB     A, r4
                ADDB    A, off(002b7h)
                JGE     ign_p40_toggle_store_ram2b8
                LB      A, #0ffh
ign_p40_toggle_store_ram2b8:     STB     A, off(002b8h)
                LB      A, r5
                CMPB    A, off(002b6h)
                JGE     ign_p40_toggle_store_r5
                LB      A, off(002b6h)
ign_p40_toggle_store_r5:     STB     A, r5
                ADDB    A, off(002b7h)
                JGE     ign_p40_toggle_store_ram2b9
                LB      A, #0ffh
ign_p40_toggle_store_ram2b9:     STB     A, off(002b9h)
                MOV     off(00282h), er2
                MOVB    r2, off(002b8h)
                MOVB    r4, off(002a9h)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #0038dh
                RB      PSWH.0
                MB      09eh.6, C
                STB     A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                SB      PSWH.0
                MOVB    r2, off(002b9h)
                MOVB    r4, off(002a9h)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #00391h
                RB      PSWH.0
                MB      09eh.7, C
                ST      A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                SB      PSWH.0
                MOVB    r2, off(002b8h)
                MOVB    r4, off(002c7h)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #00395h
                RB      PSWH.0
                MB      09fh.0, C
                ST      A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                SB      PSWH.0
                LB      A, off(002d5h)
                JNE     ign_p40_toggle_clear_carry
                JBR     off(0022ah).0, ign_p40_toggle_clear_carry
                MB      C, P4.7
                JBS     off(00238h).3, ign_p40_toggle_if_lt_goto_280c
                XORB    PSWH, #080h
                JLT     dtc27_code27_latch
                SJ      ign_p40_toggle_set_carry
ign_p40_toggle_if_lt_goto_280c:     JLT     dtc27_code27_latch
                RB      P2A.2
                JBS     off(00238h).3, ign_p40_toggle_store_carry_ram238_bit3
ign_p40_toggle_set_carry:     SC
ign_p40_toggle_store_carry_ram238_bit3:     MB      off(00238h).3, C
                JLT     ign_p40_toggle_clear_carry
                MOVB    off(002d5h), #019h
ign_p40_toggle_clear_carry:     RC
dtc27_code27_latch:     MB      09bh.2, C
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                MB      C, 0a0h.7
                JLT     ign_p40_toggle_load_lrb
                J       ign_p40_toggle_load_ie
                DB  000h,000h,000h
ign_p40_toggle_load_lrb:     MOV     LRB, #00020h
                MOV     USP, #00280h
                L       A, (00214h-00280h)[USP]
                ST      A, off(00114h)
                L       A, (00216h-00280h)[USP]
                ST      A, off(00116h)
                L       A, (00218h-00280h)[USP]
                ST      A, off(00118h)
                L       A, #01d4ch
                JBS     off(0011bh).5, ign_p40_toggle_cmp_ram0ae
                L       A, #00b45h
ign_p40_toggle_cmp_ram0ae:     CMP     0aeh, A
                MB      off(0011bh).5, C
                LB      A, #0ffh
                JBS     off(0011dh).3, ign_p40_toggle_cmp_acc
                LB      A, #0ffh
ign_p40_toggle_cmp_acc:     CMPB    A, off(00178h)
                MB      off(0011dh).3, C
                LB      A, #0ffh
                JBR     off(00120h).4, ign_p40_toggle_store_ram1e7
                JBS     off(00116h).1, ign_p40_toggle_store_ram1e7
                JBS     off(00115h).0, ign_p40_toggle_if_ram115_bit1_set
ign_p40_toggle_store_ram1e7:     STB     A, off(001e7h)
                J       vtec_state_active_check_clear_acc
ign_p40_toggle_if_ram115_bit1_set:     JBS     off(00115h).1, ign_p40_toggle_store_ram1e7
                JBR     off(0011dh).3, ign_p40_toggle_store_ram1e7
                JBR     off(00117h).2, ign_p40_toggle_store_ram1e7
                JBS     off(00113h).1, ign_p40_toggle_if_ram124_bit3_clr
                CMPB    0deh, #0f6h
                JGT     ign_p40_toggle_if_ram124_bit3_clr
                CMPB    0deh, #004h
                JLT     ign_p40_toggle_if_ram124_bit3_clr
                STB     A, off(001e7h)
                MOVB    r1, off(001b4h)
                LB      A, off(001b2h)
                JNE     ign_p40_toggle_subb_acc
                J       ign_p40_toggle_load_imm_2
                DB  000h,000h,077h,0FFh,0C7h,079h,0C4h,031h
                DB  03Eh,020h,015h,0CDh,002h,098h,002h,077h
                DB  0FFh,0EFh,031h,002h,077h,0FFh,0C7h,078h
                DB  0C4h,031h,03Fh,0CDh,001h,0A8h
ign_p40_toggle_clear_r1:     CLRB    r1
                CMPB    0deh, #0ffh
                JLE     ign_p40_toggle_load_imm
                INCB    r1
                LB      A, #006h
                MULB
                EXTND
                ADD     A, #ign_p40_toggle_tbl
                MOV     DP, A
                LB      A, 0deh
                CMPCB   A, [DP]
                JLE     ign_p40_toggle_load_imm
                INCB    r1
                JBS     off(00110h).3, ign_p40_toggle_load_imm
                JBS     off(00110h).7, ign_p40_toggle_load_imm
                DECB    r1
ign_p40_toggle_cmp_acc_2:     CMPCB   A, [DP]
                JLE     ign_p40_toggle_load_imm
                INC     DP
                INCB    r1
                CMPB    r1, #007h
                JLT     ign_p40_toggle_cmp_acc_2
ign_p40_toggle_load_imm:     LB      A, #0ffh
                JBR     off(0011ah).6, ign_p40_toggle_store_ram1b2
                SRLB    A
                JBR     off(00128h).1, ign_p40_toggle_store_ram1b2
                SRLB    A
                SJ      ign_p40_toggle_store_ram1b2
ign_p40_toggle_subb_acc:     SUBB    A, #001h
ign_p40_toggle_store_ram1b2:     STB     A, off(001b2h)
                SJ      vtec_rpm_valid_check
ign_p40_toggle_if_ram124_bit3_clr:     JBR     off(00124h).3, vtec_state_dispatch
                STB     A, off(001e7h)
vtec_state_reset_no_pressure:     MOVB    off(001e8h), #0ffh
                MOVB    r1, #004h
                SJ      vtec_rpm_valid_check
vtec_state_dispatch:     LB      A, off(001e7h)
                JNE     vtec_state_reset_no_pressure
                LB      A, off(001e8h)
                JEQ     vtec_state_active_check_clear_acc
                MOVB    r1, #002h
vtec_rpm_valid_check:     CMPB    off(00179h), #0ffh
                JGE     vtec_rpm_valid_check_cmp_r1
                JBS     off(0011dh).0, vtec_state_confirm
                SJ      vtec_state_active_check_clear_acc
vtec_rpm_valid_check_cmp_r1:     CMPB    r1, #001h
                JLE     vtec_state_active_check
                MOVB    off(001f6h), #0ffh
                SJ      vtec_state_store
vtec_state_active_check:     JBR     off(0011dh).0, vtec_state_active_check_load_r1
vtec_state_confirm:     LB      A, off(001f6h)
                JEQ     vtec_state_active_check_load_r1
                MOVB    r1, #002h
                CLRB    off(001b2h)
vtec_state_store:     LB      A, r1
                STB     A, off(001b4h)
                SB      off(0011dh).0
                JNE     vtec_state_store_cmp_ram1b6
                MOVB    off(001b6h), #00ch
                CLRB    A
                STB     A, off(001aeh)
vtec_state_store_cmp_ram1b6:     CMPB    off(001b6h), #008h
                JGT     vtec_state_store_goto_2948
                CLR     A
                LB      A, r1
                MOV     DP, #tbl_cfg_69c6
                ADD     DP, A
                LCB     A, [DP]
                STB     A, off(001aeh)
vtec_state_store_goto_2948:     SJ      vtec_state_store_goto_6e00
vtec_state_active_check_load_r1:     LB      A, r1
                CMPB    A, #001h
                JEQ     vtec_state_active_check_store_ram1b4
vtec_state_active_check_clear_acc:     CLRB    A
vtec_state_active_check_store_ram1b4:     STB     A, off(001b4h)
                RB      off(0011dh).0
                CLRB    off(001b2h)
vtec_state_store_goto_6e00:     J       vtec_state_store_set_carry
                DW  00000h
vtec_state_store_load_x1:     MOV     X1, 0cch
                JBS     off(0011dh).1, vtec_state_store_call_4523
                LB      A, 0eeh
                MOV     DP, #tbl_6a4f
                MOV     X1, 0cah
vtec_state_store_call_4523:     CAL     scale_result_common_sub_extnd_acc
                LB      A, 0e3h
                CMPB    A, r6
                JGE     vtec_state_store_store_ram135
                LB      A, r6
vtec_state_store_store_ram135:     STB     A, off(00135h)
                LB      A, #0cah
                JBS     off(0012eh).7, vtec_state_store_cmp_acc
                LB      A, #0cdh
vtec_state_store_cmp_acc:     CMPB    A, off(00179h)
                MB      off(0012eh).7, C
                MOV     DP, #tbl_fuel_row_mult_hi40
                MOV     X1, 0cch
                LB      A, 0efh
                J       vtec_state_store_if_ram11d_bit1_set
                DB  0EFh,02Eh,00Bh
vtec_state_store_if_ram11d_bit1_set:     JBS     off(0011dh).1, vtec_state_store_call_48d2
                MOV     DP, #tbl_fuel_row_mult_lo40
                MOV     X1, 0cah
                LB      A, 0eeh
vtec_state_store_call_48d2:     CAL     vtec_state_store_sub_clear_acch
                MOVB    r0, 0e9h
                JBS     off(00119h).0, vtec_state_store_clear_ram12d_bit3
                LB      A, #006h
                CMPB    A, r0
                MB      off(0012dh).3, C
                LB      A, #00ah
                CMPB    A, r0
                MB      off(0012dh).4, C
                RC
                SJ      vtec_state_store_store_carry_ram12d_bit2
vtec_state_store_clear_ram12d_bit3:     RB      off(0012dh).3
                RB      off(0012dh).4
                LB      A, #005h
                CMPB    A, r0
vtec_state_store_store_carry_ram12d_bit2:     MB      off(0012dh).2, C
                JBS     off(0011ah).6, tipin_gate_common_clear_acc
                JBS     off(0011dh).0, tipin_gate_common_clear_acc
                JBS     off(00114h).0, tipin_gate_common_clear_acc
                JBR     off(0012dh).2, accelenrich_clear_pulse_check
                JBR     off(00119h).1, tipin_gate_common_load_ram146
                JBR     off(0012dh).5, vtec_state_store_load_imm
                CMPB    0e1h, #0d0h
                JGE     tipin_gate_common_clear_acc
                CMPB    0e7h, #09ah
                JGE     tipin_gate_common_clear_acc
                CAL     accelenrich_base_calc
                RB      off(0012eh).1
                SJ      tipin_gate_common_clear_ram182
accelenrich_clear_pulse_check:     JBR     off(0012dh).4, accelenrich_clear_pulse_check_cmp_ram179
                CLR     off(00146h)
accelenrich_clear_pulse_check_cmp_ram179:     CMPB    off(00179h), #053h
                JLT     tipin_gate_common_load_ram146
                JBR     off(0012dh).3, tipin_gate_common
                JBR     off(00119h).1, tipin_gate_common
                CAL     accelenrich_clear_pulse_check_sub_load_x1
                SJ      tipin_gate_common_store_ram182
tipin_gate_common:     LB      A, off(00182h)
                JEQ     tipin_gate_common_load_ram146
                ADDB    A, #002h
                JLT     tipin_gate_common_load_ram146
                SJ      tipin_gate_common_store_ram182
tipin_gate_common_clear_acc:     CLRB    A
tipin_gate_common_store_ram182:     STB     A, off(00182h)
                CLR     A
                SJ      tipin_gate_common_store_ram146
tipin_gate_common_load_ram146:     L       A, off(00146h)
                JEQ     tipin_gate_common_clear_ram182
                CMP     A, #00000h
                MOV     er0, #00093h
                JLT     tipin_gate_common_sub_acc
                MOV     er0, #00093h
tipin_gate_common_sub_acc:     SUB     A, er0
                JLT     tipin_gate_common_clear_acc
                SB      off(0012eh).1
                SJ      tipin_gate_common_clear_ram182
vtec_state_store_load_imm:     LB      A, #006h
                CMPB    A, 0f0h
                JLT     vtec_state_store_load_ram18e
                JBS     off(0012eh).1, tipin_gate_common_load_ram146
vtec_state_store_load_ram18e:     LB      A, off(0018eh)
                CAL     accelenrich_rpm_tier1_clear_acch
tipin_gate_common_clear_ram182:     CLRB    off(00182h)
tipin_gate_common_store_ram146:     STB     A, off(00146h)
                CMPB    A, #001h
                NOP
                MB      off(0012dh).5, C
                JBS     off(00116h).1, Cranking
                J       tipin_gate_common_clear_ram09f_bit1
Cranking:     MOV     X1, #rom_537a
                LB      A, 0d9h
                VCAL    1
                STB     A, off(0013eh)
                MOV     X1, #Cranking_tbl
                L       A, 0aeh
                CAL     idleign_table_lookup_sub_load_acc
                LB      A, r6
                STB     A, off(00180h)
                MOV     X1, #rom_5393
                LB      A, 0e0h
                VCAL    2
                STB     A, off(00183h)
                MOVB    r0, off(00180h)
                MULB
                L       A, ACC
                MOV     er0, off(0013eh)
                MUL
                SLL     A
                ROL     er1
                JLT     Cranking_load_imm
                SLL     A
                L       A, er1
                ROL     A
                JGE     Cranking_add_acc
Cranking_load_imm:     L       A, #0ffffh
Cranking_add_acc:     ADD     A, off(00146h)
                JGE     Cranking_load_carry_ram09f_bit1
                L       A, #0ffffh
Cranking_load_carry_ram09f_bit1:     MB      C, 09fh.1
                JGE     crankfuel_add_adjust
                SRL     A
                SRL     A
crankfuel_add_adjust:     ADD     A, off(00142h)
                JGE     crankfuel_add_adjust_load_dp
                L       A, #0ffffh
crankfuel_add_adjust_load_dp:     MOV     DP, #00382h
                ST      A, [DP]
                INC     DP
                INC     DP
                RB      PSWH.0
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                SB      PSWH.0
                JBR     off(00111h).6, crankfuel_add_adjust_if_ram110_bit7_set
                SB      off(0011ah).0
                SJ      postfuel_calc_start
crankfuel_add_adjust_if_ram110_bit7_set:     JBS     off(00110h).7, crankfuel_add_adjust_if_ram111_bit0_set
                JBR     off(00127h).6, crankfuel_add_adjust_load_carry_ram09f_bit1
crankfuel_add_adjust_if_ram111_bit0_set:     JBS     off(00111h).0, postfuel_calc_start
                JBS     off(00127h).7, postfuel_calc_start
crankfuel_add_adjust_load_carry_ram09f_bit1:     MB      C, 09fh.1
                JLT     crankfuel_add_adjust_load_dp_2
                CMPB    off(0019dh), #004h
                JNE     postfuel_calc_start
                CMPB    0d9h, #0eah
                JGE     postfuel_calc_start
crankfuel_add_adjust_load_dp_2:     MOV     DP, #0004ch
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
postfuel_calc_start:     SB      off(0011dh).4
                LB      A, 0d9h
                CMPB    A, #0c8h
                MB      PSWL.5, C
                MOV     X1, #rom_522a
                VCAL    1
                STB     A, off(00158h)
                CLRB    off(00157h)
                MOV     er2, #02000h
                SUBB    A, r2
                STB     A, r3
                CLRB    r0
                MOVB    r1, #0b3h
                MB      C, PSWL.5
                JLT     postfuel_hyst_upper_calc
                MOVB    r1, #080h
postfuel_hyst_upper_calc:     MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(0015ah)
                L       A, er3
                MOVB    r1, #066h
                MB      C, PSWL.5
                JLT     postfuel_hyst_lower_calc
                MOVB    r1, #04ch
postfuel_hyst_lower_calc:     MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(0015ch)
                LB      A, off(0017bh)
                MOVB    r0, A
                LB      A, #066h
                MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     postfuel_hyst_lower_calc_cmp_acc
                LB      A, #0ffh
postfuel_hyst_lower_calc_cmp_acc:     CMPB    A, #040h
                JGE     accel_iac_store
                LB      A, #040h
accel_iac_store:     STB     A, off(00181h)
                MOVB    off(0019fh), #057h
                J       accel_iac_store_if_ram11e_bit1_set
tipin_gate_common_clear_ram09f_bit1:     RB      09fh.1
                JBR     off(0011dh).4, tipin_gate_common_load_ram181
                L       A, #07000h
                CMPB    off(00159h), #02ah
                JLE     tipin_gate_common_load_imm
                CMP     off(00158h), off(0015ah)
                JGT     tipin_gate_common_subb_ram157
tipin_gate_common_load_imm:     L       A, #00b00h
                CMP     off(00158h), off(0015ch)
                JGT     tipin_gate_common_subb_ram157
                L       A, #00340h
tipin_gate_common_subb_ram157:     SUBB    off(00157h), A
                CLRB    A
                L       A, ACC
                SWAP
                MOV     er0, off(00158h)
                SBC     er0, A
                CMP     er0, #02000h
                JLE     tipin_gate_common_clear_ram11d_bit4
                MOV     off(00158h), er0
                LB      A, 0d9h
                CMPB    A, #02eh
                L       A, off(00158h)
                JLT     tipin_gate_common_store_ram15e
                JBR     off(00124h).0, tipin_gate_common_store_ram15e
                CLRB    r0
                MOVB    r1, #08dh
                MUL
                SLL     A
                ROL     er1
                L       A, er1
                JGE     tipin_gate_common_store_ram15e
                L       A, #0ffffh
                SJ      tipin_gate_common_store_ram15e
tipin_gate_common_clear_ram11d_bit4:     RB      off(0011dh).4
tipin_gate_common_load_ram181:     MOVB    off(00181h), #040h
                L       A, #02000h
                ST      A, off(00158h)
tipin_gate_common_store_ram15e:     ST      A, off(0015eh)
                MOVB    r6, #080h
                JBR     off(00118h).4, tipin_gate_common_load_r6
                J       tipin_gate_common_if_ram11d_bit1_set
                DB  0EFh,02Eh,01Bh
tipin_gate_common_if_ram11d_bit1_set:     JBS     off(0011dh).1, tipin_gate_common_load_ram0ef
                LB      A, 0eeh
                CMPB    A, #00eh
                JGE     tipin_gate_common_load_r6
                SUBB    A, #004h
                JLT     tipin_gate_common_load_r6
                MOV     DP, #tbl_corr_map_a_623a
                JBS     off(00120h).0, tipin_gate_common_load_x1
                MOV     DP, #tbl_corr_map_b_62a8
tipin_gate_common_load_x1:     MOV     X1, 0cah
                SJ      tipin_gate_common_load_r1
tipin_gate_common_load_ram0ef:     LB      A, 0efh
                CMPB    A, #00eh
                JGE     tipin_gate_common_load_r6
                SUBB    A, #004h
                JLT     tipin_gate_common_load_r6
                MOV     DP, #tbl_corr_map_c_6316
                JBS     off(00120h).0, tipin_gate_common_load_x1_2
                MOV     DP, #tbl_corr_map_d_6384
tipin_gate_common_load_x1_2:     MOV     X1, 0cch
tipin_gate_common_load_r1:     MOVB    r1, 0edh
                MOV     X2, 0c6h
                CAL     tipin_gate_common_sub_load_r0
tipin_gate_common_load_r6:     LB      A, r6
                STB     A, off(0018fh)
                LB      A, #0bah
                JBS     off(00130h).4, tipin_gate_common_cmp_acc
                LB      A, #0c0h
tipin_gate_common_cmp_acc:     CMPB    A, off(00179h)
                MB      off(00130h).4, C
                LB      A, #01dh
                JBR     off(00130h).6, tipin_gate_common_cmp_acc_2
                LB      A, #01bh
tipin_gate_common_cmp_acc_2:     CMPB    A, 0d9h
                MB      off(00130h).6, C
                LB      A, #017h
                JBR     off(00130h).5, tipin_gate_common_cmp_acc_3
                LB      A, #014h
tipin_gate_common_cmp_acc_3:     CMPB    A, 0d9h
                MB      off(00130h).5, C
                LB      A, off(00179h)
                CMPB    A, #040h
                MB      off(00130h).7, C
                MOV     X1, #rom_5267
                VCAL    0
                JBS     off(00130h).7, tipin_gate_common_store_r2
                JBS     off(00130h).5, tipin_gate_common_subb_acc
                LB      A, #050h
                XCHGB   A, r6
                SUBB    A, r6
                JGE     tipin_gate_common_store_r2
                CLRB    A
                SJ      tipin_gate_common_store_r2
tipin_gate_common_subb_acc:     SUBB    A, off(0019ah)
                JGE     tipin_gate_common_if_ram11f_bit5_clr
                CLRB    A
tipin_gate_common_if_ram11f_bit5_clr:     JBR     off(0011fh).5, tipin_gate_common_store_r2
                JBR     off(00130h).4, tipin_gate_common_store_r2
                STB     A, r2
                JBS     off(00115h).6, tipin_gate_common_load_imm_2
                JBR     off(00130h).6, tipin_gate_common_load_imm_2
                LB      A, off(00179h)
                MOV     X1, #rom_5277
                VCAL    0
                SUBB    A, off(0019ah)
                JGE     tipin_gate_common_load_ram1b7
                CLRB    A
                SJ      tipin_gate_common_load_ram1b7
tipin_gate_common_load_imm_2:     LB      A, #040h
                XCHGB   A, r2
                SUBB    A, r2
                JGE     tipin_gate_common_store_r2
                CLRB    A
tipin_gate_common_store_r2:     STB     A, r2
tipin_gate_common_load_ram1b7:     MOVB    off(001b7h), r2
                STB     A, r3
                LB      A, #008h
                STB     A, r4
                LB      A, r3
                SUBB    A, r4
                JGE     tipin_gate_common_store_ram1b9
                CLRB    A
tipin_gate_common_store_ram1b9:     STB     A, off(001b9h)
                CMPB    A, off(00178h)
                MB      off(0011ch).6, C
                LB      A, #010h
                STB     A, r4
                LB      A, off(00179h)
                MOV     X1, #tbl_inj_pw_volt_6911
                VCAL    0
                JBR     off(0011ch).4, tipin_gate_common_cmp_acc_4
                LB      A, #005h
                XCHGB   A, r6
                SUBB    A, r6
tipin_gate_common_cmp_acc_4:     CMPB    A, 0abh
                JLT     tipin_gate_common_clear_ram1e5
                LB      A, r2
                JBR     off(0011ch).4, tipin_gate_common_cmp_acc_5
                SUBB    A, r4
                JGE     tipin_gate_common_cmp_acc_5
                CLRB    A
tipin_gate_common_cmp_acc_5:     CMPB    A, off(00178h)
                JLT     tipin_gate_common_if_ram130_bit4_set
                LB      A, #005h
                STB     A, off(001e5h)
                SJ      tipin_gate_common_store_carry_ram11c_bit4
tipin_gate_common_if_ram130_bit4_set:     JBS     off(00130h).4, tipin_gate_common_clear_ram1e5
                LB      A, off(001e5h)
                JEQ     tipin_gate_common_set_carry
                RC
                SJ      tipin_gate_common_store_carry_ram11c_bit4
tipin_gate_common_clear_ram1e5:     CLRB    off(001e5h)
tipin_gate_common_set_carry:     SC
tipin_gate_common_store_carry_ram11c_bit4:     MB      off(0011ch).4, C
                NOP
                NOP
                NOP
                LB      A, r3
                JBR     off(0011dh).5, tipin_gate_common_store_ram1b8
                SUBB    A, r4
                JGE     tipin_gate_common_store_ram1b8
                CLRB    A
tipin_gate_common_store_ram1b8:     STB     A, off(001b8h)
                CMPB    A, off(00178h)
                CAL     tipin_gate_common_sub_store_carry_ram11d_bit5
                SC
                JBR     off(0011fh).5, tipin_gate_common_store_carry_ram11c_bit7
                JBS     off(00115h).6, tipin_gate_common_store_carry_ram11c_bit7
                MOVB    r4, #0ffh
                J       tipin_gate_common_if_ram130_bit6_set
tipin_gate_common_if_ram11c_bit6_set:     JBS     off(0011ch).6, tipin_gate_common_load_ram1db
                RB      off(00131h).0
                JEQ     tipin_gate_common_clear_ram1d9
                MOVB    off(001dah), off(001d9h)
tipin_gate_common_clear_ram1d9:     CLRB    off(001d9h)
                RC
                SJ      tipin_gate_common_store_carry_ram11c_bit7
tipin_gate_common_set_ram131_bit0:     SB      off(00131h).0
                CLRB    off(001dbh)
                MOVB    off(001d9h), r4
                SJ      tipin_gate_common_store_carry_ram11c_bit7
tipin_gate_common_load_ram1db:     LB      A, off(001dbh)
                SB      off(00131h).0
                JNE     tipin_gate_common_clear_ram1d8
                CLR     A
                LB      A, off(001d8h)
                MOV     er0, A
                LB      A, off(001dah)
                MOV     er1, A
                LB      A, off(001dbh)
                L       A, ACC
                ADD     A, er0
                SUB     A, er1
                MB      PSWL.4, C
                LB      A, ACC
                CMPB    ACCH, #000h
                JEQ     tipin_gate_common_cmp_acc_6
                CLRB    A
                MB      C, PSWL.4
                ADCB    A, #0ffh
tipin_gate_common_cmp_acc_6:     CMPB    A, r4
                JLT     tipin_gate_common_store_ram1db
                LB      A, r4
tipin_gate_common_store_ram1db:     STB     A, off(001dbh)
tipin_gate_common_clear_ram1d8:     CLRB    off(001d8h)
                CMPB    off(001d9h), A
                XORB    PSWH, #080h
tipin_gate_common_store_carry_ram11c_bit7:     MB      off(0011ch).7, C
                LB      A, #080h
                JBS     off(00118h).4, tipin_gate_common_store_ram193
                LB      A, 0efh
                MOV     X1, 0cch
                MOV     DP, #tbl_fuel_hi_cam
                JBS     off(0011dh).1, tipin_gate_common_load_r1_2
                LB      A, 0eeh
                MOV     X1, 0cah
                MOV     DP, #tbl_fuel_lo_cam
tipin_gate_common_load_r1_2:     MOVB    r1, 0edh
                MOV     X2, 0c6h
                CAL     tipin_gate_common_sub_load_r0
tipin_gate_common_store_ram193:     STB     A, off(00193h)
                SRLB    A
                JBS     off(0011dh).0, tipin_gate_common_clear_ram11c_bit3
                JBR     off(0011ch).5, tipin_gate_common_clear_ram11c_bit3
                JBR     off(0011ch).4, tipin_gate_common_if_ram11c_bit7_clr
                JBS     off(0011ch).7, tipin_gate_common_set_ram11c_bit3
                JBR     off(00130h).6, tipin_gate_common_set_ram11c_bit3
                MOV     DP, #tbl_allff_6923
                MOV     X1, 0cch
                LB      A, 0efh
                JBS     off(0011dh).1, tipin_gate_common_call_4523
                MOV     DP, #tbl_allff_6937
                MOV     X1, 0cah
                LB      A, 0eeh
tipin_gate_common_call_4523:     CAL     scale_result_common_sub_extnd_acc
                MOVB    r0, off(00193h)
                MULB
                LB      A, ACCH
                SJ      tipin_gate_common_set_ram11c_bit3
tipin_gate_common_if_ram11c_bit7_clr:     JBR     off(0011ch).7, tipin_gate_common_clear_ram11c_bit3
tipin_gate_common_set_ram11c_bit3:     SB      off(0011ch).3
                CMPB    A, off(0017bh)
                JGT     tipin_gate_common_set_ram11c_bit2
                SJ      tipin_gate_common_load_imm_3
tipin_gate_common_clear_ram11c_bit3:     RB      off(0011ch).3
                RB      off(00131h).1
tipin_gate_common_load_imm_3:     LB      A, #040h
                RB      off(0011ch).2
                SJ      tipin_gate_common_store_ram183
tipin_gate_common_set_ram11c_bit2:     SB      off(0011ch).2
                MOVB    r0, off(00199h)
                MULB
                SLL     ACC
                LB      A, ACCH
                JGE     tipin_gate_common_store_r4
                LB      A, #0ffh
tipin_gate_common_store_r4:     STB     A, r4
                LB      A, (002b4h-00280h)[USP]
                VCAL    7
                JBS     off(00131h).1, tipin_gate_common_cmp_acc_7
                CMPB    A, #00dh
                JLT     tipin_gate_common_cmp_acc_7
                SB      off(00131h).1
                SJ      tipin_gate_common_load_ram0ef_2
tipin_gate_common_cmp_acc_7:     CMPB    A, #007h
                JGE     tipin_gate_common_load_ram0ef_2
                RB      off(00131h).1
                SJ      tipin_gate_common_rom_load_tbl_6921
tipin_gate_common_load_ram0ef_2:     LB      A, 0efh
                MOV     DP, #tbl_corr_map_hi_6a8b
                MOV     X1, 0cch
                JBS     off(0011dh).1, tipin_gate_common_call_4523_2
                LB      A, 0eeh
                MOV     DP, #tbl_corr_map_lo_6a77
                MOV     X1, 0cah
tipin_gate_common_call_4523_2:     CAL     scale_result_common_sub_extnd_acc
                MOVB    r0, r4
                MULB
                SLL     ACC
                LB      A, ACCH
                JGE     tipin_gate_common_store_r4_2
                LB      A, #0ffh
tipin_gate_common_store_r4_2:     STB     A, r4
tipin_gate_common_rom_load_tbl_6921:     LC      A, tbl_dw_6921
                CMPB    A, r4
                JGE     tipin_gate_common_load_ram1dc
                STB     A, r4
tipin_gate_common_load_ram1dc:     LB      A, off(001dch)
                JNE     tipin_gate_common_load_r4
                LB      A, ACCH
                CMPB    A, r4
                JGE     tipin_gate_common_store_ram183
tipin_gate_common_load_r4:     LB      A, r4
tipin_gate_common_store_ram183:     STB     A, off(00183h)
                MB      C, off(0011ah).2
                MB      off(0011ah).3, C
                JBR     off(00120h).0, tipin_gate_common_if_ram11d_bit1_set_2
                JBR     off(0011ah).0, tipin_gate_common_if_ram11d_bit1_set_2
                LB      A, 0dfh
                CMPB    A, #064h
                JGE     tipin_gate_common_if_ram11d_bit1_set_2
                LB      A, 0ebh
                SUBB    A, 0dfh
                JLT     tipin_gate_common_if_ram124_bit5_set
                CMPB    A, #005h
                JGE     tipin_gate_common_set_ram12d_bit7
tipin_gate_common_if_ram124_bit5_set:     JBS     off(00124h).5, tipin_gate_common_if_ram11d_bit1_set_2
                JBS     off(0011ah).6, tipin_gate_common_if_ram11d_bit1_set_2
                JBS     off(00119h).5, tipin_gate_common_if_ram11d_bit1_set_2
                L       A, 0b2h
                CMP     A, #00160h
                JLT     tipin_gate_common_if_ram11d_bit1_set_2
                SB      off(0012eh).0
                SJ      tipin_gate_common_if_ram11d_bit1_set_2
tipin_gate_common_set_ram12d_bit7:     SB      off(0012dh).7
tipin_gate_common_if_ram11d_bit1_set_2:     JBS     off(0011dh).1, tipin_gate_common_load_x1_3
                MOV     X1, #rom_53cf
                JBR     off(0011ah).0, tipin_gate_common_load_ram179
                MOV     X1, #rom_53e7
                SJ      tipin_gate_common_load_ram179
tipin_gate_common_load_x1_3:     MOV     X1, #rom_53db
                JBR     off(0011ah).0, tipin_gate_common_load_ram179
                MOV     X1, #rom_53f3
tipin_gate_common_load_ram179:     LB      A, off(00179h)
                VCAL    0
                SUBB    A, off(00197h)
                JLT     tipin_gate_common_store_carry_ram130_bit0
                CMPB    A, off(00178h)
tipin_gate_common_store_carry_ram130_bit0:     MB      off(00130h).0, C
                LB      A, off(0016fh)
                MOVB    r0, #060h
                JBR     off(0011ah).0, postig_threshold_check1
                LB      A, off(0016eh)
                MOVB    r0, #04ch
postig_threshold_check1:     JBR     off(00115h).2, rpm_threshold_adjust
                CMPB    A, r0
                JGE     rpm_threshold_adjust
                LB      A, r0
rpm_threshold_adjust:     CMPB    0dfh, #028h
                JBR     off(00120h).0, rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold
                CMPB    0dfh, #007h
rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold:     JLT     rpm_secondary_threshold_check
                JBR     off(00130h).1, rpm_secondary_threshold_check
                JBS     off(0011ah).0, rpm_secondary_threshold_check
                ADDB    A, #020h
                JGE     rpm_secondary_threshold_check
                LB      A, #0ffh
rpm_secondary_threshold_check:     CMPB    A, off(00179h)
                MB      off(00130h).3, C
                LB      A, #074h
                JBS     off(00130h).2, revlimiter_engage_resume_check
                LB      A, #080h
revlimiter_engage_resume_check:     CMPB    A, off(00179h)
                MB      off(00130h).2, C
                RB      off(0011bh).3
                JBS     off(00111h).5, revlimiter_engage_resume_check_if_ram110_bit6_set
                MB      C, 099h.3
                JLT     revlimiter_engage_resume_check_if_ram110_bit6_set
                LB      A, ADCR4H
                CMPB    A, #008h
                JGE     revlimiter_engage_resume_check_load_ram16c
revlimiter_engage_resume_check_if_ram110_bit6_set:     JBS     off(00110h).6, vaccut_rpm_check
                MB      C, 098h.2
                JLT     vaccut_rpm_check
                CMPB    0abh, #02eh
                JGE     revlimiter_engage_resume_check_load_ram16c
                MOV     X1, #revlimiter_engage_resume_check_tbl
                LB      A, 0abh
                VCAL    2
                SJ      vaccut_rpm_check_cmp_acc
vaccut_rpm_check:     LB      A, #080h
vaccut_rpm_check_cmp_acc:     CMPB    A, off(00179h)
                JGE     ofc_enable_check_if_ram130_bit0_set
                SJ      revlimiter_fuelcut_set
revlimiter_engage_resume_check_load_ram16c:     L       A, off(0016ch)
                JBS     off(0011ah).4, revlimiter_engage_resume_check_cmp_acc
                L       A, off(0016ah)
revlimiter_engage_resume_check_cmp_acc:     CMP     A, 0aeh
                JGT     revlimiter_fuelcut_set
                JBS     off(00110h).3, revlimiter_engage_resume_check_load_imm
                JBR     off(00111h).7, revlimiter_engage_resume_check_load_ram11e
revlimiter_engage_resume_check_load_imm:     L       A, #00238h
                JBS     off(0011ah).4, revlimiter_engage_resume_check_cmp_acc_2
                L       A, #00217h
revlimiter_engage_resume_check_cmp_acc_2:     CMP     A, 0aeh
                JGT     revlimiter_fuelcut_set
revlimiter_engage_resume_check_load_ram11e:     LB      A, off(0011eh)
                ANDB    A, #078h
                JNE     fuelcuttrack_store
                JBR     off(0011fh).0, fuelcut_extra_gate
                LB      A, #0ffh
                CMPB    A, off(00179h)
                JGE     revlimiter_engage_resume_check_load_imm_2
                CMPB    0dfh, #0ffh
                JGE     revlimiter_engage_resume_check_load_ram1e3
                LB      A, off(001e4h)
                JNE     revlimiter_fuelcut_set
revlimiter_engage_resume_check_load_imm_2:     LB      A, #0ffh
                STB     A, off(001e3h)
                SJ      fuelcut_extra_gate
revlimiter_engage_resume_check_load_ram1e3:     LB      A, off(001e3h)
                JNE     fuelcut_extra_gate
                LB      A, #0ffh
                STB     A, off(001e4h)
revlimiter_fuelcut_set:     SB      PSWL.5
                RB      PSWL.4
                SJ      revlimiter_fuelcut_set_if_ram12d_bit7_set
fuelcut_extra_gate:     JBS     off(0011ah).0, ofc_enable_check
                JBR     off(00116h).2, ofc_enable_check_if_ram130_bit0_set
ofc_enable_check:     JBR     off(00117h).2, ofc_enable_check_if_ram130_bit3_set
                RB      off(00130h).1
ofc_enable_check_if_ram130_bit0_set:     JBS     off(00130h).0, fuelcuttrack_store
                JBS     off(00130h).2, ofc_enable_check_clear_pswl_bit5
fuelcuttrack_store:     LB      A, #01eh
                STB     A, off(001f3h)
fuelcuttrack_store_clear_pswl_bit4:     RB      PSWL.4
                RB      PSWL.5
                RC
                SJ      fuelcuttrack_store_if_ram111_bit6_clr
ofc_enable_check_if_ram130_bit3_set:     JBS     off(00130h).3, ofc_enable_check_clear_pswl_bit5
                SB      off(00130h).1
                SJ      fuelcuttrack_store
ofc_enable_check_clear_pswl_bit5:     RB      PSWL.5
                SB      PSWL.4
                JBS     off(0011ah).0, revlimiter_fuelcut_set_if_ram12d_bit7_set
                LB      A, #004h
                JBS     off(00120h).0, ofc_enable_check_cmp_acc
                LB      A, #003h
ofc_enable_check_cmp_acc:     CMPB    A, 0e6h
                JLE     fuelcuttrack_store
                J       ofc_enable_check_load_ram1f3
                DB  000h
revlimiter_fuelcut_set_if_ram12d_bit7_set:     JBS     off(0012dh).7, revlimiter_fuelcut_set_nop_acc
                JBS     off(0012eh).0, revlimiter_fuelcut_set_nop_acc
                JBS     off(0012dh).5, revlimiter_fuelcut_set_set_carry
revlimiter_fuelcut_set_nop_acc:     NOP
                NOP
                NOP
                SJ      fuelcuttrack_store_clear_pswl_bit4
revlimiter_fuelcut_set_set_carry:     SC
fuelcuttrack_store_if_ram111_bit6_clr:     JBR     off(00111h).6, fuelcuttrack_store_store_carry_ram11a_bit0
                SC
fuelcuttrack_store_store_carry_ram11a_bit0:     MB      off(0011ah).0, C
                MB      C, PSWL.5
                MB      off(0011ah).4, C
                MB      C, PSWL.4
                MB      off(0011ah).2, C
                RB      PSWL.5
                MOVB    r2, #03ch
                LB      A, off(0011eh)
                ANDB    A, #078h
                JNE     fuelcuttrack_store_goto_2fe5
                JBR     off(0011dh).0, fuelcuttrack_store_if_ram12d_bit5_clr
                LB      A, off(00178h)
                CAL     fuelcuttrack_store_sub_load_x1
                VCAL    0
                SJ      to_set_pswl4_flag_b_set_ram11c_bit0
fuelcuttrack_store_if_ram12d_bit5_clr:     JBR     off(0012dh).5, fuelcuttrack_store_goto_2fe5
                JBR     off(0011ch).3, fuelcuttrack_store_if_ram116_bit5_clr
fuelcuttrack_store_goto_2fe5:     J       ignmap2_result_check_clear_acc
fuelcuttrack_store_if_ram116_bit5_clr:     JBR     off(00116h).5, postig_result_default
                JBR     off(00116h).2, postig_result_default
                JBR     off(00117h).4, fuelcuttrack_store_load_imm
                RB      off(00128h).3
                SJ      postig_result_default
fuelcuttrack_store_load_imm:     L       A, #rom_52b3
                MOV     X1, #rom_52c1
                JBS     off(00120h).0, fuelcuttrack_store_if_ram11c_bit0_set
                L       A, #rom_5297
                MOV     X1, #rom_52a5
fuelcuttrack_store_if_ram11c_bit0_set:     JBS     off(0011ch).0, fuelcuttrack_store_load_ram0d9
                MOV     X1, A
fuelcuttrack_store_load_ram0d9:     LB      A, 0d9h
                VCAL    0
                JBR     off(00115h).2, idle_mode_gate3
                LB      A, #060h
                JBR     off(0011ch).0, fuelcuttrack_store_cmp_acc
                LB      A, #04ah
fuelcuttrack_store_cmp_acc:     CMPB    A, r6
                JGE     idle_mode_gate3
                LB      A, r6
idle_mode_gate3:     JBR     off(00120h).0, idle_mode_gate3_cmp_acc
                JBS     off(0011ch).0, idle_mode_gate3_cmp_acc
                JBR     off(00128h).3, idle_mode_gate3_cmp_acc
                CMPB    0d9h, #02eh
                JLT     idle_mode_gate3_cmp_acc
                CMPB    0dfh, #00ah
                JLT     idle_mode_gate3_cmp_acc
                ADDB    A, #01ah
                JGE     idle_mode_gate3_cmp_acc
                LB      A, #0ffh
idle_mode_gate3_cmp_acc:     CMPB    A, off(00179h)
                JLT     idle_mode_gate3_cmp_ram0d9
                SB      off(00128h).3
                SJ      ignmap2_result_check_clear_acc
idle_mode_gate3_cmp_ram0d9:     CMPB    0d9h, #034h
                JGE     postig_result_high
                JBR     off(00120h).0, postig_result_high
                LB      A, off(001f5h)
                STB     A, r2
                JNE     ignmap2_result_check_clear_acc
postig_result_high:     LB      A, #0d9h
                JBS     off(00120h).0, to_set_pswl4_flag_b
                LB      A, #0e6h
to_set_pswl4_flag_b:     SB      PSWL.5
to_set_pswl4_flag_b_set_ram11c_bit0:     SB      off(0011ch).0
                SJ      to_set_pswl4_flag_b_store_ram18a
postig_result_default:     LB      A, #080h
                MOV     X1, #rom_53db
                JBS     off(0011dh).1, ignmap2_table_select
                MOV     X1, #rom_53cf
ignmap2_table_select:     JBR     off(0011ch).0, ignmap2_rpm_gate
                LB      A, #074h
                MOV     X1, #rom_53f3
                JBS     off(0011dh).1, ignmap2_rpm_gate
                MOV     X1, #rom_53e7
ignmap2_rpm_gate:     CMPB    A, off(00179h)
                JGE     ignmap2_result_check_clear_acc
                LB      A, off(00179h)
                VCAL    0
                ADDB    A, #001h
                JGE     ignmap2_result_check
                LB      A, #0ffh
ignmap2_result_check:     SUBB    A, off(00197h)
                JLT     ignmap2_result_check_clear_acc
                CMPB    A, off(00178h)
                JLE     ignmap2_result_check_clear_acc
                LB      A, #0e6h
                SJ      to_set_pswl4_flag_b_set_ram11c_bit0
ignmap2_result_check_clear_acc:     CLRB    A
                RB      off(0011ch).0
to_set_pswl4_flag_b_store_ram18a:     STB     A, off(0018ah)
                MB      C, PSWL.5
                MB      off(0011ch).1, C
                MOVB    off(001f5h), r2
                LB      A, #0efh
                JBS     off(0012fh).0, to_set_pswl4_flag_b_cmp_acc
                LB      A, #0f5h
to_set_pswl4_flag_b_cmp_acc:     CMPB    A, off(00179h)
                MB      off(0012fh).0, C
                JLT     to_set_pswl4_flag_b_store_carry_ram11b_bit6
                LB      A, #00fh
                JBS     off(0011bh).6, to_set_pswl4_flag_b_cmp_ram0af
                LB      A, #00fh
to_set_pswl4_flag_b_cmp_ram0af:     CMPB    0afh, A
to_set_pswl4_flag_b_store_carry_ram11b_bit6:     MB      off(0011bh).6, C
                RC
                JBS     off(0012fh).0, to_set_pswl4_flag_b_store_carry_ram11b_bit2
                JBS     off(0011ch).3, to_set_pswl4_flag_b_store_carry_ram11b_bit2
                JBS     off(0011ch).0, to_set_pswl4_flag_b_store_carry_ram11b_bit2
                JBS     off(0011ah).0, to_set_pswl4_flag_b_store_carry_ram11b_bit2
                MB      C, off(0011bh).6
to_set_pswl4_flag_b_store_carry_ram11b_bit2:     MB      off(0011bh).2, C
                LB      A, #0bah
                JBS     off(0011bh).7, to_set_pswl4_flag_b_cmp_acc_2
                LB      A, #0c0h
to_set_pswl4_flag_b_cmp_acc_2:     CMPB    A, off(00179h)
                MB      off(0011bh).7, C
                JBR     off(00117h).0, to_set_pswl4_flag_b_load_carry_ram12f_bit3
                MOVB    off(001e1h), #019h
to_set_pswl4_flag_b_load_carry_ram12f_bit3:     MB      C, off(0012fh).3
                MB      PSWL.4, C
                LB      A, #01fh
                CMPB    0e0h, #0dbh
                JLT     to_set_pswl4_flag_b_cmp_acc_3
                LB      A, #01dh
to_set_pswl4_flag_b_cmp_acc_3:     CMPB    A, 0dah
                MB      off(0012fh).3, C
                MB      C, PSWL.4
                JBR     off(0012fh).3, to_set_pswl4_flag_b_store_carry_ram12f_bit2
                RB      PSWL.4
                MB      C, PSWH.6
to_set_pswl4_flag_b_store_carry_ram12f_bit2:     MB      off(0012fh).2, C
                L       A, off(00172h)
                JEQ     to_set_pswl4_flag_b_load_r0
                DEC     off(00172h)
to_set_pswl4_flag_b_load_r0:     MOVB    r0, #064h
                JBS     off(0011dh).0, to_set_pswl4_flag_b_clear_ram196_2
                JBR     off(0011fh).0, to_set_pswl4_flag_b_if_ram118_bit6_set
                MB      C, 0a0h.0
                JGE     to_set_pswl4_flag_b_if_ram118_bit6_set
                JBR     off(0012fh).2, to_set_pswl4_flag_b_clear_ram196_2
                RB      0a0h.0
to_set_pswl4_flag_b_if_ram118_bit6_set:     JBS     off(00118h).6, to_set_pswl4_flag_b_load_imm
                JBR     off(00118h).2, to_set_pswl4_flag_b_clear_ram196_2
                JBS     off(0011ch).3, to_set_pswl4_flag_b_clear_ram196_2
                JBR     off(00118h).0, to_set_pswl4_flag_b_clear_ram196
                JBS     off(0012fh).0, to_set_pswl4_flag_b_clear_ram196_2
                JBR     off(0011bh).6, to_set_pswl4_flag_b_load_ram196
                JBS     off(0011ah).0, to_set_pswl4_flag_b_load_ram196
                JBS     off(0011ch).0, to_set_pswl4_flag_b_load_ram196
                SB      off(0011bh).1
                MOVB    off(001efh), r0
                CAL     to_set_pswl4_flag_b_sub_clear_acc
                L       A, er1
                SJ      o2_trim_dp_table_read_store_ram160
to_set_pswl4_flag_b_load_imm:     L       A, #08290h
                SJ      o2_trim_dp_table_read_clear_ram11b_bit1
to_set_pswl4_flag_b_clear_ram196:     CLRB    off(00196h)
                MOVB    off(001efh), r0
                MOV     DP, #00308h
                JBR     off(00117h).0, o2_trim_dp_table_read
                MOV     DP, #00304h
o2_trim_dp_table_read:     L       A, [DP]
                SJ      o2_trim_dp_table_read_clear_ram11b_bit1
to_set_pswl4_flag_b_clear_ram196_2:     CLRB    off(00196h)
                MOVB    off(001efh), r0
                SJ      to_set_pswl4_flag_b_load_imm_2
to_set_pswl4_flag_b_load_ram196:     MOVB    off(00196h), #00ah
                LB      A, off(001efh)
                JEQ     to_set_pswl4_flag_b_load_imm_2
                L       A, off(00160h)
                SB      off(0011bh).1
                SJ      o2_trim_dp_table_read_clear_ram11b_bit0
to_set_pswl4_flag_b_load_imm_2:     L       A, #08000h
o2_trim_dp_table_read_clear_ram11b_bit1:     RB      off(0011bh).1
o2_trim_dp_table_read_clear_ram11b_bit0:     RB      off(0011bh).0
o2_trim_dp_table_read_store_ram160:     ST      A, off(00160h)
                LB      A, off(0017eh)
                JBS     off(0011dh).0, o2_trim_dp_table_read_store_ram180
                LB      A, #040h
                JBS     off(0011ch).2, o2_trim_dp_table_read_store_ram180
                JBS     off(0011ch).0, o2_trim_dp_table_read_store_ram180
                MOV     X1, #rom_51b9
                MOV     X2, #0017ah
                JBR     off(0011bh).0, o2_trim_dp_table_read_if_ram120_bit0_set
                ADD     X1, #00004h
                INC     X2
                INC     X2
o2_trim_dp_table_read_if_ram120_bit0_set:     JBS     off(00120h).0, o2_trim_dp_table_read_load_tbl_x2
                INC     X1
o2_trim_dp_table_read_load_tbl_x2:     LB      A, 00000h[X2]
                STB     A, r6
                LB      A, 00001h[X2]
                STB     A, r7
                LB      A, off(00178h)
                CAL     knockretard_table_gate_sub_load_acc
o2_trim_dp_table_read_store_ram180:     STB     A, off(00180h)
                LB      A, off(00178h)
                MOV     X1, #rom_52ef
                VCAL    0
                MOVB    ACCH, #002h
                MOVB    r0, off(00189h)
                CLRB    r1
                MUL
                SRL     er1
                RORB    ACCH
                LB      A, r2
                L       A, ACC
                SWAP
                ADD     A, #00200h
                ST      A, off(00154h)
                LB      A, off(00183h)
                JBS     off(0011ch).2, o2_trim_dp_table_read_load_r0
                LB      A, off(00180h)
o2_trim_dp_table_read_load_r0:     MOVB    r0, off(0018fh)
                MULB
                MOV     er0, A
                LB      A, off(0018ah)
                JEQ     o2_trim_dp_table_read_load_ram182
                STB     A, ACCH
                CLRB    A
                MUL
                MOV     er0, er1
o2_trim_dp_table_read_load_ram182:     LB      A, off(00182h)
                JEQ     o2_trim_dp_table_read_load_ram162
                STB     A, ACCH
                CLRB    A
                MUL
                MOV     er0, er1
o2_trim_dp_table_read_load_ram162:     L       A, off(00162h)
                MUL
                MOV     er0, er1
                L       A, off(00154h)
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
injtimer_mul_chain2:     L       A, off(00152h)
                MUL
                MOV     er0, er1
                JBS     off(0011bh).0, injtimer_mul_final
                JBR     off(0011dh).4, injtimer_mul_final
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
injtimer_mul_chain3:     L       A, off(0015eh)
                MUL
                MOV     er0, er1
injtimer_mul_final:     L       A, off(00160h)
                MUL
                MOV     off(00150h), er1
                JBS     off(00110h).2, dwell_zero_result
                JBS     off(00110h).4, dwell_zero_result
                JBS     off(0011dh).0, dwell_zero_result
                LB      A, off(00179h)
                CMPB    A, #0c0h
                JGE     dwell_zero_result
                CMPB    A, #001h
                JLT     dwell_zero_result
                JBS     off(00128h).4, injtimer_mul_final_load_imm
                CMPB    0e2h, #010h
                JLT     dwell_zero_result
                SB      off(00128h).4
injtimer_mul_final_load_imm:     LB      A, #004h
                JBS     off(00119h).3, injtimer_mul_final_cmp_acc
                LB      A, #004h
                CMPB    0ffh, #01eh
                JLT     dwell_zero_result
injtimer_mul_final_cmp_acc:     CMPB    A, 0e6h
                JGE     dwell_zero_result
                MOVB    r0, off(00187h)
                MOVB    r1, #010h
                JBS     off(00119h).3, dwell_clamp_check
                MOVB    r0, off(00188h)
                MOVB    r1, #014h
dwell_clamp_check:     LB      A, 0e6h
                CMPB    A, r1
                JLE     dwell_mul_apply
                LB      A, r1
dwell_mul_apply:     MULB
                L       A, ACC
                SRL     A
                JBS     off(00119h).3, dwell_store_result
                VCAL    7
                SJ      dwell_store_result
dwell_zero_result:     CLR     A
dwell_store_result:     ST      A, off(00144h)
                CLRB    r4
                RC
                JBS     off(0011dh).0, rpm_accel_clamp_store_carry_ram12e_bit2
                JBR     off(00116h).6, rpm_accel_clamp_store_carry_ram12e_bit2
                JBS     off(0012eh).2, dwell_store_result_if_ram116_bit2_clr
                JBS     off(00116h).7, rpm_accel_clamp_load_r4
                SJ      dwell_store_result_load_carry_ram119_bit4
dwell_store_result_if_ram116_bit2_clr:     JBR     off(00116h).2, dwell_store_result_load_carry_ram119_bit4
                JBR     off(0012dh).0, rpm_accel_clamp_store_carry_ram12e_bit2
dwell_store_result_load_carry_ram119_bit4:     MB      C, off(00119h).4
                L       A, #000b3h
                JBS     off(00116h).7, dwell_store_result_if_lt_goto_rpm_accel_secondary_calc
                XORB    PSWH, #080h
                L       A, #000b3h
dwell_store_result_if_lt_goto_rpm_accel_secondary_calc:     JLT     rpm_accel_secondary_calc
                CMP     A, 0b0h
                JLT     rpm_accel_clamp_store_carry_ram12e_bit2
rpm_accel_secondary_calc:     CLRB    r0
                MOVB    r1, #018h
                CMPB    0d9h, #02eh
                JGE     rpm_accel_secondary_calc_load_ram0b4
                JBS     off(00120h).0, rpm_accel_secondary_calc_load_ram0b4
                CMPB    0dfh, #005h
                JLT     rpm_accel_secondary_calc_load_ram0b4
                MOVB    r1, #000h
rpm_accel_secondary_calc_load_ram0b4:     L       A, 0b4h
                MUL
                MOVB    r4, #023h
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
rpm_accel_clamp_store_carry_ram12e_bit2:     MB      off(0012eh).2, C
rpm_accel_clamp_load_r4:     LB      A, r4
                JEQ     rpm_accel_clamp_store_ram18d
                JBR     off(00116h).7, rpm_accel_clamp_store_ram18d
                VCAL    7
rpm_accel_clamp_store_ram18d:     STB     A, off(0018dh)
                CLR     er1
                JBS     off(0011dh).0, rpm_accel_clamp_clear_r0_2
                JBS     off(0011ah).6, rpm_accel_clamp_clear_r0_2
                MOVB    r0, #004h
                JBS     off(0011ah).0, rpm_accel_clamp_clear_ram12d_bit7
                LB      A, off(00198h)
                JEQ     rpm_accel_clamp_clear_r0_2
                LB      A, off(00179h)
                MOV     X1, #rpm_accel_clamp_tbl
                VCAL    1
                CLR     er1
                MOVB    r0, off(00198h)
                DECB    r0
                JBS     off(00119h).5, rpm_accel_clamp_load_ram148
                ; warning: had to flip DD
                CMP     A, 0b2h
                JGE     rpm_accel_clamp_load_ram148
                MOV     er1, #0038ah
                JBS     off(0012dh).7, rpm_accel_clamp_clear_r0_2
                L       A, #00177h
                JBS     off(0012eh).0, rpm_accel_clamp_clear_r0
                L       A, #000b5h
                JBS     off(00120h).0, rpm_accel_clamp_clear_r0
                L       A, #000b5h
rpm_accel_clamp_clear_r0:     CLRB    r0
                MOVB    r1, off(00194h)
                MUL
                SLL     A
                ROL     er1
                JLT     rpm_accel_clamp_load_er1
                SLL     A
                ROL     er1
                JGE     rpm_accel_clamp_clear_r0_2
rpm_accel_clamp_load_er1:     MOV     er1, #0ffffh
rpm_accel_clamp_clear_r0_2:     CLRB    r0
rpm_accel_clamp_clear_ram12d_bit7:     RB      off(0012dh).7
                RB      off(0012eh).0
rpm_accel_clamp_load_ram148:     MOV     off(00148h), er1
                MOVB    off(00198h), r0
                LB      A, off(0019fh)
                JEQ     rpm_accel_clamp_clear_acc_2
                CMPB    0d8h, #000h
                JGE     rpm_accel_clamp_clear_acc
                CMPB    0ffh, #032h
                JLT     rpm_accel_clamp_store_ram19f
                JBS     off(0011ah).2, rpm_accel_clamp_store_ram19f
                SUBB    A, #002h
                JGE     rpm_accel_clamp_store_ram19f
rpm_accel_clamp_clear_acc:     CLRB    A
rpm_accel_clamp_store_ram19f:     STB     A, off(0019fh)
rpm_accel_clamp_clear_acc_2:     CLR     A
                CMPB    0d9h, #02eh
                JLT     injtimer_bank_b_store
                L       A, off(00146h)
                JEQ     injtimer_bank_b_store
                CLRB    r0
                MOVB    r1, off(00185h)
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     injtimer_bank_b_store
                L       A, #0ffffh
injtimer_bank_b_store:     ST      A, off(0014ch)
                L       A, off(00148h)
                CMP     A, off(0014ch)
                JGE     injtimer_bank_c_check
                L       A, off(0014ch)
injtimer_bank_c_check:     L       A, ACC
                JEQ     injtimer_bank_c_check_store_ram14e
                ADD     A, off(00142h)
                JGE     injtimer_bank_c_check_store_ram14e
                L       A, #0ffffh
injtimer_bank_c_check_store_ram14e:     ST      A, off(0014eh)
                JBR     off(0011ah).2, injtimer_bank_c_check_load_ram146
                MOV     DP, #00382h
                CLR     A
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                J       accel_iac_store_if_ram11e_bit1_set
injtimer_bank_c_check_load_ram146:     L       A, off(00146h)
                JEQ     injtimer_bank_c_check_store_er3
                LB      A, off(00181h)
                MOVB    r0, off(00186h)
                MULB
                MOVB    r1, off(0017fh)
                CLRB    r0
                MUL
                MOV     er0, er1
                L       A, off(00152h)
                MUL
                MOV     er0, er1
                L       A, off(00146h)
                MUL
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     injtimer_bank_c_check_store_er3
                L       A, #0ffffh
injtimer_bank_c_check_store_er3:     ST      A, er3
                ST      A, off(00140h)
                L       A, er3
                CLR     er3
                MOVB    r6, off(0019fh)
                ADD     A, er3
                JLT     tipin_time_clamp
                ADD     A, off(00142h)
                JLT     tipin_time_clamp
                ADD     A, off(00148h)
                JGE     tipin_time_finalize
tipin_time_clamp:     L       A, #0ffffh
tipin_time_finalize:     ST      A, er0
                LB      A, off(0018dh)
                EXTND
                MOV     er3, off(00144h)
                CAL     tipin_time_finalize_sub_load_acc
                LB      A, off(0018bh)
                EXTND
                CAL     tipin_time_finalize_sub_load_acc
                CMP     A, #08000h
                JGE     tipin_time_finalize_add_acc
                ADD     A, er0
                JGE     tipin_time_finalize_cmp_acc
tipin_time_finalize_load_imm:     L       A, #07fffh
                SJ      tipin_result_store
tipin_time_finalize_add_acc:     ADD     A, er0
                JGE     tipin_result_store
tipin_time_finalize_cmp_acc:     CMP     A, #08000h
                JGE     tipin_time_finalize_load_imm
tipin_result_store:     ST      A, er3
                MOV     X2, A
                L       A, off(0013eh)
                MOV     er0, off(00150h)
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
                MOV     DP, #00382h
                MOV     er0, [DP]
                ST      A, [DP]
                MOV     X1, #rom_52df
cylinder_ign_correct_loop:     INC     DP
                INC     DP
                L       A, er2
                JBR     off(0011bh).1, cylinder_ign_correct_apply
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
                ST      A, [DP]
                INC     X1
                CMP     DP, #0038ah
                JLT     cylinder_ign_correct_loop
accel_iac_store_if_ram11e_bit1_set:     JBS     off(0011eh).1, o2_trim_gate_common
                JBS     off(00118h).3, o2_trim_gate_common
                L       A, off(00110h)
                AND     A, #08075h
                JNE     o2_trim_gate_common
                L       A, off(00112h)
                AND     A, #01420h
                JNE     o2_trim_gate_common
                CMPB    0feh, #01eh
                JLT     o2_trim_gate_common
                CMPB    0d9h, #028h
                JGE     o2_trim_gate_common
                LB      A, 0dah
                STB     A, r0
                JBS     off(0011ah).2, o2_store_prev_reading
                CMPB    off(00179h), #05ah
                JGE     o2_gate_tps_check
                MOVB    off(001e6h), #032h
o2_gate_tps_check:     LB      A, off(001e6h)
                JNE     o2_gate_dp_set
                SB      off(00131h).3
o2_gate_dp_set:     RC
                JBS     off(0011ah).4, dtc01_o2_latch
                JBR     off(0011ch).3, dtc01_o2_latch
                LB      A, #046h
                CMPB    A, off(00183h)
                JGE     dtc01_o2_latch
                CMPB    r0, #003h
                SJ      dtc01_o2_latch
o2_store_prev_reading:     JBS     off(0011ah).3, o2_store_prev_reading_if_ram131_bit3_clr
                STB     A, off(001abh)
o2_store_prev_reading_if_ram131_bit3_clr:     JBR     off(00131h).3, o2_trim_gate_reset_dp
                CMPB    A, #04dh
                JLE     o2_trim_gate_common
                JBS     off(00117h).2, o2_trim_gate_common
                LB      A, off(001abh)
                SUBB    A, r0
                JGE     o2_delta_magnitude_check
                VCAL    7
o2_delta_magnitude_check:     CMPB    A, #002h
                JLT     dtc01_o2_latch
o2_trim_gate_common:     RB      off(00131h).3
o2_trim_gate_reset_dp:     MOVB    off(001e6h), #032h
                RC
dtc01_o2_latch:     MB      098h.4, C
                LB      A, off(0019dh)
                JEQ     o2_trim_step_start_load_imm
                MB      C, 09fh.1
                JGE     o2_trim_step_start_subb_acc
                LB      A, #004h
o2_trim_step_start_subb_acc:     SUBB    A, #001h
                STB     A, off(0019dh)
o2_trim_step_start_load_imm:     LB      A, #000h
                JBS     off(00114h).7, injector_effective_pw_skip_store_ram19b
                LB      A, #005h
                JBS     off(0011dh).0, injector_effective_pw_skip_store_ram19b
                LB      A, #008h
                JBS     off(00110h).2, o2_trim_step_start_store_r6
                JBS     off(00110h).4, o2_trim_step_start_store_r6
                JBS     off(00110h).5, o2_trim_step_start_store_r6
                JBS     off(00111h).4, o2_trim_step_start_store_r6
                LB      A, #007h
                JBS     off(00116h).1, o2_trim_step_start_store_r6
                CLR     DP
                LB      A, 0d9h
                CMPB    A, #0a5h
                JGE     o2_trim_step_start_load_imm_2
                ADD     DP, #00003h
                CMPB    A, #028h
                JGE     o2_trim_step_start_load_imm_2
                ADD     DP, #00003h
o2_trim_step_start_load_imm_2:     LB      A, #02fh
                JBR     off(00132h).4, o2_trim_step_start_cmp_acc
                LB      A, #028h
o2_trim_step_start_cmp_acc:     CMPB    A, 0e2h
                MB      off(00132h).4, C
                LB      A, #09ch
                JBR     off(00132h).3, o2_trim_step_start_cmp_acc_2
                LB      A, #094h
o2_trim_step_start_cmp_acc_2:     CMPB    A, 0e2h
                MB      off(00132h).3, C
                JLT     o2_trim_step_start_rom_load_051a3h_dp
                INC     DP
                JBS     off(00132h).4, o2_trim_step_start_rom_load_051a3h_dp
                INC     DP
o2_trim_step_start_rom_load_051a3h_dp:     LCB     A, rom_51a3[DP]
o2_trim_step_start_store_r6:     STB     A, r6
                CLR     er0
                MOV     DP, #00382h
                L       A, [DP]
                MOV     er2, off(00136h)
                DIV
                JLT     injector_effective_pw_skip
                CMP     A, #0000bh
                JGT     injector_effective_pw_skip
                LB      A, ACC
                XCHGB   A, r6
                SUBB    A, r6
                JGE     injector_effective_pw_skip_store_ram19b
injector_effective_pw_skip:     CLRB    A
injector_effective_pw_skip_store_ram19b:     STB     A, off(0019bh)
                JBR     off(0011eh).2, injector_effective_pw_skip_load_imm
                LB      A, off(00179h)
                MOV     X1, #injector_effective_pw_skip_tbl_6
                VCAL    0
                J       injector_effective_pw_skip_clear_carry
injector_effective_pw_skip_load_imm:     LB      A, #038h
                JBS     off(0012fh).4, injector_effective_pw_skip_cmp_acc
                LB      A, #040h
injector_effective_pw_skip_cmp_acc:     CMPB    A, off(00178h)
                MB      off(0012fh).4, C
                LB      A, #013h
                JBS     off(0012fh).5, injector_effective_pw_skip_cmp_acc_2
                LB      A, #02ah
injector_effective_pw_skip_cmp_acc_2:     CMPB    A, 0e2h
                MB      off(0012fh).5, C
                LB      A, #0c5h
                JBS     off(0012fh).6, injector_effective_pw_skip_cmp_acc_3
                LB      A, #0c8h
injector_effective_pw_skip_cmp_acc_3:     CMPB    A, off(00179h)
                MB      off(0012fh).6, C
                JLT     injector_effective_pw_skip_goto_3575
                JBS     off(0011dh).2, injector_effective_pw_skip_goto_3575
                JBR     off(00116h).1, injector_effective_pw_skip_if_ram119_bit6_set
injector_effective_pw_skip_goto_3575:     J       injector_effective_pw_skip_clear_acc_2
injector_effective_pw_skip_if_ram119_bit6_set:     JBS     off(00119h).6, injector_effective_pw_skip_goto_3575
                L       A, off(00110h)
                AND     A, #0907ch
                JNE     injector_effective_pw_skip_goto_3575
                JBS     off(0011ah).0, injector_effective_pw_skip_goto_3575
                JBS     off(0011ch).3, injector_effective_pw_skip_goto_3575
                JBR     off(00117h).2, injector_effective_pw_skip_goto_3575
                JBS     off(00113h).2, injector_effective_pw_skip_if_ram11b_bit2_clr
                JBS     off(00113h).4, injector_effective_pw_skip_if_ram11b_bit2_clr
                JBR     off(00110h).0, injector_effective_pw_skip_if_ram11b_bit0_clr
injector_effective_pw_skip_if_ram11b_bit2_clr:     JBR     off(0011bh).2, injector_effective_pw_skip_clear_acc_2
                SJ      injector_effective_pw_skip_load_imm_2
injector_effective_pw_skip_if_ram11b_bit0_clr:     JBR     off(0011bh).0, injector_effective_pw_skip_clear_acc_2
injector_effective_pw_skip_load_imm_2:     LB      A, #035h
                JBR     off(0011fh).3, injector_effective_pw_skip_cmp_acc_4
                LB      A, #070h
injector_effective_pw_skip_cmp_acc_4:     CMPB    A, 0d9h
                JLE     injector_effective_pw_skip_clear_acc_2
                JBR     off(0012fh).4, injector_effective_pw_skip_clear_acc_2
                JBR     off(0012fh).5, injector_effective_pw_skip_clear_acc_2
                CLRB    r6
                JBS     off(0011dh).1, injector_effective_pw_skip_load_ram0ef
                LB      A, 0eeh
                CMPB    A, #00eh
                JGE     injector_effective_pw_skip_clear_acc
                SUBB    A, #004h
                JLT     injector_effective_pw_skip_clear_acc
                MOV     DP, #injector_effective_pw_skip_tbl_2
                JBS     off(00120h).0, injector_effective_pw_skip_load_x1
                MOV     DP, #injector_effective_pw_skip_tbl_3
injector_effective_pw_skip_load_x1:     MOV     X1, 0cah
                SJ      injector_effective_pw_skip_load_r1
injector_effective_pw_skip_load_ram0ef:     LB      A, 0efh
                CMPB    A, #00eh
                JGE     injector_effective_pw_skip_clear_acc
                SUBB    A, #004h
                JLT     injector_effective_pw_skip_clear_acc
                MOV     DP, #tbl_zero_681c
                JBS     off(00120h).0, injector_effective_pw_skip_load_x1_2
                MOV     DP, #tbl_zero_688a
injector_effective_pw_skip_load_x1_2:     MOV     X1, 0cch
injector_effective_pw_skip_load_r1:     MOVB    r1, 0edh
                MOV     X2, 0c6h
                CAL     tipin_gate_common_sub_load_r0
injector_effective_pw_skip_clear_acc:     CLR     A
                LB      A, (00290h-00280h)[USP]
                MB      C, ACC.7
                JLT     injector_effective_pw_skip_addb_acc
                ADDB    A, r6
                JGE     injector_effective_pw_skip_store_ram190
                LB      A, #0ffh
                SJ      injector_effective_pw_skip_store_ram190
injector_effective_pw_skip_addb_acc:     ADDB    A, r6
                JLT     injector_effective_pw_skip_store_ram190
                CLRB    A
injector_effective_pw_skip_store_ram190:     STB     A, off(00190h)
                MOVB    r0, off(00195h)
                MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     injector_effective_pw_skip_set_carry
                LB      A, #0ffh
injector_effective_pw_skip_set_carry:     SC
                SJ      injector_effective_pw_skip_store_carry_ram11b_bit4
injector_effective_pw_skip_clear_acc_2:     CLRB    A
injector_effective_pw_skip_clear_carry:     RC
injector_effective_pw_skip_store_carry_ram11b_bit4:     MB      off(0011bh).4, C
                STB     A, (00294h-00280h)[USP]
                RC
                JEQ     injector_effective_pw_skip_store_carry_ram01f_bit4
                SC
injector_effective_pw_skip_store_carry_ram01f_bit4:     MB      P4SF.4, C
                MB      C, off(00116h).2
                MB      off(0012dh).0, C
                MB      C, off(00115h).3
                MB      off(0012dh).1, C
;@ VTECSpeedOff type=u8 formula=raw unit=km/h category="VTEC" desc="Stock VTEC: once in, it holds above this road speed. (an immediate in the code.)" at=vtec_speed_off+1
vtec_speed_off:
                LB      A, #019h
                JBS     off(0012eh).4, injector_effective_pw_skip_cmp_acc_5
;@ VTECSpeedOn type=u8 formula=raw unit=km/h category="VTEC" desc="Stock VTEC: it engages only above this road speed. (an immediate in the code.)" at=vtec_speed_on+1
vtec_speed_on:
                LB      A, #01eh
injector_effective_pw_skip_cmp_acc_5:     CMPB    A, 0dfh
                MB      off(0012eh).4, C
;@ VTECStockLoadOff type=u8 formula=p13_rpm8 slot=vtec.stock.load.off category="VTEC" desc="Stock VTEC: once in on load, it drops out below this rpm. (an immediate in the code.)" at=vtec_load_off+1
vtec_load_off:
                LB      A, #0cch
                JBS     off(0012eh).5, injector_effective_pw_skip_cmp_acc_6
;@ VTECStockLoadOn type=u8 formula=p13_rpm8 slot=vtec.stock.load.on category="VTEC" desc="Stock VTEC: above this rpm it engages when the load is over the stock load curve (VTECLoad). (an immediate in the code.)" at=vtec_load_on+1
vtec_load_on:
                LB      A, #0cfh
injector_effective_pw_skip_cmp_acc_6:     CMPB    A, off(00179h)
                MB      off(0012eh).5, C
;@ VTECStockAnyOff type=u8 formula=p13_rpm8 slot=vtec.stock.any.off category="VTEC" desc="Stock VTEC: once in whatever the load, it holds above this rpm. (an immediate in the code.)" at=vtec_any_off+1
vtec_any_off:
                LB      A, #0e3h
                JBS     off(0012eh).6, injector_effective_pw_skip_cmp_acc_7
;@ VTECStockAnyOn type=u8 formula=p13_rpm8 slot=vtec.stock.any.on category="VTEC" desc="Stock VTEC: above this rpm it engages whatever the load. (an immediate in the code.)" at=vtec_any_on+1
vtec_any_on:
                LB      A, #0e5h
injector_effective_pw_skip_cmp_acc_7:     CMPB    A, off(00179h)
                MB      off(0012eh).6, C
                LB      A, off(00179h)
                MOV     X1, #injector_effective_pw_skip_tbl
                VCAL    0
                J       injector_effective_pw_skip_if_ram11a_bit1_clr
injector_effective_pw_skip_subb_acc:     SUBB    A, #010h
                JGE     injector_effective_pw_skip_cmp_acc_8
                CLRB    A
injector_effective_pw_skip_cmp_acc_8:     CMPB    A, off(00178h)
                STB     A, off(001bbh)
                MB      off(0012fh).1, C
                LB      A, #044h
                CMPB    A, 0d9h
                JLT     injector_effective_pw_skip_store_carry_ram127_bit0
                JBS     off(0011ch).3, injector_effective_pw_skip_clear_r0
injector_effective_pw_skip_store_carry_ram127_bit0:     MB      off(00127h).0, C
injector_effective_pw_skip_clear_r0:     CLRB    r0
                J       injector_effective_pw_skip_if_ram121_bit0_set
injector_effective_pw_skip_load_ram110:     L       A, off(00110h)
                AND     A, #0c0bch
                JNE     injector_effective_pw_skip_andb_r0
                LB      A, off(00112h)
                ANDB    A, #031h
                JNE     injector_effective_pw_skip_andb_r0
                MOVB    r0, #0c0h
                CMPB    0ffh, #032h
                JLT     injector_effective_pw_skip_andb_r0
                JBS     off(00127h).0, injector_effective_pw_skip_andb_r0
                JBR     off(0012eh).4, injector_effective_pw_skip_andb_r0
                JBR     off(00120h).0, injector_effective_pw_skip_if_ram12e_bit5_set
                JBS     off(00124h).5, injector_effective_pw_skip_if_ram11d_bit1_set
injector_effective_pw_skip_if_ram12e_bit5_set:     JBS     off(0012eh).5, injector_effective_pw_skip_if_ram12f_bit1_set
injector_effective_pw_skip_if_ram11d_bit1_set:     JBS     off(0011dh).1, injector_effective_pw_skip_clear_ram1e2
injector_effective_pw_skip_andb_r0:     ANDB    r0, #07fh
                RB      off(0011ah).1
                SJ      injector_effective_pw_skip_load_ram1f1
injector_effective_pw_skip_if_ram12f_bit1_set:     JBS     off(0012fh).1, injector_effective_pw_skip_load_ram1e2
                JBS     off(0012eh).6, injector_effective_pw_skip_load_ram1e2
                LB      A, off(001e2h)
                JNE     injector_effective_pw_skip_set_ram11a_bit1
injector_effective_pw_skip_clear_ram1e2:     CLRB    off(001e2h)
                ANDB    r0, #07fh
                RB      off(0011ah).1
                JBS     off(00125h).4, injector_effective_pw_skip_load_ram1f1_2
injector_effective_pw_skip_load_ram1f2:     LB      A, off(001f2h)
                JNE     injector_effective_pw_skip_set_ram11d_bit1
injector_effective_pw_skip_load_ram1f1:     MOVB    off(001f1h), #00ah
injector_effective_pw_skip_clear_ram11d_bit1:     RB      off(0011dh).1
                SJ      injector_effective_pw_skip_load_dp
injector_effective_pw_skip_load_ram1e2:     MOVB    off(001e2h), #00ah
injector_effective_pw_skip_set_ram11a_bit1:     SB      off(0011ah).1
                JBR     off(00125h).4, injector_effective_pw_skip_load_ram1f2
injector_effective_pw_skip_load_ram1f1_2:     LB      A, off(001f1h)
                JNE     injector_effective_pw_skip_clear_ram11d_bit1
                MOVB    off(001f2h), #00ah
injector_effective_pw_skip_set_ram11d_bit1:     SB      off(0011dh).1
injector_effective_pw_skip_load_dp:     MOV     DP, #0c000h
                RB      PSWH.0
                LB      A, (00226h-00280h)[USP]
                ANDB    A, #03fh
                ORB     A, r0
                STB     A, (00226h-00280h)[USP]
                XORB    A, #024h
                STB     A, [DP]
                SB      PSWH.0
                LB      A, #0c8h
                JBS     off(0011ah).6, injector_effective_pw_skip_cmp_acc_9
                LB      A, #0cah
injector_effective_pw_skip_cmp_acc_9:     CMPB    A, off(00179h)
                MB      off(0011ah).6, C
                LB      A, #0f4h
                JBS     off(00128h).1, injector_effective_pw_skip_cmp_acc_10
                LB      A, #0f6h
injector_effective_pw_skip_cmp_acc_10:     CMPB    A, off(00179h)
                MB      off(00128h).1, C
                LB      A, #0c0h
                JBS     off(00128h).0, injector_effective_pw_skip_cmp_acc_11
                LB      A, #0c2h
injector_effective_pw_skip_cmp_acc_11:     CMPB    A, off(00179h)
                MB      off(00128h).0, C
                SB      0a0h.2
                MOV     DP, #00048h
                MOV     X1, #0031eh
                CAL     learn_table2_check_sub_load_dp_ind
                MOV     IE, #00001h
                RB      off(00132h).2
                L       A, off(0011ch)
                ST      A, (0021ch-00280h)[USP]
                J       crank_cycle_er2_store_load_ram11a
vcal_4:         NOP
                NOP
                NOP
                RB      09eh.3
                JEQ     vcal_4_clear_ram0a0_bit2
                SJ      vcal_4_load_dp
vcal_4_clear_ram0a0_bit2:     RB      0a0h.2
                JEQ     vcal_4_call_4b80
                JBR     off(00234h).0, vcal_4_goto_3b2d
                RB      off(00235h).2
                JEQ     vcal_4_return
vcal_4_goto_3b2d:     J       vcal_4_load_ram22c
vcal_4_call_4b80:     CAL     vcal_4_sub_pushs_lrb
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                RB      off(00235h).3
                JEQ     vcal_4_clear_ram235_bit4
                J       vcal_4_load_r0
vcal_4_clear_ram235_bit4:     RB      off(00235h).4
                JEQ     vcal_4_return
                J       vcal_4_load_r0_2
vcal_4_return:     RT
vcal_4_load_dp:     MOV     DP, #00046h
                MOV     X1, #00318h
                CAL     learn_table2_check_sub_load_dp_ind
                MOV     OS1, #0ffffh
                CAL     learn_table2_check_sub_load_imm
                MOVB    r0, #00ch
                MOV     DP, #001efh
                CAL     learn_table2_check_sub_clear_pswh_bit0
                MOVB    r0, #00dh
                MOV     DP, #002f3h
                CAL     learn_table2_check_sub_clear_pswh_bit0
                MOVB    r0, #002h
                MOV     DP, #003b7h
                CAL     learn_table2_check_sub_clear_pswh_bit0
                MOV     DP, #000ach
                JBS     off(00212h).0, vcal_4_load_imm
                RB      0a0h.1
                JEQ     vcal_4_load_imm_2
                JBR     off(00216h).1, vcal_4_cmp_ram0db
                J       vcal_4_clear_ram235_bit6
vcal_4_cmp_ram0db:     CMPB    0dbh, #044h
                JLE     vcal_4_load_imm
                RB      PSWH.0
                MOVB    r0, 0bah
                L       A, 0b8h
                SUB     A, 0b6h
                SB      PSWH.0
                SBCB    r0, #000h
                SRLB    r0
                ROR     A
                CMPB    r0, #000h
                JNE     vcal_4_clear_ram235_bit6
                RB      off(00235h).5
                JNE     vss_clamp_common_clear_ram2bb
                RB      off(00235h).6
                JNE     vss_clamp_common_clear_ram2bb
                CMP     A, #002c2h
                MB      off(00235h).6, C
                JLT     vss_clamp_common_clear_ram2bb
                CMP     A, #02dfeh
                JGE     vss_result_store
                MOV     er0, #01000h
                CMP     A, #00499h
                JLT     vss_scale_apply
                MOV     er0, #04000h
vss_scale_apply:     CAL     vss_scale_apply_sub_mul_acc
vss_result_store:     ST      A, [DP]
                ST      A, er2
vssSpeedNumerator    equ 0b1e1h ; VSS: speed = (2 * 10000h + vssSpeedNumerator) / pulse period (MOV er0,#2 / L A,# / DIV).
                                ; A number, not a table: it used to be bound to whatever label sat at this address.
                MOV     er0, #00002h
                L       A, #vssSpeedNumerator
                DIV
                ST      A, er1
                L       A, er0
                JNE     vss_clamp_max
                LB      A, r3
                JEQ     vss_clamp_common
vss_clamp_max:     MOVB    r2, #0ffh
vss_clamp_common:     LB      A, r2
vss_clamp_common_clear_pswh_bit0:     RB      PSWH.0
                XCHGB   A, 0dfh
                STB     A, 0ebh
                SB      PSWH.0
                LB      A, #004h
                JBS     off(00216h).5, vss_clamp_common_cmp_acc
                LB      A, #005h
vss_clamp_common_cmp_acc:     CMPB    A, 0dfh
                MB      off(00216h).5, C
                SJ      vss_clamp_common_clear_ram2bb
vcal_4_load_imm:     L       A, #vcal_4_tbl
                RB      off(00235h).5
                SJ      vss_result_store
vcal_4_load_imm_2:     LB      A, #003h
                CMPB    0f6h, A
                JLT     vss_clamp_common_clear_ram2bb
                STB     A, 0f6h
vcal_4_clear_ram235_bit6:     RB      off(00235h).6
                L       A, #0ffffh
                ST      A, [DP]
                SB      off(00235h).5
                CLRB    A
                SJ      vss_clamp_common_clear_pswh_bit0
vss_clamp_common_clear_ram2bb:     CLRB    off(002bbh)
                CAL     vss_clamp_common_sub_load_dp_2
                CAL     vss_clamp_common_sub_load_dp_ind
                CAL     vss_clamp_common_sub_clear_pswh_bit0
                CAL     vss_clamp_common_sub_load_dp
                CAL     vss_clamp_common_sub_load_dp_2
                CAL     vss_clamp_common_sub_load_dp_ind
                LB      A, off(002bbh)
                JEQ     vss_clamp_common_load_carry_ram229_bit0
                CMPB    A, #0ffh
                JEQ     vss_clamp_common_load_carry_ram229_bit0
                CMPB    A, #0aah
                JEQ     vss_clamp_common_load_carry_ram229_bit0
                CMPB    A, #055h
                JEQ     vss_clamp_common_load_carry_ram229_bit0
                SJ      vss_clamp_common_if_ram220_bit0_clr
vss_clamp_common_load_carry_ram229_bit0:     MB      C, off(00229h).0
                MB      off(00229h).1, C
                MB      C, off(00229h).2
                MB      off(00229h).3, C
                RORB    A
                MB      off(00229h).0, C
                RORB    A
                MB      off(00229h).2, C
vss_clamp_common_if_ram220_bit0_clr:     JBR     off(00220h).0, vss_clamp_common_clear_ram2ba
                JBS     off(00229h).4, vss_clamp_common_if_ram229_bit2_clr
                J       vss_clamp_common_load_ram210
vss_clamp_common_clear_ram229_bit4:     RB      off(00229h).4
                JBS     off(00213h).5, vss_clamp_common_clear_ram226_bit2
                JBS     off(00213h).6, vss_clamp_common_clear_ram226_bit2
                LB      A, off(002e5h)
                JNE     vss_clamp_common_load_ram2fa
                LB      A, off(002fah)
                JEQ     vss_clamp_common_load_ram2e5
                SB      off(00226h).2
                SJ      vss_clamp_common_load_ram2fb
vss_clamp_common_load_ram2e5:     MOVB    off(002e5h), #023h
                SJ      vss_clamp_common_clear_ram226_bit2
vss_clamp_common_load_ram2fa:     MOVB    off(002fah), #006h
vss_clamp_common_clear_ram226_bit2:     RB      off(00226h).2
vss_clamp_common_load_ram2fb:     MOVB    off(002fbh), #0a0h
vss_clamp_common_clear_ram2ba:     CLRB    off(002bah)
                J       vss_clamp_common_if_ram220_bit0_clr_2
vss_clamp_common_cmp_ram0d9:     CMPB    0d9h, #02eh
                JGE     vss_clamp_common_load_ram2fb_2
                LB      A, #053h
                JBS     off(00229h).5, vss_clamp_common_cmp_acc_2
                LB      A, #060h
vss_clamp_common_cmp_acc_2:     CMPB    A, off(00289h)
                MB      off(00229h).5, C
                JGE     vss_clamp_common_load_ram2fb_2
vss_clamp_common_if_ram229_bit2_clr:     JBR     off(00229h).2, vss_clamp_common_if_ram229_bit0_clr
                JBR     off(00229h).0, vss_clamp_common_if_ram229_bit4_clr
                SJ      vss_clamp_common_if_ram229_bit4_clr_2
vss_clamp_common_if_ram229_bit0_clr:     JBR     off(00229h).0, vss_clamp_common_load_ram2ba_2
                JBR     off(00229h).4, vss_clamp_common_load_ram2fb_2
                LB      A, 0dfh
                MOV     X1, #rom_50fa
                VCAL    0
                STB     A, off(002bah)
                LB      A, 0dfh
                MOV     X1, #rom_5102
                VCAL    0
                STB     A, off(002bch)
                SJ      vss_clamp_common_clear_ram226_bit2_2
vss_clamp_common_if_ram229_bit4_clr:     JBR     off(00229h).4, vss_clamp_common_load_ram2fb_2
                MOVB    off(002bah), #050h
                MOVB    off(002bch), #080h
                SJ      vss_clamp_common_clear_ram226_bit2_2
vss_clamp_common_if_ram229_bit4_clr_2:     JBR     off(00229h).4, vss_clamp_common_load_ram2fb_2
                SB      off(00226h).2
vss_clamp_common_load_ram2ba:     LB      A, off(002bah)
                ADDB    A, off(002bch)
                JGE     vss_clamp_common_store_ram2ba
vss_clamp_common_clear_ram229_bit4_2:     RB      off(00229h).4
                SJ      vss_clamp_common_clear_ram2ba_2
vss_clamp_common_store_ram2ba:     STB     A, off(002bah)
                SJ      vss_clamp_common_load_ram2fb_3
vss_clamp_common_load_ram2fb_2:     MOVB    off(002fbh), #0a0h
                SB      off(00226h).2
vss_clamp_common_clear_ram2ba_2:     CLRB    off(002bah)
                SJ      vss_clamp_common_if_ram220_bit0_clr_2
vss_clamp_common_load_ram2ba_2:     LB      A, off(002bah)
                JEQ     vss_clamp_common_load_ram2ba_3
                CMPB    A, #0f4h
                JGE     vss_clamp_common_load_ram2ba_3
                RB      off(00226h).2
                SJ      vss_clamp_common_load_ram2ba
vss_clamp_common_load_ram2ba_3:     MOVB    off(002bah), #0f4h
                MOVB    off(002bch), #004h
                SB      off(00229h).4
vss_clamp_common_clear_ram226_bit2_2:     RB      off(00226h).2
vss_clamp_common_load_ram2fb_3:     LB      A, off(002fbh)
                JEQ     vss_clamp_common_clear_ram229_bit4_2
                JBS     off(0021dh).2, vss_clamp_common_clear_ram2ba_2
vss_clamp_common_if_ram220_bit0_clr_2:     JBR     off(00220h).0, vss_clamp_common_load_stk
                JBS     off(00213h).5, vss_clamp_common_load_stk
                JBS     off(00213h).6, vss_clamp_common_load_stk
                JBS     off(00216h).1, vss_clamp_common_load_stk
                CMPB    0dbh, #07dh
                JLT     vss_clamp_common_load_stk
                JBS     off(00229h).0, vss_clamp_common_clear_ram09a_bit4
                JBR     off(00229h).2, vss_clamp_common_load_stk
dtc30_at_signal_a_latch: SB      09ah.4
                RB      09ah.5
                JBR     off(00229h).1, vss_clamp_common_if_ram221_bit1_clr
dtc31_at_signal_b_latch_2: SB      09ch.5
                SJ      vss_clamp_common_if_ram221_bit1_clr
vss_clamp_common_clear_ram09a_bit4:     RB      09ah.4
                JBS     off(00229h).2, vss_clamp_common_clear_ram09a_bit5
dtc31_at_signal_b_latch: SB      09ah.5
                JBR     off(00229h).3, vss_clamp_common_if_ram221_bit1_clr
dtc30_at_signal_a_latch_2: SB      09ch.4
                SJ      vss_clamp_common_if_ram221_bit1_clr
vss_clamp_common_load_stk:     MOVB    (001a4h-00180h)[USP], #006h
                MOVB    (001a5h-00180h)[USP], #006h
                RB      09ah.4
vss_clamp_common_clear_ram09a_bit5:     RB      09ah.5
vss_clamp_common_if_ram221_bit1_clr:     JBR     off(00221h).1, idle_gate1_clear
                JBS     off(00212h).7, idle_gate1_clear
                MB      C, off(00237h).0
                MB      PSWH.6, C
                MB      C, P4.3
                MB      off(00237h).0, C
                JGE     vss_clamp_common_if_ne_goto_idle_gate1_timer_check
                XORB    PSWH, #040h
vss_clamp_common_if_ne_goto_idle_gate1_timer_check:     JNE     idle_gate1_timer_check
                CMPB    off(00289h), #00dh
                JLT     idle_gate1_trigger
                JBS     off(00238h).1, idle_gate1_timer_check
idle_gate1_trigger:     MOVB    off(002fdh), #00ah
idle_gate1_clear:     RC
                SJ      dtc24_code24_latch
idle_gate1_timer_check:     LB      A, off(002fdh)
                JNE     idle_gate1_clear
                SC
dtc24_code24_latch:     MB      09ah.3, C
                RB      0a0h.3
                JNE     idle_init_start_load_ram2f3
                MOVB    off(002f3h), #010h
idle_init_start_load_ram2f3:     LB      A, off(002f3h)
                MB      C, PSWH.6
                MB      off(0022ah).5, C
                SB      PSWL.4
                MOV     X1, #003f1h
                LB      A, 00000h[X1]
                CMPB    A, 00008h[X1]
                JEQ     idle_init_start_inc_x1
                STB     A, 00008h[X1]
                RB      PSWL.4
idle_init_start_inc_x1:     INC     X1
idle_init_start_load_tbl_x1:     L       A, 00000h[X1]
                CMP     A, 00008h[X1]
                JEQ     idle_init_start_inc_x1_2
                ST      A, 00008h[X1]
                RB      PSWL.4
idle_init_start_inc_x1_2:     INC     X1
                INC     X1
                CMP     X1, #003f7h
                JLT     idle_init_start_load_tbl_x1
                MB      C, PSWL.4
                JLT     idle_init_start_load_ram2f4
                MOVB    off(002f4h), #005h
idle_init_start_load_ram2f4:     LB      A, off(002f4h)
                MB      C, PSWH.6
                MB      off(0022ah).6, C
                L       A, TIMER
                XCHG    A, 0d2h
                ST      A, er0
                SUB     A, 0d2h
                NOP
                CMP     A, #0ec78h
                JGE     idle_init_start_load_dp
                MOV     DP, #0035eh
                L       A, er0
                ST      A, [DP]
                INC     DP
                INC     DP
                L       A, 0d2h
                ST      A, [DP]
                MOVB    0d4h, #057h
                J       fault_retry_check
idle_init_start_load_dp:     MOV     DP, #003b8h
                LB      A, [DP]
                JNE     idle_init_start_load_ram0f8
                CLRB    0f8h
idle_init_start_load_ram0f8:     LB      A, 0f8h
                CLRB    r0
                SBR     r0
                LB      A, r0
                RB      PSWH.0
                STB     A, off(0021eh)
                STB     A, (0011eh-00180h)[USP]
                SB      PSWH.0
                MOV     X1, #idle_init_start_tbl
                CAL     idle_init_start_sub_load_r3
                MOV     DP, #003c4h
                STB     A, [DP]
                MOV     X1, #idle_init_start_tbl_2
                CAL     idle_init_start_sub_load_r3
                MOV     DP, #003c5h
                STB     A, [DP]
                MOV     X1, #idle_init_start_tbl_3
                CAL     idle_init_start_sub_load_r3
                MOV     DP, #003c6h
                STB     A, [DP]
                MOV     X1, #idle_init_start_tbl_4
                CAL     idle_init_start_sub_load_r3
                MOV     DP, #003c7h
                STB     A, [DP]
                MOV     X1, #idle_init_start_tbl_5
                CAL     idle_init_start_sub_load_r3
                MOV     DP, #003c8h
                STB     A, [DP]
                MOV     X1, #idle_init_start_tbl_6
                CAL     idle_init_start_sub_load_r3
                MOV     DP, #003c9h
                STB     A, [DP]
                JBS     off(0022eh).2, idle_init_start_clear_acc
                MB      C, IRQH.1
                JLT     idle_init_start_set_ram22e_bit2
                RT
idle_init_start_set_ram22e_bit2:     SB      off(0022eh).2
idle_init_start_clear_acc:     CLR     A
                LB      A, off(002f9h)
                JNE     idle_init_start_load_r0
                SB      off(00235h).4
                LB      A, #0c8h
                STB     A, off(002f9h)
idle_init_start_load_r0:     MOVB    r0, #00ah
                DIVB
                LB      A, r1
                JNE     idle_init_start_if_ram2f9_bit0_clr
                SB      off(00235h).3
idle_init_start_if_ram2f9_bit0_clr:     JBR     off(002f9h).0, idle_init_start_load_er3
                J       idle_init_start_load_dp_2
idle_init_start_load_er3:     MOV     er3, off(00270h)
                L       A, ADCR4
                SUB     A, off(0026eh)
                MB      off(00239h).5, C
                MB      PSWL.4, C
                MOV     X1, #000a0h
                MOV     X2, #00800h
                JGE     idle_init_start_load_er0
                VCAL    7
idle_init_start_load_er0:     MOV     er0, #0b000h
                CMP     A, er0
                JGE     idle_init_start_load_imm
                ST      A, er0
idle_init_start_load_imm:     L       A, #00550h
                CAL     idle_helper2
                MOV     DP, A
                L       A, #00120h
                CAL     idle_helper2
                ST      A, off(00272h)
                ST      A, PWM0CMP
                CLRB    A
                JLT     idle_init_start_store_ram2e3
                L       A, DP
                ST      A, off(00270h)
                LB      A, #0ffh
idle_init_start_store_ram2e3:     STB     A, off(002e3h)
                LB      A, #010h
                MOV     DP, #003dbh
                CMPB    [DP], #0ffh
                JGT     transit_flag_common
                RB      TRNSIT.5
                JNE     transit_flag_common
                SC
                LB      A, off(002c6h)
                JEQ     transit_flag_common_store_carry_ram233_bit7
                SUBB    A, #001h
transit_flag_common:     RC
transit_flag_common_store_carry_ram233_bit7:     MB      off(00233h).7, C
                STB     A, off(002c6h)
                JBS     off(00212h).7, transit_flag_common_goto_6ed7
                CAL     transit_flag_common_sub_load_dp
                JLT     transit_flag_common_set_dp_ind
                RB      [DP].0
                JNE     transit_flag_common_call_4afe
                SJ      transit_flag_common_goto_6ed7
transit_flag_common_set_dp_ind:     SB      [DP].0
                JNE     transit_flag_common_goto_6ed7
transit_flag_common_call_4afe:     CAL     cfgvariant_checksum_loop_load_dp
                ST      A, [DP]                ; (a word: the sum and the xor, 362h-363h)
transit_flag_common_goto_6ed7:     J       transit_flag_common_clear_ram232_bit6
idle_init_start_load_dp_2:     MOV     DP, #0c000h
                RB      PSWH.0
                LB      A, off(00226h)
                XORB    A, #024h
                STB     A, [DP]
                CMPB    A, [DP]
                MB      C, PSWH.6
                SB      PSWH.0
                JLT     idle_init_start_if_ram2f9_bit1_clr
                MB      C, 09eh.0
                JLT     idle_init_start_if_ram2f9_bit1_clr
                JBR     off(00232h).7, idle_init_start_call_4aca
                LB      A, #051h
                CAL     idle_init_start_sub_cmp_ram0d7
idle_init_start_call_4aca:     CAL     calchecksum_loop_sub_load_dp
idle_init_start_if_ram2f9_bit1_clr:     JBR     off(002f9h).1, idle_init_start_clear_carry
                J       transit_flag_common_return
idle_init_start_clear_carry:     RC
                JBS     off(00211h).3, dtc12_egr_latch
                CMPB    off(00289h), #0c0h
                MB      off(0022eh).0, C
                JGE     dtc12_egr_latch
                LB      A, #0fah
                CMPB    A, ADCR3H
dtc12_egr_latch:     MB      099h.0, C
                JGE     idle_init_start_load_adcr3h
                MOVB    off(002ebh), #01eh
                SJ      idle_init_start_load_ram2ec
idle_init_start_load_adcr3h:     LB      A, ADCR3H
                STB     A, off(00292h)
                SUBB    A, off(00293h)
                JGE     idle_init_start_if_ram219_bit6_set
                CLRB    A
idle_init_start_if_ram219_bit6_set:     JBS     off(00219h).6, idle_init_start_load_ram2ec
                RC
                JBR     off(00211h).3, idle_init_start_store_carry_ram219_bit6
                STB     A, r0
                LB      A, #070h
                CMPB    A, r0
                JLT     idle_init_start_store_carry_ram219_bit6
                CMPB    r0, #002h
                LB      A, r0
idle_init_start_store_carry_ram219_bit6:     MB      off(00219h).6, C
                JLT     idle_init_start_load_ram2ec
                STB     A, off(00291h)
                JBR     off(0022eh).0, idle_init_start_load_ram2ec
                CMPB    0dbh, #068h
                JLT     idle_init_start_load_ram2ec
                CMPB    0e2h, #030h
                JLT     idle_init_start_load_ram2ec
                CMPB    off(00294h), #018h
                JLT     idle_init_start_load_ram2ec
                SUBB    A, off(00294h)
                RB      off(0022eh).1
                MB      off(0022eh).1, C
                JEQ     idle_init_start_if_ram22e_bit1_clr
                XORB    PSWH, #080h
                JLT     idle_init_start_load_ram2ec
idle_init_start_if_ram22e_bit1_clr:     JBR     off(0022eh).1, idle_init_start_cmp_acc
                VCAL    7
idle_init_start_cmp_acc:     CMPB    A, #006h
                JGT     idle_init_start_load_ram2ec_2
idle_init_start_load_ram2ec:     MOVB    off(002ech), #005h
idle_init_start_load_ram2ec_2:     LB      A, off(002ech)
                MB      C, PSWH.6
dtc12_egr_latch_2: MB      099h.1, C
                CLR     A
                CLR     DP
                RC
                LB      A, off(00294h)
                JEQ     idle_init_start_load_ram276
                L       A, off(00274h)
                JNE     idle_init_start_store_er3
                L       A, #04e20h
idle_init_start_store_er3:     ST      A, er3
                LB      A, off(00291h)
                SUBB    A, off(00294h)
                MB      PSWL.4, C
                JGE     idle_init_start_store_r0
                VCAL    7
idle_init_start_store_r0:     STB     A, r0
                CLRB    r1
                L       A, #000a0h
                MOV     X1, #00000h
                MOV     X2, #09fffh
                CAL     mul_then_clamp_x1x2_2
                MOV     DP, A
                ST      A, er3
                L       A, #00200h
                CAL     mul_then_clamp_x1x2_2
idle_init_start_load_ram276:     MOV     off(00276h), A
                JLT     idle_init_start_load_imm_2
                L       A, DP
                ST      A, off(00274h)
idle_init_start_load_imm_2:     L       A, #0a000h
                SUB     A, off(00276h)
                ST      A, PWM1CMP
                SB      off(00235h).2
transit_flag_common_return:     RT
vcal_4_load_ram22c:     LB      A, off(0022ch)
                MB      C, off(00224h).5
                MB      ACC.0, C
                MB      C, off(00224h).0
                MB      ACC.1, C
                MB      C, off(00216h).7
                MB      ACC.3, C
                MB      C, off(00216h).6
                MB      ACC.7, C
                STB     A, r0
                LB      A, off(0022dh)
                XORB    A, r0
                XNBL    A, off(00239h)
                MOVB    off(0022dh), r0
                LB      A, off(0029eh)
                SUBB    A, 0ddh
                JGE     vcal_4_store_ram29d
                STB     A, r0
                CLRB    A
                SUBB    A, r0
vcal_4_store_ram29d:     STB     A, off(0029dh)
                MB      off(0022ch).7, C
                MOVB    off(0029eh), 0ddh
                LB      A, #0ddh
                JBS     off(0022fh).2, idle_temp_hyst2
                LB      A, #0e0h
idle_temp_hyst2:     CMPB    A, off(00289h)
                MB      off(0022fh).2, C
                LB      A, #060h
                JBS     off(00239h).7, idle_temp_hyst3
                LB      A, #06dh
idle_temp_hyst3:     CMPB    A, off(00289h)
                MB      off(00239h).7, C
                LB      A, off(0021eh)
                ANDB    A, #078h
                JEQ     idle_temp_hyst3_load_adcr2h
                RB      off(00232h).3
                RB      off(00216h).6
                L       A, #01000h
                JBS     off(0021eh).3, idle_temp_hyst3_goto_4192
                L       A, #01c00h
                JBS     off(0021eh).4, idle_temp_hyst3_goto_4192
                L       A, #02b00h
                JBS     off(0021eh).5, idle_temp_hyst3_goto_4192
                L       A, #03fffh
idle_temp_hyst3_goto_4192:     J       idle_temp_hyst3_if_eq_goto_41a6
idle_temp_hyst3_load_adcr2h:     LB      A, ADCR2H
                STB     A, 0dch
                LB      A, #0e0h
                JBS     off(0022fh).1, idle_temp_hyst3_cmp_acc
                LB      A, #0f0h
idle_temp_hyst3_cmp_acc:     CMPB    A, 0dch
                MB      off(0022fh).1, C
                MOV     X1, #rom_55a5
                LB      A, off(00289h)
                VCAL    0
                MOVB    r0, 0dch
                MULB
                L       A, ACC
                SLL     A
                JLT     idle_temp_hyst3_load_imm
                SLL     A
                LB      A, ACCH
                JGE     idle_temp_hyst3_load_x1
idle_temp_hyst3_load_imm:     LB      A, #0ffh
idle_temp_hyst3_load_x1:     MOV     X1, #rom_55af
                VCAL    1
                MOV     X2, A
                MOV     X1, #rom_559b
                LB      A, off(00289h)
                VCAL    0
                STB     A, ACCH
                CLRB    A
                MOV     er0, X2
                MUL
                L       A, ACC
                SLL     A
                ROL     er1
                JLT     idle_temp_hyst3_load_imm_2
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_temp_hyst3_if_ram225_bit3_set
idle_temp_hyst3_load_imm_2:     L       A, #0ffffh
idle_temp_hyst3_if_ram225_bit3_set:     JBS     off(00225h).3, idle_temp_hyst3_store_er3
                MOVB    r1, #0e6h
                CLRB    r0
                MUL
                L       A, er1
idle_temp_hyst3_store_er3:     ST      A, er3
                SB      off(00232h).3
                JEQ     idle_temp_hyst3_clear_r5
                JBS     off(00234h).0, idle_temp_hyst3_clear_acc
                L       A, off(00210h)
                AND     A, #02054h
                JNE     idle_temp_hyst3_clear_acc
                JBR     off(00212h).0, idle_temp_hyst3_load_r2
idle_temp_hyst3_clear_acc:     CLRB    A
                STB     A, r0
                STB     A, r4
                MOVB    r1, #018h
                MOVB    r5, off(002c3h)
                L       A, er3
                MOV     er3, off(00258h)
                CAL     o2trim_add_clamp_sub_sub_acc
                SJ      idle_temp_hyst3_load_er3
idle_temp_hyst3_load_r2:     MOVB    r2, #008h
                JBR     off(00220h).2, idle_temp_hyst3_if_ram224_bit0_set
                JBS     off(0022ch).1, idle_temp_hyst3_if_ram22f_bit1_set
                JBS     off(00235h).1, idle_temp_hyst3_goto_3c4d
idle_temp_hyst3_if_ram22f_bit1_set:     JBS     off(0022fh).1, idle_temp_hyst3_clear_acc
                JBS     off(00224h).0, idle_temp_hyst3_clear_acc
                LB      A, #038h
                JBR     off(0022ch).7, idle_temp_hyst3_cmp_acc_2
                LB      A, #038h
                CLRB    r2
idle_temp_hyst3_cmp_acc_2:     CMPB    A, off(0029dh)
                JGE     idle_temp_hyst3_clear_acc
idle_temp_hyst3_goto_3c4d:     SJ      idle_temp_hyst3_load_ram298
idle_temp_hyst3_if_ram224_bit0_set:     JBS     off(00224h).0, idle_temp_hyst3_clear_acc
                L       A, er3
                SUB     A, off(00258h)
                MOV     er0, #0ffffh
                JGE     idle_temp_hyst3_cmp_acc_3
                VCAL    7
                MOV     er0, #0ffffh
                CLRB    r2
idle_temp_hyst3_cmp_acc_3:     CMP     A, er0
                JLT     idle_temp_hyst3_clear_acc
idle_temp_hyst3_load_ram298:     MOVB    off(00298h), r2
idle_temp_hyst3_clear_r5:     CLRB    r5
idle_temp_hyst3_load_er3:     L       A, er3
                ST      A, off(00258h)
                MOVB    off(002c3h), r5
                J       idle_temp_hyst3_cmp_ram298
                DB  000h,000h,000h
idle_temp_hyst3_add_acc:     ADD     A, #00500h
                J       idle_temp_hyst3_decb_ram298
idle_temp_hyst3_store_ram284:     ST      A, off(00284h)
                MB      C, off(00235h).1
                MB      off(0022ch).1, C
                RB      09eh.3
                JEQ     idle_temp_hyst3_if_ram22e_bit5_clr
                CAL     vcal_4_load_dp
idle_temp_hyst3_if_ram22e_bit5_clr:     JBR     off(0022eh).5, idle_temp_hyst3_load_ram248
                MOV     off(00246h), #00380h
                MOV     X1, #rom_55d0
                LB      A, off(00289h)
                VCAL    0
                L       A, ACC
                SWAP
                CLRB    A
                MOV     er0, off(00242h)
                MUL
                L       A, ACC
                SLL     A
                L       A, er1
                ROL     A
                CAL     idle_temp_hyst3_sub_add_acc
                L       A, off(00248h)
                JEQ     idle_temp_hyst3_load_ram244
                SUB     A, #00300h
                JGE     idle_temp_hyst3_store_ram248
                CLR     A
idle_temp_hyst3_store_ram248:     ST      A, off(00248h)
                SJ      idle_temp_hyst3_load_ram244
idle_temp_hyst3_load_ram248:     MOV     off(00248h), #00c00h
                L       A, off(00244h)
                JEQ     idle_temp_hyst3_clear_pswl_bit5
                L       A, off(00246h)
                ST      A, er2
                SUB     A, #00030h
                JGE     idle_temp_hyst3_store_ram246
                CLR     A
idle_temp_hyst3_store_ram246:     ST      A, off(00246h)
                L       A, er2
                SRA     A
                ROL     A
                J       idle_temp_hyst3_if_ge_goto_70b0
idle_temp_hyst3_load_ram244:     MOV     off(00244h), er2
idle_temp_hyst3_clear_pswl_bit5:     RB      PSWL.5
                JBR     off(00220h).0, idle_temp_hyst3_clear_acc_2
                JBS     off(00224h).5, idle_temp_hyst3_clear_acc_2
                CMPB    0d9h, #03bh
                JLT     idle_temp_hyst3_cmp_ram0d9
                LB      A, off(002e4h)
                JEQ     idle_temp_hyst3_set_pswl_bit5
                SC
                RB      PSWH.0
                JBS     off(00219h).4, idle_temp_hyst3_set_pswh_bit0
                CMP     0b0h, #00011h
idle_temp_hyst3_set_pswh_bit0:     SB      PSWH.0
                JGE     idle_temp_hyst3_set_pswl_bit5
                L       A, off(00240h)
                JEQ     idle_temp_hyst3_store_ram240
idle_temp_hyst3_set_pswl_bit5:     SB      PSWL.5
idle_temp_hyst3_cmp_ram0d9:     CMPB    0d9h, #038h
                JGE     idle_temp_hyst3_load_ram23e
                MOV     X1, #rom_55f5
                L       A, off(00286h)
                CAL     idleign_table_lookup_sub_load_acc
                CMP     A, off(0023eh)
                JGE     idle_temp_hyst3_store_ram240
idle_temp_hyst3_load_ram23e:     L       A, off(0023eh)
                SJ      idle_temp_hyst3_store_ram240
idle_temp_hyst3_clear_acc_2:     CLR     A
                MOVB    off(002e4h), #032h
idle_temp_hyst3_store_ram240:     ST      A, off(00240h)
                MB      C, PSWL.5
                MB      off(0022ch).0, C
                JBS     off(00216h).1, idle_temp_hyst3_clear_ram22c_bit4
                CMPB    0d9h, #0d1h
                JLT     idle_temp_hyst3_if_ram22c_bit4_clr
idle_temp_hyst3_clear_ram22c_bit4:     RB      off(0022ch).4
                CLRB    off(00296h)
                SJ      idle_temp_hyst3_clear_acc_3
idle_temp_hyst3_if_ram22c_bit4_clr:     JBR     off(0022ch).4, idle_temp_hyst3_if_ram22c_bit2_set
                JBR     off(0022ch).2, idle_temp_hyst3_goto_4f70
                L       A, #00200h
                CMPB    off(00296h), #000h
                JEQ     idle_temp_hyst3_store_ram24a
                J       idle_temp_hyst3_decb_ram296
                DB  067h ; 3D2A
;@ Stock_rom_3d2b type=u16 count=2 formula=raw category="Internal" desc="Stock data, 4 bytes, read by the code at idle_temp_hyst3_decb_ram296; its role not traced."
rom_3d2b:       DB  000h,004h,0CBh,00Bh ; 3D2B
idle_temp_hyst3_if_ram22c_bit2_set:     JBS     off(0022ch).2, idle_temp_hyst3_clear_acc_3
                SB      off(0022ch).4
idle_temp_hyst3_goto_4f70:     J       idle_temp_hyst3_load_imm_4
;@ Stock_rom_3d38 type=u8 count=1 formula=raw category="Internal" desc="Stock data, 1 bytes, read by the code at idle_temp_hyst3_load_imm_4; its role not traced."
rom_3d38:       DB  004h
idle_temp_hyst3_clear_acc_3:     CLR     A
idle_temp_hyst3_store_ram24a:     ST      A, off(0024ah)
                LB      A, #0d0h
                JBS     off(0022ah).4, idle_temp_hyst3_cmp_acc_4
                LB      A, #0e0h
idle_temp_hyst3_cmp_acc_4:     CMPB    A, off(00289h)
                MB      off(0022ah).4, C
                CLR     er3
                RC
                JBS     off(0022ah).4, idle_temp_hyst3_load_r0
                JBR     off(00216h).5, idle_temp_hyst3_load_r0
                JBS     off(00210h).6, idle_temp_hyst3_load_r0
                MB      C, 098h.2
                XORB    PSWH, #080h
                JGE     idle_temp_hyst3_load_r0
                LB      A, off(00289h)
                MOV     X1, #idle_temp_hyst3_tbl_4
                VCAL    1
                CLR     A
                MOV     DP, #0032fh
                LB      A, [DP]
                ADDB    A, #003h
                MOV     er0, A
                L       A, 0aah
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SUB     A, er0
                JGE     idle_temp_hyst3_load_er0
                CLR     A
idle_temp_hyst3_load_er0:     MOV     er0, #idle_temp_hyst3_tbl_3
                MUL
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     idle_temp_hyst3_cmp_acc_5
                L       A, #0ffffh
idle_temp_hyst3_cmp_acc_5:     CMP     A, er3
                JLT     idle_temp_hyst3_store_er3_2
                L       A, er3
idle_temp_hyst3_store_er3_2:     ST      A, er3
                ADD     A, #00100h
                CMP     A, off(0025ch)
idle_temp_hyst3_load_r0:     MOVB    r0, #0ffh
                JGE     idle_temp_hyst3_load_er3_2
                LB      A, off(002fch)
                JNE     idle_temp_hyst3_clear_ram09e_bit3
                L       A, off(0025ch)
                CLR     er0
                MOVB    r1, off(002c8h)
                MUL
                LB      A, #018h
                JBS     off(00220h).0, idle_temp_hyst3_xchgb_acc
                LB      A, #018h
idle_temp_hyst3_xchgb_acc:     XCHGB   A, r1
                SUBB    A, r1
                JGE     idle_temp_hyst3_store_r0
                CLRB    A
idle_temp_hyst3_store_r0:     STB     A, r0
                L       A, er1
                CMP     A, er3
                JGE     idle_temp_hyst3_store_ram25c
idle_temp_hyst3_load_er3_2:     L       A, er3
idle_temp_hyst3_store_ram25c:     ST      A, off(0025ch)
                MOVB    off(002c8h), r0
                MOVB    off(002fch), #00fh
idle_temp_hyst3_clear_ram09e_bit3:     RB      09eh.3
                JEQ     idle_temp_hyst3_if_ram216_bit1_clr
                CAL     vcal_4_load_dp
idle_temp_hyst3_if_ram216_bit1_clr:     JBR     off(00216h).1, idle_temp_hyst3_clear_ram22c_bit5
                CLR     off(0025ch)
                SB      off(0022ch).5
                RB      off(00216h).6
                RB      off(0022ch).6
                J       idle_temp_hyst3_load_er3_4
idle_temp_hyst3_clear_ram22c_bit5:     RB      off(0022ch).5
                JBR     off(00217h).2, idle_temp_hyst3_load_carry_ram098_bit1
                J       idle_temp_hyst3_clear_ram216_bit6_2
idle_temp_hyst3_load_carry_ram098_bit1:     MB      C, 098h.1
                JLT     idle_temp_hyst3_goto_3ee3
                JBS     off(00210h).5, idle_temp_hyst3_goto_3ee3
                L       A, off(00210h)
                AND     A, #02054h
                JNE     idle_temp_hyst3_goto_3eef
                JBS     off(00212h).0, idle_temp_hyst3_goto_3eef
                SJ      idle_temp_hyst3_load_ram210
idle_temp_hyst3_goto_3ee3:     J       idle_temp_hyst3_call_4a61_3
idle_temp_hyst3_goto_3eef:     J       idle_temp_hyst3_call_4a61_4
idle_temp_hyst3_load_ram210:     L       A, off(00210h)
                JNE     idle_temp_hyst3_call_4a61
                L       A, off(00212h)
                AND     A, #09cffh
                JEQ     idle_temp_hyst3_if_ram216_bit4_set
idle_temp_hyst3_call_4a61:     CAL     idle_temp_hyst3_sub_load_dp
idle_temp_hyst3_if_ram216_bit4_set:     JBS     off(00216h).4, idle_temp_hyst3_clear_ram216_bit6
                CLR     off(0025ch)
                MOV     X1, #rom_555c
                LB      A, 0d9h
                VCAL    0
                CMPB    A, off(00289h)
                JLT     idle_temp_hyst3_clear_ram2f6
                JBR     off(00216h).2, idle_temp_hyst3_clear_ram2f6
                MOV     er0, off(0025ah)
                CMPB    A, 0eah
                JGE     idle_temp_hyst3_load_ram2f6
                L       A, 0b2h
                MOV     DP, A
                MOV     X1, #rom_556a
                LB      A, 0d9h
                VCAL    1
                ; warning: had to flip DD
                CMP     A, DP
                JGT     idle_temp_hyst3_clear_ram2f6
                MOV     X1, #rom_557f
                LB      A, 0d9h
                VCAL    0
                STB     A, off(002f6h)
                MOV     X1, #rom_558d
                LB      A, 0d9h
                VCAL    0
                CLR     er0
                STB     A, r0
                L       A, DP
                MUL
                MOV     er0, #02000h
                CMP     er1, #00000h
                JNE     idle_temp_hyst3_load_ram2f6
                CMP     A, er0
                JGE     idle_temp_hyst3_load_ram2f6
                ST      A, er0
idle_temp_hyst3_load_ram2f6:     LB      A, off(002f6h)
                JNE     idle_temp_hyst3_load_ram25a
idle_temp_hyst3_clear_ram2f6:     CLRB    off(002f6h)
                CLR     er0
idle_temp_hyst3_load_ram25a:     MOV     off(0025ah), er0
                JBR     off(00220h).0, idle_temp_hyst3_set_ram216_bit6
                JBS     off(00224h).5, idle_temp_hyst3_set_ram216_bit6
                JBR     off(0022ch).0, idle_temp_hyst3_set_ram216_bit6
                RB      off(00216h).6
                SB      off(0022ch).6
                J       idle_temp_hyst3_load_er3_6
idle_temp_hyst3_set_ram216_bit6:     SB      off(00216h).6
idle_temp_hyst3_clear_ram22c_bit6:     RB      off(0022ch).6
                J       idle_temp_hyst3_clear_ram09e_bit3_2
idle_temp_hyst3_clear_ram216_bit6:     RB      off(00216h).6
                CLR     er3
                JBR     off(00239h).7, idle_temp_hyst3_load_er3_3
                JBR     off(0021ah).0, idle_temp_hyst3_load_er3_3
                CMPB    0d9h, #02eh
                JGE     idle_temp_hyst3_load_er3_3
                CMPB    0dfh, #005h
                JLT     idle_temp_hyst3_load_er3_3
                L       A, off(0025ch)
                JNE     idle_temp_hyst3_load_er3_3
                LB      A, off(00289h)
                MOV     X1, #idle_temp_hyst3_tbl_2
                JBS     off(0021dh).1, idle_temp_hyst3_vcal_1
                MOV     X1, #idle_temp_hyst3_tbl
idle_temp_hyst3_vcal_1:     VCAL    1
idle_temp_hyst3_load_er3_3:     L       A, er3
                ST      A, off(0025eh)
                JEQ     idle_temp_hyst3_goto_3e76
                RB      off(0022ch).6
                J       idle_temp_hyst3_load_er3_7
idle_temp_hyst3_goto_3e76:     J       idle_temp_hyst3_clear_ram22c_bit6
idle_temp_hyst3_clear_ram216_bit6_2:     RB      off(00216h).6
                JBR     off(0022fh).2, idle_temp_hyst3_load_carry_ram098_bit1_2
                RB      off(0022ch).6
                L       A, #02000h
                J       idle_gear_target_final
idle_temp_hyst3_load_carry_ram098_bit1_2:     MB      C, 098h.1
                JLT     idle_temp_hyst3_call_4a61_3
                JBS     off(00210h).5, idle_temp_hyst3_call_4a61_3
                L       A, off(00210h)
                AND     A, #02054h
                JNE     idle_temp_hyst3_call_4a61_4
                JBS     off(00212h).0, idle_temp_hyst3_call_4a61_4
                L       A, off(00210h)
                JNE     idle_temp_hyst3_call_4a61_2
                L       A, off(00212h)
                AND     A, #09cffh
                JEQ     idle_temp_hyst3_goto_3eae
idle_temp_hyst3_call_4a61_2:     CAL     idle_temp_hyst3_sub_load_dp
idle_temp_hyst3_goto_3eae:     J       idle_temp_hyst3_goto_3e76
idle_temp_hyst3_call_4a61_3:     CAL     idle_temp_hyst3_sub_load_dp
                RB      off(00216h).6
                RB      off(0022ch).6
                J       idle_temp_hyst3_load_er3_5
idle_temp_hyst3_call_4a61_4:     CAL     idle_temp_hyst3_sub_load_dp
                RB      off(00216h).6
                RB      off(0022ch).6
                J       idle_temp_hyst3_clear_er3
idle_temp_hyst3_clear_ram09e_bit3_2:     RB      09eh.3
                JEQ     idle_temp_hyst3_load_ram256
                CAL     vcal_4_load_dp
idle_temp_hyst3_load_ram256:     MOV     off(00256h), off(00254h)
                MOVB    off(002a0h), off(0029fh)
                JBS     off(00216h).6, idle_temp_hyst3_if_ram22d_bit7_set
                JBS     off(0022dh).7, idle_temp_hyst3_if_ram216_bit2_set
                JBS     off(00216h).3, idle_temp_hyst3_load_imm_3
                JBR     off(00216h).2, idle_temp_hyst3_load_imm_3
                SJ      idle_temp_hyst3_load_ram260
idle_temp_hyst3_if_ram22d_bit7_set:     JBS     off(0022dh).7, idle_temp_hyst3_if_ram220_bit0_clr
                JBR     off(0022dh).5, idle_temp_hyst3_if_ram216_bit2_set
                L       A, off(00268h)
                SJ      idle_temp_hyst3_load_dp
idle_temp_hyst3_if_ram220_bit0_clr:     JBR     off(00220h).0, idle_temp_hyst3_if_ram239_bit1_set
                JBS     off(00239h).0, idle_temp_hyst3_if_ram216_bit2_set
idle_temp_hyst3_if_ram239_bit1_set:     JBS     off(00239h).1, idle_temp_hyst3_if_ram216_bit2_set
                JBR     off(0022dh).4, idle_temp_hyst3_load_imm_3
                JBR     off(00239h).2, idle_temp_hyst3_load_imm_3
idle_temp_hyst3_if_ram216_bit2_set:     JBS     off(00216h).2, idle_temp_hyst3_if_ram220_bit0_clr_2
                L       A, off(00262h)
                SJ      idle_temp_hyst3_load_dp
idle_temp_hyst3_if_ram220_bit0_clr_2:     JBR     off(00220h).0, idle_temp_hyst3_load_ram260
                JBS     off(00224h).5, idle_temp_hyst3_load_ram260
                JBR     off(0022dh).6, idle_temp_hyst3_load_ram260
                CLR     A
                LC      A, rom_5558
                ADD     A, off(00260h)
                SJ      idle_temp_hyst3_store_ram254
idle_temp_hyst3_load_ram260:     L       A, off(00260h)
idle_temp_hyst3_load_dp:     MOV     DP, #0030eh
                ADD     A, [DP]
idle_temp_hyst3_store_ram254:     ST      A, off(00254h)
                ST      A, off(00256h)
                CLRB    A
                STB     A, off(0029fh)
                STB     A, off(002a0h)
idle_temp_hyst3_load_imm_3:     LB      A, #043h
                STB     A, r2
                JBS     off(00216h).6, idle_temp_hyst3_if_ram216_bit5_clr
                STB     A, off(00297h)
                JBS     off(00216h).7, idle_temp_hyst3_load_x1_3
idle_temp_hyst3_load_x1_2:     MOV     X1, #rom_5550
                SJ      idle_temp_hyst3_clear_pswh_bit0
idle_temp_hyst3_if_ram216_bit5_clr:     JBR     off(00216h).5, idle_temp_hyst3_if_ram216_bit2_set_2
                STB     A, off(00297h)
idle_temp_hyst3_load_x1_3:     MOV     X1, #rom_554d
                SJ      idle_temp_hyst3_clear_pswh_bit0
idle_temp_hyst3_if_ram216_bit2_set_2:     JBS     off(00216h).2, idle_temp_hyst3_load_ram0d9
                CMPB    0ffh, #096h
                JLT     idle_temp_hyst3_if_ram216_bit7_clr
idle_temp_hyst3_load_ram0d9:     LB      A, 0d9h
                MOV     X1, #idle_temp_hyst3_tbl_5
                VCAL    0
                LB      A, off(00295h)
                SUBB    A, r6
                JLT     idle_temp_hyst3_load_ram297
                CMPB    A, off(00289h)
                JGE     idle_temp_hyst3_load_r2_2
idle_temp_hyst3_load_ram297:     LB      A, off(00297h)
                JEQ     idle_temp_hyst3_load_x1_4
                DECB    off(00297h)
                SJ      idle_temp_hyst3_load_x1_3
idle_temp_hyst3_load_r2_2:     LB      A, r2
                STB     A, off(00297h)
idle_temp_hyst3_load_x1_4:     MOV     X1, #rom_5547
                SJ      idle_temp_hyst3_clear_pswh_bit0
idle_temp_hyst3_if_ram216_bit7_clr:     JBR     off(00216h).7, idle_temp_hyst3_load_x1_2
                MOV     X1, #rom_554a
idle_temp_hyst3_clear_pswh_bit0:     RB      PSWH.0
                MOV     er0, 0b4h
                MB      C, off(00216h).7
                SB      PSWH.0
                MB      PSWL.4, C
                MOV     er2, er0
                CLR     A
                LCB     A, [X1]
                SWAP
                MUL
                L       A, er1
                MB      C, PSWL.4
                JGE     idle_temp_hyst3_store_ram24c
                VCAL    7
idle_temp_hyst3_store_ram24c:     ST      A, off(0024ch)
                INC     X1
                MOV     er0, er2
                CLR     A
                LCB     A, [X1]
                SWAP
                MUL
                ST      A, er0
                L       A, er1
                MB      C, PSWL.4
                JGE     idle_temp_hyst3_store_ram24e
                CLRB    A
                SUBB    A, r1
                STB     A, r1
                CLR     A
                SBC     A, er1
idle_temp_hyst3_store_ram24e:     ST      A, off(0024eh)
                MOVB    off(002a1h), r1
                INC     X1
                MOV     er0, 0b2h
                CLR     A
                LCB     A, [X1]
                SWAP
                MUL
                L       A, er1
                JBR     off(00219h).5, idle_temp_hyst3_store_ram250
                VCAL    7
idle_temp_hyst3_store_ram250:     ST      A, off(00250h)
                MOV     DP, #0030eh
                CLR     A
                MOV     er0, off(00262h)
                MOVB    ACCH, #025h
                JBR     off(00216h).2, idle_temp_hyst3_mul_acc
                MOV     er0, off(00260h)
                MOVB    ACCH, #052h
                JBR     off(00216h).6, idle_temp_hyst3_mul_acc
                JBR     off(00216h).5, idle_temp_hyst3_mul_acc
                CMPB    0d9h, #07ah
                JGE     idle_temp_hyst3_mul_acc
                MOV     er2, [DP]
                SJ      idle_temp_hyst3_clear_acc_4
idle_temp_hyst3_mul_acc:     MUL
                SLL     A
                ROL     er1
                L       A, er1
                ADD     A, [DP]
                SUB     A, #00600h
                JGE     idle_temp_hyst3_store_er2
                CLR     A
idle_temp_hyst3_store_er2:     ST      A, er2
idle_temp_hyst3_clear_acc_4:     CLR     A
                MOVB    ACCH, #080h
                JBS     off(00216h).2, idle_temp_hyst3_mul_acc_2
                MOVB    ACCH, #099h
idle_temp_hyst3_mul_acc_2:     MUL
                SLL     A
                ROL     er1
                J       idle_temp_hyst3_load_er1
idle_temp_hyst3_add_acc_2:     ADD     A, #01800h
                NOP
                NOP
                J       idle_temp_hyst3_if_lt_goto_705f
idle_temp_hyst3_load_x1_5:     MOV     X1, A
                L       A, off(0024eh)
                ST      A, er3
                SLL     A
                MB      PSWL.4, C
                LB      A, off(002a1h)
                ADDB    A, off(0029fh)
                STB     A, r1
                L       A, off(00254h)
                ADC     A, er3
                RB      PSWL.4
                JNE     idle_temp_hyst3_if_ge_goto_4056
                JLT     idle_temp_hyst3_load_x1_6
                SJ      idle_temp_hyst3_cmp_acc_6
idle_temp_hyst3_if_ge_goto_4056:     JGE     idle_temp_hyst3_load_er2
idle_temp_hyst3_cmp_acc_6:     CMP     A, er2
                JGE     idle_temp_hyst3_cmp_acc_7
idle_temp_hyst3_load_er2:     L       A, er2
                CLRB    r1
idle_temp_hyst3_cmp_acc_7:     CMP     A, X1
                JLE     idle_temp_hyst3_store_er1
idle_temp_hyst3_load_x1_6:     L       A, X1
                CLRB    r1
idle_temp_hyst3_store_er1:     ST      A, er1
                ST      A, er3
                L       A, off(0024ch)
                VCAL    5
                L       A, off(00250h)
                VCAL    5
                CMP     A, X1
                JLE     idle_temp_hyst3_cmp_acc_8
                L       A, X1
                SJ      idle_temp_hyst3_store_ram252
idle_temp_hyst3_cmp_acc_8:     CMP     A, er2
                JGE     idle_temp_hyst3_load_ram254
                L       A, er2
                SJ      idle_temp_hyst3_store_ram252
idle_temp_hyst3_load_ram254:     MOV     off(00254h), er1
                MOVB    off(0029fh), r1
idle_temp_hyst3_store_ram252:     ST      A, off(00252h)
                L       A, off(00210h)
                JEQ     idle_temp_hyst3_load_ram212
                J       idle_temp_hyst3_load_ram25a_2
idle_temp_hyst3_load_ram212:     L       A, off(00212h)
                AND     A, #09cffh
                JNE     idle_temp_hyst3_load_ram25a_2
                JBR     off(00216h).6, idle_temp_hyst3_load_ram25a_2
                JBS     off(00216h).5, idle_temp_hyst3_load_ram25a_2
                JBR     off(00216h).2, idle_temp_hyst3_load_ram25a_2
                L       A, off(0024ah)
                JNE     idle_temp_hyst3_load_ram25a_2
                JBS     off(00224h).0, idle_temp_hyst3_load_ram25a_2
                CMPB    0e2h, #047h
                JLT     idle_temp_hyst3_load_ram25a_2
                JBR     off(00239h).3, idle_temp_hyst3_load_ram25a_2
                CMP     0b4h, #00095h
                JGE     idle_temp_hyst3_load_ram25a_2
                CMPB    0d9h, #057h
                JGE     idle_temp_hyst3_load_ram25a_2
                JBR     off(0021bh).1, idle_temp_hyst3_load_ram25a_2
                MOV     X1, #0030eh
                MOV     er3, 00000h[X1]
                MOV     er2, 00002h[X1]
                L       A, off(00254h)
                SUB     A, er3
                MB      PSWL.4, C
                JGE     idle_temp_hyst3_clear_r1
                ST      A, er0
                CLR     A
                SUB     A, er0
idle_temp_hyst3_clear_r1:     CLRB    r1
                MOVB    r0, #0ffh
                CMPB    0d9h, #028h
                JLT     idle_temp_hyst3_mul_acc_3
                MOVB    r0, #001h
idle_temp_hyst3_mul_acc_3:     MUL
                MB      C, PSWL.4
                JLT     idle_temp_hyst3_sub_er2
                ADD     er2, A
                L       A, er3
                ADC     A, er1
                SJ      idle_temp_hyst3_load_dp_2
idle_temp_hyst3_sub_er2:     SUB     er2, A
                L       A, er3
                SBC     A, er1
idle_temp_hyst3_load_dp_2:     MOV     DP, #rom_5554
                CMPC    A, [DP]
                JLT     idle_temp_hyst3_rom_load_dp_ind
                INC     DP
                INC     DP
                CMPC    A, [DP]
                JLT     idle_temp_hyst3_store_tbl_x1
idle_temp_hyst3_rom_load_dp_ind:     LC      A, [DP]
                CLR     er2
idle_temp_hyst3_store_tbl_x1:     ST      A, 00000h[X1]
                L       A, er2
                ST      A, 00002h[X1]
idle_temp_hyst3_load_ram25a_2:     L       A, off(0025ah)
                JBS     off(00216h).6, idle_temp_hyst3_store_er3_3
                L       A, off(0025ch)
idle_temp_hyst3_store_er3_3:     ST      A, er3
                L       A, off(00252h)
                SJ      idle_temp_hyst3_clear_ram09e_bit3_3
idle_temp_hyst3_load_er3_4:     MOV     er3, off(00268h)
                SJ      idle_temp_hyst3_rom_load_ram5558
idle_temp_hyst3_load_er3_5:     MOV     er3, #00900h
                SJ      idle_temp_hyst3_rom_load_ram5558
idle_temp_hyst3_clear_er3:     CLR     er3
                SJ      idle_temp_hyst3_load_ram260_2
idle_temp_hyst3_load_er3_6:     MOV     er3, off(0025ah)
idle_temp_hyst3_load_ram260_2:     L       A, off(00260h)
                CAL     tipin_time_finalize_sub_load_acc
idle_temp_hyst3_rom_load_ram5558:     LC      A, rom_5558
                JBS     off(00220h).0, idle_temp_hyst3_clear_ram09e_bit3_3
                LC      A, rom_555a
idle_temp_hyst3_clear_ram09e_bit3_3:     RB      09eh.3
                JEQ     idle_temp_hyst3_call_44b5
                PUSHS   A
                L       A, er3
                PUSHS   A
                CAL     vcal_4_load_dp
                POPS    A
                ST      A, er3
                POPS    A
idle_temp_hyst3_call_44b5:     CAL     tipin_time_finalize_sub_load_acc
                L       A, off(00240h)
                CAL     tipin_time_finalize_sub_load_acc
                L       A, off(00244h)
                CAL     tipin_time_finalize_sub_load_acc
                L       A, off(00284h)
                CAL     tipin_time_finalize_sub_load_acc
                L       A, off(0026ah)
                CAL     tipin_time_finalize_sub_load_acc
                L       A, off(0024ah)
                SJ      idle_temp_hyst3_clear_ram09e_bit3_4
idle_temp_hyst3_load_er3_7:     MOV     er3, off(0025eh)
                MOV     DP, #0030eh
                L       A, [DP]
idle_temp_hyst3_clear_ram09e_bit3_4:     RB      09eh.3
                JEQ     idle_temp_hyst3_call_44b5_2
                PUSHS   A
                L       A, er3
                PUSHS   A
                CAL     vcal_4_load_dp
                POPS    A
                ST      A, er3
                POPS    A
idle_temp_hyst3_call_44b5_2:     CAL     tipin_time_finalize_sub_load_acc
                MB      C, ACCH.7
                JLT     idle_temp_hyst3_clear_acc_5
                CLR     A
                LB      A, off(00299h)
                L       A, ACC
                SWAP
                MOV     er0, er3
                MUL
                SLL     A
                L       A, er1
                ROL     A
                MB      C, ACCH.7
                JGE     idle_temp_hyst3_store_er3_4
                L       A, #07fffh
idle_temp_hyst3_store_er3_4:     ST      A, er3
                L       A, off(00266h)
                CAL     tipin_time_finalize_sub_load_acc
                L       A, off(0026ch)
                CAL     tipin_time_finalize_sub_load_acc
                L       A, er3
idle_temp_hyst3_if_eq_goto_41a6:     JEQ     idle_temp_hyst3_clear_acc_5
                MB      C, ACCH.7
                JLT     idle_temp_hyst3_clear_acc_5
                MOV     er3, #04000h
                CMP     A, er3
                JLT     idle_gear_target_store
                L       A, er3
                JBS     off(00216h).7, idle_gear_target_store
                SJ      idle_gear_target_reset
idle_temp_hyst3_clear_acc_5:     CLR     A
                JBR     off(00216h).7, idle_gear_target_store
idle_gear_target_reset:     MOV     off(00254h), off(00256h)
                MOVB    off(0029fh), off(002a0h)
idle_gear_target_store:     ST      A, off(0023ch)
                MOV     X1, #idle_gear_target_store_tbl
                CAL     idleign_table_lookup_sub_load_acc
idle_gear_target_final:     ST      A, off(0026eh)
                MB      C, off(00216h).2
                MB      off(00216h).3, C
                RB      09eh.3
                JEQ     idle_gear_target_final_return
                CAL     vcal_4_load_dp
idle_gear_target_final_return:     RT
vcal_4_load_r0:     MOVB    r0, #00eh
                MOV     DP, #001e1h
                CAL     learn_table2_check_sub_clear_pswh_bit0
                MOVB    r0, #01eh
                MOV     DP, #002d5h
                CAL     learn_table2_check_sub_clear_pswh_bit0
                LB      A, 0ffh
                ADDB    A, #001h
                JEQ     vcal_4_load_ram2c0
                STB     A, 0ffh
vcal_4_load_ram2c0:     LB      A, off(002c0h)
                JEQ     percyl_counter_gate
                CMPB    off(002e0h), #000h
                JNE     percyl_alt_check
                MOVB    r2, #010h
                CMPB    A, r2
                JGE     percyl_counter_check2
                MOVB    r2, #001h
percyl_counter_check2:     SUBB    A, r2
                MOV     er1, #01107h
                JNE     percyl_store_result
percyl_counter_gate:     SC
                JBR     off(00212h).7, percyl_counter_gate_clear_acc
                J       percyl_counter_gate_store_carry_ram226_bit4
percyl_counter_gate_clear_acc:     CLR     A
percyl_counter_gate_load_ram2c1:     LB      A, off(002c1h)
                CMPB    A, #020h
                JLT     percyl_counter_dp_select
                CLRB    off(002c1h)
                LCB     A, 07ff1h
                JNE     percyl_counter_gate_store_carry_ram226_bit4
                LB      A, 0d5h
                JEQ     percyl_counter_gate_store_carry_ram226_bit4
                SJ      percyl_bcd_convert
percyl_counter_dp_select:     MOV     DP, #00333h
                CMPB    A, #018h
                JGE     percyl_counter_increment
                DEC     DP
                JBS     off(002c1h).4, percyl_counter_increment
                DEC     DP
                JBS     off(002c1h).3, percyl_counter_increment
                DEC     DP
percyl_counter_increment:     INCB    off(002c1h)
                TRB     [DP]
                JNE     percyl_wrap_check1
                LB      A, off(002c1h)
                ANDB    A, #007h
                JNE     percyl_counter_gate_load_ram2c1
                RC
                SJ      percyl_counter_gate_store_carry_ram226_bit4
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
percyl_store_result:     STB     A, off(002c0h)
                CMPB    A, #010h
                JLT     percyl_result_final
                MOVB    r2, r3
percyl_result_final:     MOVB    off(002e0h), r2
percyl_alt_check:     CMPB    A, #010h
                L       A, #00206h
                JLT     percyl_alt_store
                L       A, #00311h
percyl_alt_store:     ST      A, er1
                LB      A, off(002e0h)
                CMPB    A, r2
                JGE     percyl_counter_gate_store_carry_ram226_bit4
                CMPB    r3, A
percyl_counter_gate_store_carry_ram226_bit4:     MB      off(00226h).4, C
                JBR     off(00224h).2, percyl_counter_gate_clear_pswl_bit4
                MOV     DP, #00330h
                L       A, [DP]
                JNE     percyl_counter_gate_store_carry_ram226_bit3
                INC     DP
                INC     DP
                L       A, [DP]
                JNE     percyl_counter_gate_store_carry_ram226_bit3
                LCB     A, 07ff1h
                JNE     percyl_counter_gate_set_carry
                LB      A, 0d5h
                JNE     percyl_counter_gate_store_carry_ram226_bit3
percyl_counter_gate_set_carry:     SC
percyl_counter_gate_store_carry_ram226_bit3:     MB      off(00226h).3, C
percyl_counter_gate_clear_pswl_bit4:     RB      PSWL.4
                SB      PSWL.5
                JBR     off(00220h).4, percyl_counter_gate_load_carry_pswl_bit4
                JBS     off(00212h).5, percyl_counter_gate_load_carry_pswl_bit4
                JBS     off(00213h).1, percyl_counter_gate_load_carry_pswl_bit4
                JBS     off(00213h).0, percyl_counter_gate_load_carry_pswl_bit4
                L       A, off(00210h)
                AND     A, #001bch
                JNE     percyl_counter_gate_load_carry_pswl_bit4
                JBR     off(00215h).0, percyl_counter_gate_load_carry_pswl_bit4
                JBS     off(00215h).1, percyl_counter_gate_load_carry_pswl_bit4
                SB      PSWL.4
                RB      PSWL.5
                LB      A, 0d9h
                CMPB    A, #0ffh
                JLE     percyl_counter_gate_load_carry_pswl_bit4
                CMPB    A, #0ffh
                JGE     percyl_counter_gate_load_carry_pswl_bit4
                SB      off(00226h).5
                JEQ     percyl_counter_gate_load_carry_pswl_bit4
                RB      PSWL.4
percyl_counter_gate_load_carry_pswl_bit4:     MB      C, PSWL.4
                MB      off(00226h).5, C
                MB      C, PSWL.5
                MB      off(0022ah).3, C
                CAL     percyl_counter_gate_sub_load_dp
                RB      09eh.3
                JEQ     percyl_counter_gate_return
                CAL     vcal_4_load_dp
percyl_counter_gate_return:     RT
vcal_4_load_r0_2:     MOVB    r0, #005h
                MOV     DP, #001dch
                CAL     learn_table2_check_sub_clear_pswh_bit0
                MOVB    r0, #008h
                MOV     DP, #002cdh
                CAL     learn_table2_check_sub_clear_pswh_bit0
                LB      A, 0feh
                ADDB    A, #001h
                JEQ     vcal_4_load_imm_3
                STB     A, 0feh
vcal_4_load_imm_3:     LB      A, #0ffh
                CMPB    A, (001d9h-00180h)[USP]
                JLE     vcal_4_cmp_acc
                INCB    (001d9h-00180h)[USP]
vcal_4_cmp_acc:     CMPB    A, (001d8h-00180h)[USP]
                JLE     vcal_4_load_ram29a
                INCB    (001d8h-00180h)[USP]
vcal_4_load_ram29a:     L       A, off(0029ah)
                JEQ     learn_table1_check
                DEC     off(0029ah)
learn_table1_check:     LB      A, off(002cfh)
                JNE     learn_table2_check
                MOVB    off(002cfh), #005h
                MOV     X1, #learn_table1_check_tbl
                MOV     DP, #001a6h
                MOVB    r6, #027h
learn_table1_loop:     LB      A, [DP]
                ADDB    A, #001h
                CMPCB   A, [X1]
                JLT     learn_table1_store
                LCB     A, [X1]
learn_table1_store:     STB     A, [DP]
                LB      A, r6
                SUBB    A, 0f1h
                JNE     learn_table1_advance
                STB     A, 0f1h
learn_table1_advance:     INC     X1
                INC     DP
                INCB    r6
                CMP     DP, #001aah
                JLE     learn_table1_loop
learn_table2_check:     LB      A, off(002d2h)
                JNE     learn_table2_check_clear_ram09e_bit3
                MOVB    off(002d2h), #005h
                LB      A, #001h
                MB      C, 09eh.0
                JLT     learn_counter_store
                LB      A, 0d7h
                ADDB    A, #001h
                CMPB    A, #010h
                JLT     learn_counter_store
                LB      A, #010h
learn_counter_store:     STB     A, 0d7h
                LB      A, 0d6h
                ADDB    A, #001h
                CMPB    A, #010h
                JLT     learn_counter_store_store_ram0d6
                RB      09eh.0
                LB      A, #010h
learn_counter_store_store_ram0d6:     STB     A, 0d6h
learn_table2_check_clear_ram09e_bit3:     RB      09eh.3
                JEQ     learn_table2_check_return
                CAL     vcal_4_load_dp
learn_table2_check_return:     RT
calchecksum_loop_sub_load_x1:     MOV     X1, A
                MOV     X2, A
                MOV     DP, A
                CMP     A, X1
                JNE     calchecksum_loop_sub_return
                CMP     A, X2
                JNE     calchecksum_loop_sub_return
                CMP     A, DP
calchecksum_loop_sub_return:     RT
learn_table2_check_sub_load_dp_ind:     L       A, [DP]
                CMP     A, #0ffffh
                JNE     learn_table2_check_sub_xor_acc
                CLR     A
learn_table2_check_sub_xor_acc:     XOR     A, #0ffffh
                ST      A, 00000h[X1]
                CMP     A, 00002h[X1]
                JLT     learn_table2_check_sub_cmp_acc
                ST      A, 00002h[X1]
                RT
learn_table2_check_sub_cmp_acc:     CMP     A, 00004h[X1]
                JGT     learn_table2_check_sub_return
                ST      A, 00004h[X1]
learn_table2_check_sub_return:     RT
vcal_0:         LB      A, ACC
vcal_0_cmp_acc:     CMPCB   A, 00002h[X1]
                JGE     table_interp_bracket_found
                INC     X1
                INC     X1
                SJ      vcal_0_cmp_acc
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
                MB      C, PSWL.4
                JGE     table_interp_delta_calc_addb_acc
                SUBB    r6, A
                LB      A, r6
                RT
table_interp_delta_calc_addb_acc:     ADDB    A, r6
                STB     A, r6
                RT
vcal_2:         LB      A, ACC
                CMPCB   A, [X1]
                JLT     vcal1_bracket_check
                LCB     A, [X1]
vcal1_bracket_check:     CMPCB   A, 00002h[X1]
                JGE     vcal1_bracket_check_goto_table_interp_bracket_found
                LCB     A, 00002h[X1]
vcal1_bracket_check_goto_table_interp_bracket_found:     SJ      table_interp_bracket_found
knockretard_table_gate_sub_load_acc:     LB      A, ACC
                CMPCB   A, [X1]
                JLT     knockretard_r1_store
                LCB     A, [X1]
knockretard_r1_store:     CMPCB   A, 00002h[X1]
                JGE     knockretard_sub_result
                LCB     A, 00002h[X1]
knockretard_sub_result:     MOVB    r0, A
                J       table_interp_delta_calc
vcal_1:         LB      A, ACC
vcal_1_cmp_acc:     CMPCB   A, 00003h[X1]
                JGE     vcal_common_interp
                ADD     X1, #00003h
                SJ      vcal_1_cmp_acc
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
                MB      C, PSWL.4
                JGE     injtimer_bank_calc3_add_acc
                SUB     er3, A
                L       A, er3
                RT
injtimer_bank_calc3_add_acc:     ADD     A, er3
                ST      A, er3
                RT
idleign_table_lookup_sub_load_acc:     L       A, ACC
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
vcal_3:         LB      A, ACC
                CMPCB   A, [X1]
                JLT     vcal_3_cmp_acc
                LCB     A, [X1]
vcal_3_cmp_acc:     CMPCB   A, 00003h[X1]
                JGE     vcal_3_goto_vcal_common_interp
                LCB     A, 00003h[X1]
vcal_3_goto_vcal_common_interp:     SJ      vcal_common_interp
subtract24_clamp_byte:     SUBB    A, #018h
                JGE     subtract24_clamp_byte_load_carry_ramacc_bit7
                CLRB    A
                RT
subtract24_clamp_byte_load_carry_ramacc_bit7:     MB      C, ACCH.7
                ROLB    A
                JGE     subtract24_clamp_byte_return
                LB      A, #0ffh
subtract24_clamp_byte_return:     RT
vcal_7:         MB      C, PSWH.4
                JGE     vcal_7_xor_acc
                XOR     A, #0ffffh
                ADD     A, #00001h
                RT
vcal_7_xor_acc:     XOR     A, #086ffh
                RT
                DB  001h
vcal_6:         DB  0E2h
vcal_5:         L       A, ACC
                MB      C, ACCH.7
                JLT     vcal_5_add_acc
                ADD     A, er3
                JGE     vcal4_store
                L       A, #0ffffh
                SJ      vcal4_store
vcal_5_add_acc:     ADD     A, er3
                JLT     vcal4_store
                CLR     A
vcal4_store:     ST      A, er3
                RT
                DB  0E2h
tipin_time_finalize_sub_load_acc:     L       A, ACC
                MB      C, ACCH.7
                JLT     tipin_time_finalize_sub_load_carry_r7_bit7
                MB      C, r7.7
                JLT     signext_common_add
                ADD     A, er3
                MB      C, ACCH.7
                JGE     signext_common_add_store_er3
                L       A, #07fffh
                SJ      signext_common_add_store_er3
tipin_time_finalize_sub_load_carry_r7_bit7:     MB      C, r7.7
                JGE     signext_common_add
                ADD     A, er3
                MB      C, ACCH.7
                JLT     signext_common_add_store_er3
                L       A, #08000h
                SJ      signext_common_add_store_er3
signext_common_add:     ADD     A, er3
signext_common_add_store_er3:     ST      A, er3
                RT
vss_scale_apply_sub_mul_acc:     MUL
                MOV     er2, er1
                L       A, [DP]
                MUL
                L       A, [DP]
                SUB     A, er1
                ADD     A, er2
                ST      A, [DP]
                RT
ect_smooth_helper:     MOVB    r0, #001h
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
o2trim_add_clamp_sub_sub_acc:     SUB     A, er3
                JGE     o2trim_add_clamp_sub_mul_acc
                XOR     A, #0ffffh
                INC     ACC
o2trim_add_clamp_sub_mul_acc:     MUL
                JGE     o2trim_add_clamp_sub_add_er2
                SUB     er2, A
                L       A, er1
                SBC     er3, A
                RT
o2trim_add_clamp_sub_add_er2:     ADD     er2, A
                L       A, er1
                ; invalid opcode encountered @4510; halting
                DB  047h,091h,001h
scale_div32_loop_sub_clear_pswh_bit0:     RB      PSWH.0
                LB      A, P3
                ANDB    A, #0f8h
                ORB     A, r0
                XORB    A, #0ffh
                ANDB    A, #00fh
                STB     A, P3
                SB      PSWH.0
                RT
scale_result_common_sub_extnd_acc:     EXTND
                ADD     DP, A
                LC      A, [DP]
                SWAP
                ST      A, er3
                J       scale_result_common_sub_load_er0
scale_result_common_sub_clear_acc:     CLR     A
                LB      A, r7
                SUBB    A, r6
                MB      PSWL.4, C
                JGE     scale_result_common_sub_mul_acc
                STB     A, r7
                CLRB    A
                SUBB    A, r7
scale_result_common_sub_mul_acc:     MUL
                LB      A, r2
                RB      PSWL.4
                JEQ     scale_result_common_sub_addb_acc
                SUBB    r6, A
                LB      A, r6
                RT
scale_result_common_sub_addb_acc:     ADDB    A, r6
                STB     A, r6
                RT
tipin_gate_common_sub_load_r0:     MOVB    r0, #00ah
                MULB
                ADD     DP, A
                LB      A, r1
                EXTND
                ADD     DP, A
                LC      A, [DP]
                ST      A, er3
                ADD     DP, #0000ah
                MOV     er0, X2
                CAL     scale_result_common_sub_clear_acc
                ; warning: had to flip DD
                STB     A, r4
                LC      A, [DP]
                MOV     er3, A
                MOV     er0, X2
                CAL     scale_result_common_sub_clear_acc
                MOVB    r7, r4
scale_result_common_sub_load_er0:     MOV     er0, X1
                CAL     scale_result_common_sub_clear_acc
                RT
dtc_active_confirm_sub_clear_acc:     CLR     A
                LB      A, r6
                SUBB    A, #001h
                STB     A, r2
                MOVB    r0, #008h
                DIVB
                MOV     X1, A
                LB      A, r1
                SBR     00110h[X1]
                SBR     00210h[X1]
                SBR     00330h[X1]
                CLR     A
                LB      A, r2
                L       A, ACC
                SLL     A
                ADD     A, #dtc_active_confirm_tbl_2
                LC      A, [ACC]
                CLR     er0
                J       [ACC]
dtc_step_4594:  CMPB 0DAh, #01Ah
                JLT dtc_step_459B
                INCB r0
dtc_step_459B:  J dtc_step_4641
dtc_step_459E:  MOV DP, #003E4h
                LB A, [DP]
                SLLB A
                JGE dtc_step_45A6
                INCB r0
dtc_step_45A6:  J dtc_step_4641
dtc_step_45A9:  CMPB r7, #021h
                JEQ dtc_step_45AF
                INCB r0
dtc_step_45AF:  J dtc_step_4641
dtc_step_45B2:  MOV DP, #003DAh
                LB A, [DP]
                SLLB A
                JGE dtc_step_45BA
                INCB r0
dtc_step_45BA:  J dtc_step_4641
dtc_step_45BD:  MOV DP, #crank_sync_exit_jump_store_carry_ram12e_bit3
                LB A, [DP]
                SLLB A
                JGE dtc_step_45C5
                INCB r0
dtc_step_45C5:  SJ dtc_step_4641
dtc_step_45C7:  LB A, r7
                CMPB A, #022h
                JEQ dtc_step_45D2
                INCB r0
                CMPB A, #02Ah
                JEQ dtc_step_45D2
                INCB r0
dtc_step_45D2:  SJ dtc_step_4641
dtc_step_45D4:  CMPB r7, #023h
                JEQ dtc_step_45DA
                INCB r0
dtc_step_45DA:  SJ dtc_step_4641
dtc_step_45DC:  MOV DP, #003D2h
                LB A, [DP]
                SLLB A
                JGE dtc_step_45E4
                INCB r0
dtc_step_45E4:  SJ dtc_step_4641
dtc_step_45E6:  CMPB r7, #00Ah
                JNE dtc_step_45EF
                MOVB r0, #002h
                SJ dtc_step_45F8
dtc_step_45EF:  MOV DP, #003E1h
                CMPB [DP], #080h
                JLT dtc_step_45F8
                INCB r0
dtc_step_45F8:  SJ dtc_step_4641
dtc_step_45FA:  MOV DP, #003D3h
                LB A, [DP]
                SLLB A
                JGE dtc_step_4602
                INCB r0
dtc_step_4602:  SJ dtc_step_4641
dtc_step_4604:  MOV DP, #003D8h
                LB A, [DP]
                SLLB A
                JGE dtc_step_460C
                INCB r0
dtc_step_460C:  SJ dtc_step_4641
dtc_step_460E:  CLRB A
                SJ dtc_step_4642
dtc_step_4611:  LB A, #023h
                SJ dtc_step_4642
dtc_step_4615:  MOV DP, #003E3h
                LB A, [DP]
                SLLB A
                JGE dtc_step_461D
                INCB r0
dtc_step_461D:  LB A, #024h
                SJ dtc_step_4642
dtc_step_4621:  LB A, #029h
                SJ dtc_step_4642
dtc_step_4625:  CMP -32[USP], #08000h
                JLT dtc_step_462D
                INCB r0
dtc_step_462D:  LB A, #02Bh
                SJ dtc_step_4642
dtc_step_4631:  CMPB r7, #015h
                JNE dtc_step_4637
                INCB r0
dtc_step_4637:  SJ dtc_step_4641
dtc_step_4639:  CMPB r7, #016h
                JNE dtc_step_463F
                INCB r0
dtc_step_463F:  SJ dtc_step_4641
dtc_step_4641:  LB A, r6
dtc_step_4642:  STB A, r1
                EXTND
                SRL A
                MOV X1, A
                LB A, r0
                JGE dtc_step_464B
                ADDB A, #004h
dtc_step_464B:  SBR 00348h[X1]
dtc_step_464F:  RT
crank_tooth_count_store_sub_clear_ram0a0_bit6:     RB      0a0h.6
                CLR     A
                ST      A, IGNA
                RB      0a0h.5
                L       A, #00001h
                ST      A, IGNB
                RT
crankfuel_clamp_max_sub_cmp_acc:     CMP     A, 0004ch[X1]
                JGE     crankfuel_clamp_max_sub_store_tbl_x1
                CMP     0004ch[X1], #0ffffh
                JNE     crankfuel_clamp_max_sub_return
crankfuel_clamp_max_sub_store_tbl_x1:     ST      A, 0004ch[X1]
crankfuel_clamp_max_sub_return:     RT
tps_interp_exact_match_sub_rom_load_00026h_dp:     LC      A, 00026h[DP]
                L       A, ACC
                MOV     er0, 0aeh
                CMP     er0, A
                JGE     tps_interp_exact_match_sub_store_carry_pswl_bit5
                ST      A, er0
tps_interp_exact_match_sub_store_carry_pswl_bit5:     MB      PSWL.5, C
                LC      A, [DP]
                SUB     A, #00001h
                CMP     A, er0
                JGE     tps_interp_exact_match_sub_store_carry_pswl_bit4
                ST      A, er0
tps_interp_exact_match_sub_store_carry_pswl_bit4:     MB      PSWL.4, C
                CLR     A
                LB      A, #012h
                CMPB    A, r6
                JLT     tps_interp_exact_match_sub_store_r6
                LB      A, r6
tps_interp_exact_match_sub_store_r6:     STB     A, r6
                ADDB    A, #001h
                SLLB    A
                ADD     DP, A
                L       A, er0
tps_interp_exact_match_sub_dec_dp:     DEC     DP
                DEC     DP
                DECB    r6
                CMPC    A, [DP]
                JGE     tps_interp_exact_match_sub_dec_dp
tps_interp_exact_match_sub_inc_dp:     INC     DP
                INC     DP
                INCB    r6
                CMPC    A, [DP]
                JLT     tps_interp_exact_match_sub_inc_dp
                LC      A, [DP]
                SUB     er0, A
                ST      A, er2
                LC      A, 0fffeh[DP]
                SUB     A, er2
                ST      A, er2
                CLR     A
                DIV
                RT
tps_interp_exact_match_sub_clear_acc:     CLR     A
                LB      A, #008h
                CMPB    A, r6
                JLT     tps_interp_exact_match_sub_store_r6_2
                LB      A, r6
tps_interp_exact_match_sub_store_r6_2:     STB     A, r6
                ADDB    A, #001h
                MOV     DP, #tbl_map_axis_mbar10
                ADD     DP, A
                LB      A, r0
                ADDB    A, #001h
                MB      PSWL.4, C
                SBCB    A, #001h
tps_interp_exact_match_sub_dec_dp_2:     DEC     DP
                DECB    r6
                CMPCB   A, [DP]
                JLT     tps_interp_exact_match_sub_dec_dp_2
tps_interp_exact_match_sub_inc_dp_2:     INC     DP
                INCB    r6
                CMPCB   A, [DP]
                JGE     tps_interp_exact_match_sub_inc_dp_2
                LCB     A, [DP]
                STB     A, r4
                DEC     DP
                LCB     A, [DP]
                SUBB    r4, A
                CLRB    r5
                CMPB    r6, #008h
                JLT     tps_interp_exact_match_sub_subb_r0
                INC     er2
tps_interp_exact_match_sub_subb_r0:     SUBB    r0, A
                CLRB    r1
                CLR     A
                DIV
                RT
scale_result_common_sub_extnd_acc_2:     EXTND
                JEQ     scale_result_common_sub_add_er3
                OR      A, #0ff00h
scale_result_common_sub_add_er3:     ADD     er3, A
                RT
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
to_set_pswl4_flag_b_sub_clear_acc:     CLR     A
                LC      A, rom_5247
                SB      off(0011bh).0
                JEQ     to_set_pswl4_flag_b_sub_goto_o2_trim_dp300_read
                JBR     off(0012dh).1, to_set_pswl4_flag_b_sub_if_ram117_bit3_set
                JBS     off(00115h).3, to_set_pswl4_flag_b_sub_if_ram117_bit3_set
to_set_pswl4_flag_b_sub_goto_o2_trim_dp300_read:     J       o2_trim_dp300_read
to_set_pswl4_flag_b_sub_if_ram117_bit3_set:     JBS     off(00117h).3, to_set_pswl4_flag_b_sub_load_er1
                JBR     off(00117h).2, to_set_pswl4_flag_b_sub_load_er1
                J       to_set_pswl4_flag_b_sub_store_ram170_2
to_set_pswl4_flag_b_sub_load_er1:     MOV     er1, off(00160h)
                JBS     off(0012fh).2, to_set_pswl4_flag_b_sub_store_ram170
                J       o2_trim_dp300_read_rom_load_ram5247
to_set_pswl4_flag_b_sub_store_ram170:     ST      A, off(00170h)
                CAL     to_set_pswl4_flag_b_sub_call_4880
                JBS     off(00117h).0, to_set_pswl4_flag_b_sub_sll_x1
                JBS     off(0012fh).3, to_set_pswl4_flag_b_sub_sll_x1
                LB      A, off(001f0h)
                JNE     to_set_pswl4_flag_b_sub_sll_x1
                MOVB    off(001f0h), #014h
                L       A, #0045ah
                JBS     off(00130h).4, o2trim_add_clamp
                MOVB    r0, #080h
                MOV     er2, #006f7h
                LB      A, #03fh
                JBR     off(00120h).0, to_set_pswl4_flag_b_sub_goto_6d90
                MOVB    r0, #07dh
                MOV     er2, #00767h
                LB      A, #046h
to_set_pswl4_flag_b_sub_goto_6d90:     J       to_set_pswl4_flag_b_sub_if_ram11f_bit3_clr
                DB  000h
to_set_pswl4_flag_b_sub_load_er2:     L       A, er2
                J       to_set_pswl4_flag_b_sub_cmp_r0
                DW  00acfh
to_set_pswl4_flag_b_sub_load_ram166:     L       A, off(00166h)
                CMPB    off(00178h), #077h
                JGE     o2trim_add_clamp
                L       A, off(00164h)
o2trim_add_clamp:     ADD     er1, A
                JGE     o2trim_add_clamp_call_48c3
                MOV     er1, #0ffffh
                SJ      o2trim_add_clamp_call_48c3
to_set_pswl4_flag_b_sub_sll_x1:     SLL     X1
                L       A, #rom_5249
                JBR     off(00120h).0, to_set_pswl4_flag_b_sub_add_x1
                L       A, #rom_5253
to_set_pswl4_flag_b_sub_add_x1:     ADD     X1, A
                LC      A, [X1]
                JBR     off(0012fh).3, o2trim_add_clamp
                SUB     er1, A
                JGE     o2trim_add_clamp_call_48c3
                CLR     er1
o2trim_add_clamp_call_48c3:     CAL     o2trim_add_clamp_sub_load_imm_2
                JBS     off(0011eh).1, o2trim_add_clamp_goto_487f
                JBS     off(0011bh).7, o2trim_add_clamp_goto_487f
                CMPB    0d8h, #01ah
                JLT     o2trim_add_clamp_goto_487f
                L       A, #00040h
                MOV     X1, #00306h
                JBR     off(00117h).0, o2trim_add_clamp_cmp_ram0d9
                L       A, #00a00h
                MOV     X1, #00302h
o2trim_add_clamp_cmp_ram0d9:     CMPB    0d9h, #02eh
                JLT     o2trim_add_clamp_store_er0
                L       A, #00001h
o2trim_add_clamp_store_er0:     ST      A, er0
                MOV     er2, 00000h[X1]
                MOV     er3, 00002h[X1]
                L       A, er1
                MOV     DP, A
                CAL     o2trim_add_clamp_sub_sub_acc
                CAL     o2trim_add_clamp_sub_load_imm
                L       A, er2
                ST      A, 00000h[X1]
                L       A, er3
                ST      A, 00002h[X1]
                MOV     er1, DP
o2trim_add_clamp_goto_487f:     J       o2trim_add_clamp_return
to_set_pswl4_flag_b_sub_store_ram170_2:     ST      A, off(00170h)
                JBR     off(00117h).1, o2_trim_dp304_calc
                MOV     DP, #0030ch
                MOV     er1, [DP]
                SJ      o2_trim_dp300_read_rom_load_ram5247
o2_trim_dp300_read:     ST      A, off(00170h)
                MOV     DP, #00304h
                MOV     er1, [DP]
                JBS     off(00117h).0, o2_trim_dp300_read_rom_load_ram5247
o2_trim_dp304_calc:     MOV     DP, #00308h
                MOV     er0, [DP]
                L       A, #08000h
                JBS     off(00120h).0, o2_trim_dp304_calc_mul_acc
                L       A, #08000h
o2_trim_dp304_calc_mul_acc:     MUL
                SLL     A
                ROL     er1
                JGE     o2_trim_dp300_read_rom_load_ram5247
                MOV     er1, #0ffffh
o2_trim_dp300_read_rom_load_ram5247:     LC      A, rom_5247
                MOV     DP, #00170h
                JBR     off(0012fh).3, o2_trim_dp300_read_decb_dp_ind
                INC     DP
                SWAP
o2_trim_dp300_read_decb_dp_ind:     DECB    [DP]
                JNE     o2_trim_dp300_read_call_48c3
                LB      A, ACC
                STB     A, [DP]
                CAL     o2_trim_dp300_read_sub_clear_x1
                L       A, #rom_525d
                JBR     off(00120h).0, o2_trim_dp300_read_add_x1
                L       A, #rom_5262
o2_trim_dp300_read_add_x1:     ADD     X1, A
                CLR     A
                LCB     A, [X1]
                JBS     off(0012fh).3, o2_trim_dp300_read_sub_er1
                ADD     er1, A
                SJ      o2_trim_dp300_read_if_ram11e_bit1_set
o2_trim_dp300_read_sub_er1:     SUB     er1, A
o2_trim_dp300_read_if_ram11e_bit1_set:     JBS     off(0011eh).1, o2_trim_dp300_read_call_48c3
                CMPB    0d8h, #01ah
                JLT     o2_trim_dp300_read_call_48c3
                JBS     off(00117h).0, o2_trim_dp300_read_call_48c3
                LB      A, off(001e1h)
                JEQ     o2_trim_dp300_read_call_48c3
                MOV     X1, #0030ah
                L       A, #00020h
                CMPB    0d9h, #02eh
                JLT     o2_trim_dp300_read_store_er0
                L       A, #00001h
o2_trim_dp300_read_store_er0:     ST      A, er0
                MOV     er2, 00000h[X1]
                MOV     er3, 00002h[X1]
                L       A, er1
                MOV     DP, A
                CAL     o2trim_add_clamp_sub_sub_acc
                CAL     o2trim_add_clamp_sub_load_imm
                L       A, er2
                ST      A, 00000h[X1]
                L       A, er3
                ST      A, 00002h[X1]
                MOV     er1, DP
o2_trim_dp300_read_call_48c3:     CAL     o2trim_add_clamp_sub_load_imm_2
o2trim_add_clamp_return:     RT
o2_trim_dp300_read_sub_clear_x1:     CLR     X1
                JBR     off(00117h).0, o2_trim_dp300_read_sub_load_r5
                LB      A, off(00196h)
                JEQ     o2_trim_dp300_read_sub_add_x1
                JBR     off(0012fh).2, o2_trim_dp300_read_sub_load_ram179
                DECB    off(00196h)
                JNE     o2_trim_dp300_read_sub_load_ram179
o2_trim_dp300_read_sub_add_x1:     ADD     X1, #00004h
                SJ      o2_trim_dp300_read_sub_return
o2_trim_dp300_read_sub_load_r5:     MOVB    r5, #00ah
                LB      A, (00295h-00280h)[USP]
                CMPB    A, off(00179h)
                JLT     o2_trim_dp300_read_sub_load_ram196
                CLRB    r5
o2_trim_dp300_read_sub_load_ram196:     MOVB    off(00196h), r5
o2_trim_dp300_read_sub_load_ram179:     LB      A, off(00179h)
                JBS     off(00130h).4, o2_trim_dp300_read_sub_return
                INC     X1
                CMPB    A, #0a0h
                JGE     o2_trim_dp300_read_sub_return
                INC     X1
                CMPB    A, #040h
                JGE     o2_trim_dp300_read_sub_return
                INC     X1
o2_trim_dp300_read_sub_return:     RT
o2trim_add_clamp_sub_load_imm:     L       A, #09999h
                CMP     A, er3
                JLT     o2trim_add_clamp_sub_store_er3
                L       A, #o2trim_add_clamp_tbl_2
                CMP     A, er3
                JLE     o2trim_add_clamp_sub_return
o2trim_add_clamp_sub_store_er3:     ST      A, er3
o2trim_add_clamp_sub_return:     RT
o2trim_add_clamp_sub_load_imm_2:     L       A, #0bc44h
                CMP     A, er1
                JGE     o2trim_add_clamp_sub_load_imm_3
                ST      A, er1
o2trim_add_clamp_sub_load_imm_3:     L       A, #o2trim_add_clamp_tbl
                CMP     A, er1
                JLE     o2trim_add_clamp_sub_return_2
                ST      A, er1
o2trim_add_clamp_sub_return_2:     RT
vtec_state_store_sub_clear_acch:     CLRB    ACCH
                ADD     DP, A
                CAL     vtec_state_store_sub_rom_load_dp_ind
                STB     A, r3
                INC     DP
                CAL     vtec_state_store_sub_rom_load_dp_ind
                ; warning: had to flip DD
                XCHG    A, er3
                MOV     er0, X1
                SUB     A, er3
                MB      PSWL.4, C
                JGE     vtec_state_store_sub_mul_acc
                VCAL    7
vtec_state_store_sub_mul_acc:     MUL
                L       A, er1
                RB      PSWL.4
                JNE     vtec_state_store_sub_sub_er3
                ADD     A, er3
                SJ      map_result_postscale
vtec_state_store_sub_sub_er3:     SUB     er3, A
                L       A, er3
map_result_postscale:     MOVB    r0, off(00184h)
                MOVB    r1, #001h
                CMPB    r0, #080h
                JGE     mul_scale_rotate
                INCB    r1
mul_scale_rotate:     MUL
                SRL     er1
                ROR     A
                MOVB    r0, ACCH
                MOVB    r1, r2
                L       A, er0
                ST      A, off(0013eh)
                RT
vtec_state_store_sub_rom_load_dp_ind:     LCB     A, [DP]
                MOVB    r0, off(00135h)
                MULB
                L       A, ACC
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ST      A, er1
                CLRB    A
                LCB     A, 00014h[DP]
                SUBB    A, #080h
                EXTND
                SLL     A
                ADD     er1, A
                RB      ACCH.7
                JEQ     vtec_state_store_sub_load_er1
                JLT     vtec_state_store_sub_load_er1
                CLR     er1
vtec_state_store_sub_load_er1:     L       A, er1
                RT
accelenrich_clear_pulse_check_sub_load_x1:     MOV     X1, #rom_532e
                LB      A, (002a4h-00280h)[USP]
                CMPB    A, #002h
                JLE     accelenrich_clear_pulse_check_sub_cmp_ram179
                ADD     X1, #00006h
accelenrich_clear_pulse_check_sub_cmp_ram179:     CMPB    off(00179h), #08ah
                JLT     accelenrich_clear_pulse_check_sub_load_ram0e9
                ADD     X1, #0000ch
accelenrich_clear_pulse_check_sub_load_ram0e9:     LB      A, 0e9h
                VCAL    3
                LB      A, ACC
                RT
accelenrich_base_calc:     CLRB    A
                JBR     off(00117h).1, accelenrich_base_adjust
                CMPB    0dfh, #005h
                JLT     accelenrich_rpm_tier1_store_ram18e
accelenrich_base_adjust:     ADDB    A, #006h
                JBR     off(0011ah).3, accelenrich_rpm_tier1
                ADDB    A, #006h
accelenrich_rpm_tier1:     CMPB    off(00179h), #066h
                JLT     accelenrich_rpm_tier1_store_ram18e
                ADDB    A, #00ch
accelenrich_rpm_tier1_store_ram18e:     STB     A, off(0018eh)
accelenrich_rpm_tier1_clear_acch:     CLRB    ACCH
                MOV     X1, A
                ADD     X1, #rom_5310
                LB      A, 0e9h
                VCAL    3
                RT
vemapscalar_gate_sub_sub_acc:     SUB     A, #00043h
                JLT     vemapscalar_gate_sub_rom_load_tbl_x1
                CMPC    A, [X1]
                JGE     vemapscalar_gate_sub_return
vemapscalar_gate_sub_rom_load_tbl_x1:     LC      A, [X1]
vemapscalar_gate_sub_return:     RT
add24_clamp_neg1:     ADD     A, #00001h
                JGE     add24_clamp_neg1_store_er3
                L       A, #0ffffh
add24_clamp_neg1_store_er3:     ST      A, er3
                CLR     er1
                L       A, 0ach
                SUB     A, #01140h
                JLT     add24_clamp_neg1_rom_load_tbl_x1
                ST      A, er0
                LC      A, 00002h[X1]
                MUL
add24_clamp_neg1_rom_load_tbl_x1:     LC      A, [X1]
                ADD     A, er1
                JGE     add24_clamp_neg1_cmp_acc
                L       A, #0ffffh
add24_clamp_neg1_cmp_acc:     CMP     A, er3
                JLT     add24_clamp_neg1_return
                L       A, er3
add24_clamp_neg1_return:     RT
learn_table2_check_sub_clear_pswh_bit0:     RB      PSWH.0
                LB      A, [DP]
                JEQ     learn_table2_check_sub_set_pswh_bit0
                DECB    [DP]
learn_table2_check_sub_set_pswh_bit0:     SB      PSWH.0
                INC     DP
                DECB    r0
                JNE     learn_table2_check_sub_clear_pswh_bit0
                RT
learn_table2_check_sub_load_imm:     LB      A, #03ch
                STB     A, WDT
                SWAPB
                STB     A, WDT
                MB      C, 09eh.0
                JLT     learn_table2_check_sub_return_2
                XORB    P2A, #002h
learn_table2_check_sub_return_2:     RT
vss_clamp_common_sub_load_dp:     MOV     DP, #08000h
                RB      PSWH.0
                LB      A, [DP]
                XORB    A, #0c2h
                STB     A, off(00224h)
                STB     A, (00124h-00180h)[USP]
                SB      PSWH.0
                MOV     DP, #01000h
                RB      PSWH.0
                LB      A, [DP]
                XORB    A, #030h
                STB     A, off(00227h)
                STB     A, (00125h-00180h)[USP]
                SB      PSWH.0
                RB      PSWH.0
                MB      C, P4.5
                MB      off(00214h).0, C
                MB      C, P4.6
                XORB    PSWH, #080h
                MB      off(0022ch).2, C
                SB      PSWH.0
                RT
idle_init_start_sub_cmp_ram0d7:     CMPB    0d7h, #000h
                JEQ     idle_init_start_sub_store_ram0d4
                DECB    0d7h
                JEQ     idle_init_start_sub_store_ram0d4
                RT
idle_init_start_sub_store_ram0d4:     STB     A, 0d4h
                CLRB    0d6h
                J       fault_retry_check
percyl_counter_gate_sub_cmp_ram0d7:     CMPB    0d7h, #000h
                JEQ     percyl_counter_gate_sub_store_ram0d4
                DECB    0d7h
                JEQ     percyl_counter_gate_sub_store_ram0d4
                RT
percyl_counter_gate_sub_store_ram0d4:     STB     A, 0d4h
                J       fault_retry_check_nop_acc
idle_helper2:     MUL
                L       A, er1
                SJ      mul_then_clamp_x1x2_2_load_carry_pswl_bit4
mul_then_clamp_x1x2_2:     MUL
                CMPB    r2, #000h
                JEQ     mul_then_clamp_x1x2_2_load_carry_pswl_bit4
                L       A, #0ffffh
mul_then_clamp_x1x2_2_load_carry_pswl_bit4:     MB      C, PSWL.4
                JGE     mul_then_clamp_x1x2_2_xchg_acc
                ADD     A, er3
                JLT     mul_then_clamp_x1x2_2_load_x2
mul_then_clamp_x1x2_2_cmp_acc:     CMP     A, X1
                JLT     idle_pi_clamp_setcarry
                CMP     X2, A
                JGE     idle_pi_clamp_setcarry_store_er3
mul_then_clamp_x1x2_2_load_x2:     L       A, X2
                SJ      idle_pi_clamp_setcarry_store_er3
mul_then_clamp_x1x2_2_xchg_acc:     XCHG    A, er3
                SUB     A, er3
                JGE     mul_then_clamp_x1x2_2_cmp_acc
idle_pi_clamp_setcarry:     L       A, X1
idle_pi_clamp_setcarry_store_er3:     ST      A, er3
                RT
ect_fault_range_check_sub_load_dp:     MOV     DP, #003a5h
                ADDB    A, #005h
                JGE     ect_fault_range_check_sub_if_ram216_bit0_set
                LB      A, #0ffh
ect_fault_range_check_sub_if_ram216_bit0_set:     JBS     off(00216h).0, ect_fault_range_check_sub_load_r0
                JBR     off(00233h).3, ect_fault_range_check_sub_load_r0
                CMPB    A, [DP]
                JGE     ect_fault_range_check_sub_return
ect_fault_range_check_sub_load_r0:     MOVB    r0, #058h
                CMPB    A, r0
                JGE     ect_fault_range_check_sub_store_dp_ind
                LB      A, r0
ect_fault_range_check_sub_store_dp_ind:     STB     A, [DP]
ect_fault_range_check_sub_return:     RT
idle_temp_hyst3_sub_load_dp:     MOV     DP, #0030eh
                CLR     A
                LC      A, rom_5558
                JBS     off(00220h).0, idle_temp_hyst3_sub_store_dp_ind
                LC      A, rom_555a
idle_temp_hyst3_sub_store_dp_ind:     ST      A, [DP]
                RT
vss_clamp_common_sub_load_dp_2:     MOV     DP, #08000h
vss_clamp_common_sub_load_dp_ind:     LB      A, [DP]
                ROLB    A
                ROLB    off(002bbh)
                ROLB    A
                ROLB    off(002bbh)
                RT
                DB  090h,09Dh,0F2h,07Fh,001h
div_scale_mul_final_sub_subb_acc:     SUBB    A, #074h
div_scale_mul_final_sub_if_le_goto_4a8d:     JLE     div_scale_mul_final_sub_addb_acc
                SUBB    A, #004h
                JGE     div_scale_mul_final_sub_addb_acc_2
                CLRB    A
div_scale_mul_final_sub_addb_acc:     ADDB    A, #080h
                SJ      div_scale_mul_final_sub_return
div_scale_mul_final_sub_addb_acc_2:     ADDB    A, #080h
                JGE     div_scale_mul_final_sub_return
                LB      A, #0ffh
div_scale_mul_final_sub_return:     RT
vss_clamp_common_sub_clear_pswh_bit0:     RB      PSWH.0
                RB      ADSCAN.5
                MB      C, PSWH.6
                RB      09fh.4
                JGE     vss_clamp_common_sub_set_pswh_bit0
                JNE     vss_clamp_common_sub_set_pswh_bit0
                CAL     vss_clamp_common_sub_set_pswh_bit0_2
                NOP
                NOP
                SJ      vss_clamp_common_sub_return
vss_clamp_common_sub_set_pswh_bit0:     SB      PSWH.0
                LB      A, 0bbh
                EXTND
                MOV     X1, A
                LB      A, ADCR0H
                STB     A, 003d0h[X1]
                LB      A, ADCR1H
                STB     A, 003d8h[X1]
                LB      A, 0bbh
                ADDB    A, #001h
                ANDB    A, #007h
                STB     A, 0bbh
                STB     A, r0
                CAL     scale_div32_loop_sub_clear_pswh_bit0
vss_clamp_common_sub_return:     RT
calchecksum_loop_sub_load_dp:     MOV     DP, #0e000h
                MOVB    [DP], #090h
                MOV     DP, #0a000h
                LB      A, off(00225h)
                XORB    A, #0ffh
                STB     A, [DP]
                MOV     DP, #0c000h
                RB      PSWH.0
                LB      A, off(00226h)
                XORB    A, #024h
                STB     A, [DP]
                SB      PSWH.0
                SB      off(00232h).7
                RT
cfgvariant_checksum_calc:     MOV     DP, #00330h
                CLR     er0
cfgvariant_checksum_loop:     LB      A, r0
                ADDB    A, [DP]
                STB     A, r0
                LB      A, r1
                XORB    A, [DP]
                STB     A, r1
                INC     DP
                CMP     DP, #00334h
                JNE     cfgvariant_checksum_loop
                L       A, er0
                ST      A, [DP]
cfgvariant_checksum_loop_load_dp:     MOV     DP, #00338h
                CLR     er0
cfgvariant_checksum_loop_load_r0:     LB      A, r0
                ADDB    A, [DP]
                STB     A, r0
                LB      A, r1
                XORB    A, [DP]
                STB     A, r1
                INC     DP
                CMP     DP, #0035dh
                JLE     cfgvariant_checksum_loop_load_r0
                MOV     DP, #00362h
                L       A, er0
                RT
dtc_active_confirm_sub_load_dp:     MOV     DP, #00338h
                LB      A, [DP]
                JNE     dtc_active_confirm_sub_return
                LB      A, r1
                JEQ     dtc_active_confirm_sub_return
                MB      C, off(0021bh).0
                MB      ACC.7, C
                STB     A, [DP]
                INC     DP
                LB      A, 0dfh
                STB     A, [DP]
                INC     DP
                L       A, 0aeh
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                MOV     X1, #003dah
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003d2h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003e4h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003d3h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003e5h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                LB      A, 0dbh
                STB     A, [DP]
                INC     DP
                MOV     X1, #00382h
                L       A, 00000h[X1]
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                LB      A, 0dah
                STB     A, [DP]
                INC     DP
                LB      A, (0ffe0h-0ffffh)[USP]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003e2h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003e1h
                LB      A, 00000h[X1]
                STB     A, [DP]
dtc_active_confirm_sub_return:     RT
vcal_4_sub_pushs_lrb:     PUSHS   LRB
                MOV     LRB, #00076h
                RB      off(003bch).2
                JEQ     vcal_4_sub_pops_lrb
                LB      A, r1
                CMPB    A, #020h
                JNE     vcal_4_sub_cmp_acc
                MOV     off(003c0h), 0aeh
                CAL     vcal_4_sub_clear_acc_2
                NOP
                MOVB    off(003bah), r3
                LB      A, r4
                ADDB    A, #003h
                STB     A, r2
                SJ      vcal_4_sub_set_ram3bc_bit0
vcal_4_sub_cmp_acc:     CMPB    A, #030h
                JLT     vcal_4_sub_cmp_acc_2
                CMPB    A, #036h
                JGT     vcal_4_sub_cmp_acc_2
                MOVB    r2, #003h
                CMPB    A, #030h
                JEQ     vcal_4_sub_clear_ram0f8
                MOV     DP, #00124h
                MB      C, [DP].2
                JGE     vcal_4_sub_clear_ram0f8
                LB      A, off(003b8h)
                JEQ     vcal_4_sub_cmp_r1
                CMPB    r1, off(003b9h)
                JEQ     vcal_4_sub_load_r1
                SJ      vcal_4_sub_load_ram3b8
vcal_4_sub_cmp_r1:     CMPB    r1, off(003b9h)
                JNE     vcal_4_sub_clear_ram0f8
vcal_4_sub_load_r1:     LB      A, r1
                STB     A, 0f8h
vcal_4_sub_load_ram3b8:     MOVB    off(003b8h), #028h
                SJ      vcal_4_sub_set_ram3bc_bit0
vcal_4_sub_clear_ram0f8:     CLRB    0f8h
                CLRB    off(003b8h)
                SJ      vcal_4_sub_set_ram3bc_bit0
vcal_4_sub_cmp_acc_2:     CMPB    A, #021h
                JNE     vcal_4_sub_pops_lrb
                MOVB    r2, #003h
                JBR     off(003b3h).0, vcal_4_sub_if_ram3b3_bit1_clr
                CAL     vcal_4_sub_load_usp_2
vcal_4_sub_if_ram3b3_bit1_clr:     JBR     off(003b3h).1, vcal_4_sub_set_ram3bc_bit0
                CAL     vcal_4_sub_load_usp
vcal_4_sub_set_ram3bc_bit0:     SB      off(003bch).0
                MOVB    r5, #002h
                LB      A, r1
                ANDB    A, #01fh
                STB     A, r6
                STB     A, STBUF
vcal_4_sub_pops_lrb:     POPS    LRB
                RT
int_serial_sub_cmp_acc:     CMPB    A, #07fh
                JGT     int_serial_sub_load_imm
                CLRB    ACCH
                MOV     X1, A
                SLLB    A
                LC      A, int_serial_tbl[ACC]
                MOV     DP, A
                LCB     A, int_serial_tbl_2[X1]
                CMPB    A, #000h
                JNE     int_serial_sub_cmp_acc_2
                J       [DP]
int_serial_sub_cmp_acc_2:     CMPB    A, #001h
                JNE     int_serial_sub_cmp_acc_3
                LB      A, [DP]
                RT
int_serial_sub_cmp_acc_3:     CMPB    A, #002h
                JNE     int_serial_sub_cmp_acc_4
                CLRB    A
                LCB     A, [DP]
                RT
int_serial_sub_cmp_acc_4:     CMPB    A, #0ffh
                JNE     int_serial_sub_load_imm
                LB      A, #000h
                RT
int_serial_sub_load_imm:     LB      A, #0ffh
                RT
serial_cmd_4C25:MOV DP, #00220h
                LB A, [DP]
                ANDB A, #051h
                RT
serial_cmd_4C2C:MOV DP, #0023Ch
                L A, [DP]
                JEQ serial_cmd_4C38
                DEC 006h
                CAL serial_cmd_4D29
serial_cmd_4C38:LB A, 006h
                RT
serial_cmd_4C3B:L A, off(00Eh)
                CAL serial_cmd_4D29
                LB A, 006h
                RT
serial_cmd_4C43:MOV DP, #002B4h
                LB A, [DP]
                CAL vcal_7
                RT
serial_cmd_4C4B:CLR A
                LB A, off(0A9h)
                SLLB A
                SLLB A
                LCB A, clamp_result_store_tbl_2[006h]
                RT
serial_cmd_4C56:MOV DP, #0021Fh
                LB A, [DP]
                ANDB A, #02Fh
                RT
vcal_4_sub_load_usp:     MOV     USP, #00280h
                CLRB    off(00300h)
                L       A, #08000h
                ST      A, off(00304h)
                ST      A, off(00308h)
                ST      A, off(0030ch)
                MB      C, (00220h-00280h)[USP].0
                LC      A, rom_5558
                JLT     vcal_4_sub_store_ram30e
                LC      A, rom_555a
vcal_4_sub_store_ram30e:     ST      A, off(0030eh)
                MOVB    off(0032fh), #078h
                CLRB    off(0032eh)
                MOVB    off(00300h), #05ah
                MOVB    (002f5h-00280h)[USP], #006h
                MOVB    (0028bh-00280h)[USP], #0fah
                MOVB    (00293h-00280h)[USP], #03dh
                LB      A, #01eh
                STB     A, (002ebh-00280h)[USP]
                MOV     USP, #00180h
                RT
vcal_4_sub_load_usp_2:     MOV     USP, #00280h
                CLR     A
                MOV     DP, #00110h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                ST      A, (00210h-00280h)[USP]
                ST      A, (00212h-00280h)[USP]
                ST      A, 098h
                ST      A, 09ah
                ST      A, 09ch
                CLRB    0f1h
                CLRB    (002bfh-00280h)[USP]
                ANDB    (00233h-00280h)[USP], #01fh
                ANDB    (00215h-00280h)[USP], #0bfh
                ANDB    (00218h-00280h)[USP], #0bfh
                CLRB    (002c0h-00280h)[USP]
                MOVB    (002c6h-00280h)[USP], #010h
                RB      09eh.0
                JEQ     vcal_4_sub_load_ram0d6
                RB      (00232h-00280h)[USP].7
vcal_4_sub_load_ram0d6:     MOVB    0d6h, #010h
                MOVB    0d7h, #010h
                ORB     off(00336h), #0c0h
                CAL     vcal_4_sub_clear_acc
                ANDB    off(00336h), #03fh
                CAL     clamp_result_store_sub_load_dp
                MOV     USP, #00180h
                ANDB    (00127h-00180h)[USP], #01fh
                RT
vcal_4_sub_clear_acc:     CLR     A
                MOV     DP, #00330h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOV     X1, #0035ch
                MOV     DP, #00013h
vcal_4_sub_load_tbl_x1:     MOV     00000h[X1], A
                DEC     X1
                DEC     X1
                JRNZ    DP, vcal_4_sub_load_tbl_x1
                MOV     DP, #00362h
                ST      A, [DP]
                RT
clamp_result_store_sub_load_dp:     MOV     DP, #001a0h
                MOV     X1, #clamp_result_store_tbl
clamp_result_store_sub_rom_load_tbl_x1:     LCB     A, [X1]
                STB     A, [DP]
                INC     X1
                INC     DP
                CMP     DP, #001abh
                JLT     clamp_result_store_sub_rom_load_tbl_x1
                MOV     DP, #00172h
                L       A, #00bb3h
                ST      A, [DP]
                RT
serial_cmd_4D29:SRL A
                SRL A
                SRL A
                SRL A
                SRL A
                SRL A
                RT
percyl_counter_gate_sub_load_dp:     MOV     DP, #003dbh
                LB      A, [DP]
                CMPB    A, #066h
                JLT     percyl_counter_gate_sub_load_imm
                CMPB    A, #099h
                JLE     percyl_counter_gate_sub_return
                CMPB    A, #0ffh
                JGT     percyl_counter_gate_sub_return
percyl_counter_gate_sub_load_imm:     LB      A, #04ch
                CAL     percyl_counter_gate_sub_cmp_ram0d7
percyl_counter_gate_sub_return:     RT
idle_init_start_sub_load_r3:     MOVB    r3, #008h
                CLR     A
idle_init_start_sub_rom_load_tbl_x1:     LC      A, [X1]
                MB      C, PSWH.6
                INC     X1
                INC     X1
                JGE     idle_init_start_sub_load_x2
                RC
                RORB    r2
                RC
                RORB    r0
                SJ      idle_init_start_sub_decb_r3
idle_init_start_sub_load_x2:     MOV     X2, A
                SLL     A
                RORB    r2
                L       A, X2
                AND     A, #00fffh
                MOV     DP, A
                L       A, X2
                SWAP
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                MBR     C, [DP]
                RORB    r0
idle_init_start_sub_decb_r3:     DECB    r3
                JNE     idle_init_start_sub_rom_load_tbl_x1
                LB      A, r0
                XORB    A, r2
                RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0C5h,0A0h,02Fh
                DB  0CDh,005h,0B5h,01Ah,098h,01Bh,014h,032h
                DB  0C8h,036h,001h,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh
vss_clamp_common_sub_set_pswh_bit0_2:     SB      PSWH.0
                LB      A, #04dh
                CAL     percyl_counter_gate_sub_cmp_ram0d7
                RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
knock_div_calc4_if_ram215_bit0_clr:     JBR     off(00215h).0, knock_div_calc4_goto_1ac7
                JBS     off(00216h).1, knock_div_calc4_goto_1ac7
                J       knock_div_calc4_if_ram213_bit1_set
knock_div_calc4_goto_1ac7:     J       knock_div_calc4_load_imm_2
                DB  0FFh,0FFh,0FFh,0FFh
knock_div_calc4_if_ram215_bit0_clr_2:     JBR     off(00215h).0, knock_div_calc4_goto_1ae0
                JBS     off(00216h).1, knock_div_calc4_goto_1ae0
                J       knock_div_calc4_if_ram22f_bit4_set
knock_div_calc4_goto_1ae0:     J       knock_div_calc4_load_imm_3
                DB  0FFh,0FFh,0FFh,0FFh
crank_cycle_er2_store_load_imm:     L       A, #0141bh
                MB      C, 0a0h.7
                JLT     crank_cycle_er2_store_store_ie
                L       A, #0041bh
crank_cycle_er2_store_store_ie:     ST      A, IE
                J       crank_cycle_er2_store_load_lrb
tps_interp_exact_match_load_ie:     MOV     IE, #0141bh
                NOP
                MOV     IE, #0041bh
                J       tps_interp_exact_match_load_r0
ign_p40_toggle_load_ie:     MOV     IE, #0141bh
                NOP
                MOV     IE, #0041bh
                J       ign_p40_toggle_load_lrb
                DB  0FFh,0FFh,0FFh,0FFh
int_break_sub_load_ram07b:     MOVB    SCONB, #081h
                LC      A, 00020h
                CMP     A, #int_serial
                JEQ     int_break_sub_return
                MOVB    SCONB, #0a1h
int_break_sub_return:     RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
clamp_result_store_sub_load_r1:     MOVB    r1, #085h
                MOVB    r2, #081h
                L       A, #int_serial
                CMPC    A, 00020h
                JEQ     clamp_result_store_sub_return
                MOVB    r2, #0a1h
clamp_result_store_sub_return:     RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
serial_cmd_4E70:MOV DP, #00348h
                LB A, [DP]
                ANDB A, #0F1h
                RT
                DB  0FFh ; 4E77
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
vcal_4_sub_clear_acc_2:     CLR     A
                MOV     DP, #0011ah
                MB      C, [DP].0
                JLT     vcal_4_sub_store_ram3c2
                L       A, off(00382h)
vcal_4_sub_store_ram3c2:     ST      A, off(003c2h)
                RT
                DB  0FFh,0FFh,0FFh ; 4E8D
serial_cmd_4E90:CLRB A
                LCB A, 0003Bh
                ANDB A, #00Fh
                SWAPB
                STB A, 007h
                LCB A, rom_6d53
                ANDB A, #00Fh
                ORB A, 007h
                RT
                DB  0FFh ; 4EA4
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
ign_p40_toggle_load_imm_2:     LB      A, #0ffh
                JBR     off(00132h).5, ign_p40_toggle_cmp_acc_3
                LB      A, #0ffh
ign_p40_toggle_cmp_acc_3:     CMPB    A, off(00179h)
                MB      off(00132h).5, C
                LB      A, #0ffh
                JBR     off(00132h).6, ign_p40_toggle_cmp_acc_4
                LB      A, #0ffh
ign_p40_toggle_cmp_acc_4:     CMPB    A, off(00179h)
                MB      off(00132h).6, C
                LB      A, #0ffh
                JBR     off(00132h).7, ign_p40_toggle_cmp_acc_5
                LB      A, #0ffh
ign_p40_toggle_cmp_acc_5:     CMPB    A, off(00179h)
                MB      off(00132h).7, C
                LB      A, #003h
                JBR     off(0011dh).1, ign_p40_toggle_if_ram132_bit5_clr
                JBS     off(00132h).7, ign_p40_toggle_store_r0
ign_p40_toggle_load_imm_3:     LB      A, #001h
                SJ      ign_p40_toggle_store_r0
ign_p40_toggle_if_ram132_bit5_clr:     JBR     off(00132h).5, ign_p40_toggle_clear_acc
                JBR     off(00132h).6, ign_p40_toggle_load_imm_3
                LB      A, #002h
                SJ      ign_p40_toggle_store_r0
ign_p40_toggle_clear_acc:     CLRB    A
ign_p40_toggle_store_r0:     STB     A, r0
                J       ign_p40_toggle_clear_r1
                DB  0FFh
sensor_bank_gate3_sub_vcal_0:     VCAL    0
                STB     A, r3
                LB      A, 0d8h
                MOV     X1, #sensor_bank_gate3_tbl_2
                RT
knockretard_store_load_imm_2:     LB      A, #019h
                J       knockretard_store_addb_acc
                DB  000h
knockretard_store_load_ram280:     L       A, off(00280h)
                ST      A, er3
                MOV     X1, #knockretard_store_tbl
                LB      A, off(00288h)
                CAL     knockretard_table_gate_sub_load_acc
                VCAL    7
                STB     A, r0
                JBR     off(00230h).5, knockretard_store_goto_2410
                J       knockretard_store_load_ram29c
knockretard_store_goto_2410:     J       knockretard_store_goto_6e90
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh
idle_temp_hyst3_decb_ram296:     DECB    off(00296h)
                L       A, #02000h
                JBS     off(00220h).6, idle_temp_hyst3_goto_3d3a
                LC      A, rom_3d2b
idle_temp_hyst3_goto_3d3a:     J       idle_temp_hyst3_store_ram24a
idle_temp_hyst3_load_imm_4:     LB      A, #002h
                JBS     off(00220h).6, idle_temp_hyst3_store_ram296
                LCB     A, rom_3d38
idle_temp_hyst3_store_ram296:     STB     A, off(00296h)
                J       idle_temp_hyst3_clear_acc_3
                DB  0FFh,0FFh ; 4F7E
serial_cmd_4F80:CLRB A
                MOV DP, #00212h
                MB C, [DP].0
                JLT serial_cmd_4F8A
                LB A, 0DFh
serial_cmd_4F8A:RT
                DB  0FFh,0FFh,0FFh ; 4F8B
                DB  0FFh,0FFh
knockretard_store_sub_vcal_7:     VCAL    7
                STB     A, off(002cah)
                JBR     off(00217h).0, knockretard_store_sub_clear_acc
                JBR     off(00220h).6, knockretard_store_sub_clear_acc
                JBS     off(00224h).2, knockretard_store_sub_clear_acc
                JBR     off(00216h).2, knockretard_store_sub_clear_acc
                JBR     off(0022ch).4, knockretard_store_sub_clear_acc
                CMPB    off(00288h), #060h
                JGE     knockretard_store_sub_clear_acc
                CLRB    A
                LCB     A, code_1458+3
                JBS     off(00220h).2, knockretard_store_sub_cmp_acc
                LCB     A, overrev_hardcap_compare_cmp_ram0d9+3
knockretard_store_sub_cmp_acc:     CMPB    A, 0d9h
                JGE     knockretard_store_sub_load_dp
knockretard_store_sub_clear_acc:     CLRB    A
                STB     A, off(002bdh)
                STB     A, off(002beh)
                SJ      knockretard_store_sub_store_ram2c2
knockretard_store_sub_load_dp:     MOV     DP, #002bdh
                MOV     X1, #002beh
                MOVB    r0, #004h
                MOVB    r1, #02ah
                JBS     off(0022ch).2, knockretard_store_sub_load_r0
                LB      A, #02ah
                VCAL    7
                STB     A, r1
                L       A, X1
                XCHG    A, DP
                MOV     X1, A
                MOVB    r0, #006h
knockretard_store_sub_load_r0:     LB      A, r0
                MOVB    00000h[X1], A
                LB      A, [DP]
                JEQ     knockretard_store_sub_store_ram2c2
                DECB    [DP]
                CLRB    off(002adh)
                LB      A, r1
knockretard_store_sub_store_ram2c2:     STB     A, off(002c2h)
                RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
scale_result_common_sub_extnd_acc_3:     EXTND
                ADD     er3, A
                LB      A, off(002c2h)
                EXTND
                ADD     er3, A
                RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4FF9
;@ DwellRpm type=u8 count=22 colstride=2 formula=raw cols.axis=rom_5000 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Dwell" desc="Coil dwell against rpm (2A7h), multiplied with DwellBattery." at=rom_5000+1
rom_5000:       DB  0FFh ; 5000
                DB  09Ch,0F8h,09Fh,0F0h,0A8h,0E8h,0A5h,0E0h
                DB  0A9h,0D8h,0ACh,0D0h,0AFh,0C8h,0AAh,0C0h
                DB  0A4h,0B0h,097h,0A8h,091h,0A0h,08Ah,098h
                DB  081h,090h,077h,088h,06Eh,080h,064h,070h
                DB  05Ah,060h,04Eh,050h,043h,040h,037h,020h
                DB  02Ah,000h,01Ch ; 5029
;@ DwellBattery type=u8 count=13 colstride=2 formula=raw cols.axis=rom_502c cols.stride=2 cols.formula=p13_batt_v category="Dwell" desc="Coil dwell against battery voltage (2A8h): longer at low voltage." at=rom_502c+1
rom_502c:       DB  0FFh,020h,0FEh,021h,0BCh ; 502C
                DB  031h,0A7h,036h,09Dh,03Bh,092h,040h,088h
                DB  046h,07Dh,04Dh,073h,057h,068h,061h,053h
                DB  08Ah,03Fh,0EEh,000h,0EEh ; 5041
;@ IgnitionRpmCorrection type=u8 count=22 colstride=2 formula=raw cols.axis=rom_5046 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Ignition" desc="Advance added against rpm (2B7h), on top of the ignition maps: more at high rpm." at=rom_5046+1
rom_5046:       DB  0FFh,034h,0F8h ; 5046
                DB  030h,0F0h,02Ch,0E8h,029h,0E0h,026h,0D8h
                DB  023h,0D0h,01Fh,0C8h,01Ch,0C0h,019h,0B0h
                DB  015h,0A8h,013h,0A0h,011h,098h,00Fh,090h
                DB  00Eh,088h,00Ch,080h,00Ah,070h,007h,060h
                DB  005h,050h,003h,040h,002h,020h,000h,000h
                DB  000h ; 5071
;@ KnockRetardCoolant type=u8 count=6 colstride=2 formula=raw cols.axis=rom_5072 cols.stride=2 cols.formula=honda_temp_c category="Knock" desc="Knock: a limit against coolant temperature (2B1h), used with the knock retard against load (rom_507e)." at=rom_5072+1
rom_5072:       DB  0FFh,019h,0AEh,019h,087h,019h,057h ; 5072
                DB  019h,034h,000h,000h,000h ; 5079
;@ KnockLoad type=u8 count=2 colstride=2 formula=raw cols.axis=rom_507e cols.stride=2 cols.formula=map_load_axis_mbar category="Knock" desc="Knock: a value against load (two points), with KnockRetardCoolant (2B1h), in the knock retard limit." at=rom_507e+1
rom_507e:       DB  0D4h,000h,064h ; 507E
                DB  000h ; 5081
;@ Stock_rom_5082 type=u8 count=4 formula=raw category="Internal" desc="Stock data, 4 bytes, read by the code at idleign_result_store_cmp_acc; its role not traced."
rom_5082:       DB  089h,0D4h,076h,051h ; 5082
;@ CoolantPairCold type=u8 count=7 colstride=2 formula=raw cols.axis=rom_5086 cols.stride=2 cols.formula=honda_temp_c category="Internal" desc="Looked up against coolant temperature with rom_5094 when the coolant byte is under 28h (CoolantPairWarm above), in the coolant reading's ramp (ect_simulate_ramp)." at=rom_5086+1
rom_5086:       DB  0FFh,000h,01Fh ; 5086
                DB  000h,01Bh,000h,015h,006h,010h,00Dh,00Fh
                DB  00Dh,000h,00Dh ; 5091
;@ CoolantPairCold2 type=u8 count=7 colstride=2 formula=raw cols.axis=rom_5094 cols.stride=2 cols.formula=honda_temp_c category="Internal" desc="The partner of CoolantPairCold (coolant byte under 28h), in the coolant reading's ramp." at=rom_5094+1
rom_5094:       DB  0FFh,000h,01Fh,000h,01Bh ; 5094
                DB  000h,015h,000h,010h,000h,00Fh,000h,000h
                DB  000h ; 50A1
;@ CoolantPairWarm type=u8 count=7 colstride=2 formula=raw cols.axis=rom_50a2 cols.stride=2 cols.formula=honda_temp_c category="Internal" desc="Looked up against coolant temperature with its partner (rom_50b0) when the coolant byte is 28h or more (rom_5086/rom_5094 below that); into r3 in the coolant reading's ramp (ect_simulate_ramp)." at=rom_50a2+1
rom_50a2:       DB  0FFh,050h,0F1h,050h,0BAh,050h,0A1h ; 50A2
                DB  043h,057h,020h,028h,000h,000h,000h ; 50A9
;@ CoolantPairWarm2 type=u8 count=7 colstride=2 formula=raw cols.axis=rom_50b0 cols.stride=2 cols.formula=honda_temp_c category="Internal" desc="The partner of CoolantPairWarm (coolant byte 28h or more), in the coolant reading's ramp." at=rom_50b0+1
rom_50b0:       DB  0FFh ; 50B0
                DB  040h,0F1h,040h,0BAh,040h,0A1h,032h,057h
                DB  014h,028h,000h,000h,000h ; 50B9
;@ KnockLoadThreshold type=u8 count=5 colstride=2 formula=raw cols.axis=rom_50be cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Knock" desc="Knock: the load (0E7h) above which, against rpm, the knock retard can act." at=rom_50be+1
rom_50be:       DB  0FFh,040h,0A0h ; 50BE
                DB  040h,080h,038h,040h,02Ch,000h,02Ch ; 50C1
;@ IdleIgnition type=u16 count=5 colstride=4 formula=raw cols.axis=rom_50c8 cols.type=u16 cols.stride=4 cols.formula=raw category="Idle" desc="Idle: timing against the idle speed error (0B4h, crank period counts over the target) while flag 216h.7 is set." at=rom_50c8+2
rom_50c8:       DB  0FFh ; 50C8
                DB  0FFh,000h,000h,050h,001h,000h,000h,000h
                DB  001h,015h,000h,0B3h,000h,015h,000h,000h
                DB  000h,000h,000h ; 50D9
;@ IdleIgnition2 type=u16 count=5 colstride=4 formula=raw cols.axis=rom_50dc cols.type=u16 cols.stride=4 cols.formula=raw category="Idle" desc="Idle: timing against the idle speed error (0B4h, crank period counts over the target) while flag 216h.7 is clear." at=rom_50dc+2
rom_50dc:       DB  0FFh,0FFh,000h,000h,0BEh ; 50DC
                DB  001h,000h,000h,045h,001h,015h,000h,0CDh
                DB  000h,015h,000h,000h,000h,000h,000h ; 50E9
;@ Stock_rom_50f0 type=u8 count=10 formula=raw category="Internal" desc="Stock data, 10 bytes, read by the code at rpm_decel_limit_check_store_stk; its role not traced."
rom_50f0:       DB  0FFh ; 50F0
                DB  056h,080h,056h,060h,048h,040h,03Ch,000h
                DB  030h ; 50F9
;@ SpeedTable2BA type=u8 count=4 colstride=2 formula=raw cols.axis=rom_50fa cols.stride=2 cols.formula=raw category="Internal" desc="Against road speed (2BAh; 50h when not used)." at=rom_50fa+1
rom_50fa:       DB  0FFh,0A0h,05Dh,0A0h,02Fh,0A0h,000h ; 50FA
                DB  0A0h ; 5101
;@ SpeedTable2BC type=u8 count=4 colstride=2 formula=raw cols.axis=rom_5102 cols.stride=2 cols.formula=raw category="Internal" desc="Against road speed (2BCh; 80h when not used)." at=rom_5102+1
rom_5102:       DB  0FFh,020h,05Dh,020h,02Fh,020h,000h ; 5102
                DB  020h,000h,000h,000h,000h,000h,000h,000h
                DB  017h,037h,038h,03Bh,038h,045h,047h,055h
                DB  057h,05Ah,05Bh,05Bh,05Bh ; 5119
;@ IgnMinHigh type=u8 count=20 formula=p13_advance cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="Ignition" desc="High cam: the least advance against rpm (2B6h) - the timing is never let below it." at=rom_5102+8
;@ IgnMinLow type=u8 count=20 formula=p13_advance cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="Ignition" desc="Low cam: the least advance against rpm (2B6h) - the timing is never let below it." at=rom_511e+20
;@ IgnMinHigh2 type=u8 count=20 formula=p13_advance cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="Ignition" desc="High cam: the least advance against rpm (2B6h) while flag 231h.2 is set (2A9h at D0h or over)." at=rom_511e
rom_511e:       DB  02Fh,03Bh,040h ; 511E
                DB  04Ah,057h,064h,073h,088h,080h,06Fh,073h
                DB  080h,08Dh,08Dh,091h,091h,091h,091h,091h
                DB  091h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,008h,00Eh,017h,01Fh,02Dh
                DB  037h,040h,043h,05Bh,05Bh ; 5141
;@ IgnMinLow2 type=u8 count=20 formula=p13_advance cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="Ignition" desc="Low cam: the least advance against rpm (2B6h) while flag 231h.2 is set (2A9h at D0h or over)." at=rom_5146
rom_5146:       DB  000h,000h,000h ; 5146
                DB  002h,011h,022h,02Fh,037h,04Ch,05Dh,06Ah
                DB  06Eh,074h,076h,07Bh,077h,07Bh,082h,093h
                DB  093h ; 5159
;@ KnockRpmLimit type=u8 count=7 colstride=2 formula=raw cols.axis=rom_515a cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Knock" desc="Knock: a value against rpm compared with 0E7h, in the knock retard's own steps." at=rom_515a+1
rom_515a:       DB  0FFh,04Dh,0D0h,04Dh,0C0h,040h,0A0h ; 515A
                DB  033h,080h,033h,040h,033h,000h,033h ; 5161
;@ KnockRpmStep type=u8 count=7 colstride=2 formula=raw cols.axis=rom_5168 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Knock" desc="Knock: a value against rpm, multiplied with 2A5h - the size of the knock retard's steps." at=rom_5168+1
rom_5168:       DB  0FFh ; 5168
                DB  02Ah,0D0h,02Ah,0C0h,02Ah,0A0h,02Ah,080h
                DB  02Ah,040h,019h,000h,019h ; 5171
;@ Stock_rom_5176 type=u8 count=5 formula=raw category="Internal" desc="Stock data, 5 bytes, read by the code at sensor_bank_gate3_store_ram2a4; its role not traced."
rom_5176:       DB  000h,000h,04Ch ; 5176
                DB  080h,080h ; 5179
;@ KnockRpmCurveHigh type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="Knock" desc="High cam: a knock value against rpm, with flag 21Dh.5 (into 2ABh)." at=rom_517b
rom_517b:       DB  000h,000h,000h,000h,000h,000h ; 517B
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h ; 5189
;@ KnockRpmCurveLow type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="Knock" desc="Low cam: a knock value against rpm, with flag 21Dh.5 (into 2ABh)." at=rom_518f
rom_518f:       DB  000h,000h ; 518F
                DB  000h,000h,000h,000h,000h,000h,000h,004h
                DB  006h,008h,014h,017h,017h,000h,000h,000h
                DB  000h,000h ; 51A1
;@ Stock_rom_51a3 type=u8 count=9 formula=raw category="Internal" desc="Stock data, 9 bytes, read by the code at o2_trim_step_start_rom_load_051a3h_dp; its role not traced."
rom_51a3:       DB  008h,008h,008h,008h,008h,008h ; 51A3
                DB  008h,008h,008h ; 51A9
;@ Stock_rom_51ac type=u8 count=7 formula=raw category="Internal" desc="Stock data, 7 bytes, read by the code at tps_window_store2; its role not traced."
rom_51ac:       DB  030h,030h,040h,030h,030h ; 51AC
                DB  030h,020h ; 51B1
;@ Stock_rom_51b3 type=u8 count=6 formula=raw category="Internal" desc="Stock data, 6 bytes, read by the code at tps_window_store2; its role not traced."
rom_51b3:       DB  004h,030h,004h,020h,004h,020h ; 51B3
rom_51b9:       DB  0D4h,0D4h,064h,03Fh,0D4h,0B6h,064h,03Fh
;@ CoolantFuel type=u8 count=7 colstride=2 formula=trim_byte_64_pct cols.axis=rom_51c1 cols.stride=2 cols.formula=honda_temp_c category="Fuel" slot=ectcorr.fuel desc="Fuel against coolant temperature (17Ah; 40h = 0 %): the warm-up enrichment, applied to every pulse once the engine runs." at=rom_51c1+1
rom_51c1:       DB  0FFh,04Ch,0F5h,04Ch,0BAh,04Ah,087h,048h
                DB  02Eh,044h,028h,040h,000h,040h ; 51C9
;@ CoolantFuel2 type=u8 count=7 colstride=2 formula=trim_byte_64_pct cols.axis=rom_51cf cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="A second fuel correction against coolant temperature (17Bh; 40h = 0 %), applied off idle." at=rom_51cf+1
rom_51cf:       DB  0FFh,06Ah ; 51CF
                DB  0F5h,06Ah,0BAh,062h,087h,05Dh,02Eh,04Ah
                DB  028h,040h,000h,040h ; 51D9
;@ ClosedLoopCoolant1 type=u8 count=7 colstride=2 formula=raw cols.axis=rom_51dd cols.stride=2 cols.formula=honda_temp_c category="Closed loop" desc="Closed loop: a value against coolant temperature (17Ch) the O2 correction reads with rom_51b9." at=rom_51dd+1
rom_51dd:       DB  0FFh,040h,0F5h,040h ; 51DD
                DB  0BAh,040h,087h,040h,02Eh,040h,028h,040h
                DB  000h,040h ; 51E9
;@ ClosedLoopCoolant2 type=u8 count=7 colstride=2 formula=raw cols.axis=rom_51eb cols.stride=2 cols.formula=honda_temp_c category="Closed loop" desc="Closed loop: a value against coolant temperature (17Dh) the O2 correction reads with rom_51b9." at=rom_51eb+1
rom_51eb:       DB  0FFh,053h,0F5h,053h,0BAh,053h ; 51EB
                DB  087h,04Eh,02Eh,043h,028h,040h,000h,040h
;@ ClosedLoopCoolant3 type=u8 count=7 colstride=2 formula=raw cols.axis=rom_51f9 cols.stride=2 cols.formula=honda_temp_c category="Closed loop" desc="Closed loop: a value against coolant temperature (17Eh), the O2 correction's step when it is running." at=rom_51f9+1
rom_51f9:       DB  0FFh,060h,0D0h,060h,087h,059h,056h,050h
                DB  02Eh,045h,028h,040h,000h,040h ; 5201
;@ TipInCoolant type=u8 count=7 colstride=2 formula=trim_byte_64_pct cols.axis=rom_5207 cols.stride=2 cols.formula=honda_temp_c category="Tip-in" desc="Tip-in fuel against coolant temperature (17Fh; 40h = 0 %): more when cold." at=rom_5207+1
rom_5207:       DB  0FFh,08Fh ; 5207
                DB  0F5h,08Fh,0BAh,080h,087h,076h,02Eh,043h
                DB  028h,040h,000h,040h ; 5211
;@ IntakeAirFuel type=u16 count=7 colstride=3 formula=trim_word_pct cols.axis=rom_5215 cols.stride=3 cols.formula=honda_temp_c category="Fuel" desc="Fuel against intake air temperature (152h; 8000h = 0 %): more fuel in cold, dense air." at=rom_5215+1
rom_5215:       DB  0FFh,0EBh,091h,0F5h ; 5215
                DB  0EBh,091h,0E1h,008h,08Ch,0BAh,02Bh,087h
                DB  087h,000h,080h,057h,029h,07Ch,000h,029h
                DB  07Ch ; 5229
;@ PostFuel type=u16 count=7 colstride=3 formula=raw cols.axis=rom_522a cols.stride=3 cols.formula=honda_temp_c category="Fuel" desc="After-start fuel against coolant temperature (158h): the extra fuel the engine starts with, which then decays." at=rom_522a+1
rom_522a:       DB  0FFh,099h,099h,0F5h,099h,099h,0E1h ; 522A
                DB  08Fh,05Ah,0A6h,0CDh,03Ch,07Ah,0C3h,035h
                DB  034h,0D7h,023h,000h,0D7h,023h ; 5239
;@ Stock_rom_523f type=u8 count=4 formula=raw category="Internal" desc="Stock data, 4 bytes, read by the code at fueltbl_sanitize_advance; its role not traced."
rom_523f:       DB  0BAh,02Eh ; 523F
                DB  0A9h,057h ; 5241
;@ IntakeAirCoolantCross type=u8 count=2 colstride=2 formula=raw cols.axis=rom_5243 cols.stride=2 cols.formula=honda_temp_c category="Sensors" desc="Against intake air temperature, compared with the coolant temperature (flag 218h.2); a second table above 15 km/h." at=rom_5243+1
rom_5243:       DB  0BAh,03Bh,0A9h,094h ; 5243
rom_5247:       DB  004h,004h ; 5247
rom_5249:       DB  000h,000h,05Ah,004h,05Ah,004h,0E0h,000h
                DB  000h,000h ; 5251
;@ Stock_rom_5253 type=u16 count=5 formula=raw category="Internal" desc="Stock data, 10 bytes, read by the code at to_set_pswl4_flag_b_sub_sll_x1; its role not traced."
rom_5253:       DB  000h,000h,05Ah,004h,05Ah,004h ; 5253
                DB  0E0h,000h,000h,000h ; 5259
;@ Stock_rom_525d type=u16 count=2 formula=raw category="Internal" desc="Stock data, 5 bytes, read by the code at o2_trim_dp300_read_decb_dp_ind; its role not traced."
rom_525d:       DB  00Bh,0BDh,0BDh,06Fh ; 525D
                DB  02Ch ; 5261
;@ Stock_rom_5262 type=u16 count=2 formula=raw category="Internal" desc="Stock data, 5 bytes, read by the code at o2_trim_dp300_read_decb_dp_ind; its role not traced."
rom_5262:       DB  00Bh,0BDh,0BDh,06Fh,02Ch ; 5262
;@ OpenLoopLoad type=u8 count=8 colstride=2 formula=map_load_axis_mbar cols.axis=rom_5267 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Fuel" desc="The load (the map load byte, less the baro correction 19Ah) above which the fuel goes open loop and rich (11Ch.6), against rpm: lower at high rpm." at=rom_5267+1
rom_5267:       DB  0FFh,030h ; 5267
                DB  0F0h,050h,0E0h,070h,0C0h,0B0h,0A0h,0E0h
                DB  080h,0E0h,020h,0C0h,000h,0C0h ; 5271
;@ Stock_rom_5277 type=u8 count=16 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at tipin_gate_common_if_ram11f_bit5_clr; its role not traced."
rom_5277:       DB  0FFh,0FFh ; 5277
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5281
;@ BaroLoadCorrection type=u8 count=2 colstride=2 formula=raw cols.axis=rom_5287 cols.stride=2 cols.formula=map_load_axis_mbar category="Fuel" desc="Taken off the load before it is compared with the open-loop load (19Ah), against barometric pressure." at=rom_5287+1
rom_5287:       DB  0F5h,000h ; 5287
                DB  089h,030h ; 5289
;@ CoolantFuelMult type=u8 count=6 colstride=2 formula=raw cols.axis=rom_528b cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Fuel against coolant temperature (199h): a multiplier on the map's value while flag 11Ch.2 is set; also sets flag 218h.7 below its second point." at=rom_528b+1
rom_528b:       DB  0FFh,080h,01Fh,080h,018h,088h ; 528B
                DB  012h,092h,00Fh,098h,000h,098h ; 5291
;@ FuelCutCoolant type=u8 count=7 colstride=2 formula=raw cols.axis=rom_5297 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Overrun fuel cut (manual): a value against coolant temperature, in the cut's tracking (fuelcuttrack)." at=rom_5297+1
rom_5297:       DB  0FFh,08Ah ; 5297
                DB  0EDh,08Ah,094h,080h,062h,073h,044h,066h
                DB  02Eh,05Ah,000h,05Ah ; 52A1
;@ FuelCutCoolant2 type=u8 count=7 colstride=2 formula=raw cols.axis=rom_52a5 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Overrun fuel cut (manual): a second value against coolant temperature, in the cut's tracking (fuelcuttrack)." at=rom_52a5+1
rom_52a5:       DB  0FFh,07Dh,0EDh,07Dh ; 52A5
                DB  094h,06Ah,062h,05Dh,044h,050h,02Eh,043h
                DB  000h,043h ; 52B1
;@ Stock_rom_52b3 type=u16 count=7 formula=raw category="Internal" desc="Stock data, 14 bytes, read by the code at fuelcuttrack_store_load_imm; its role not traced."
rom_52b3:       DB  0FFh,08Ah,0EDh,08Ah,0BAh,082h ; 52B3
                DB  0A1h,070h,062h,05Bh,02Eh,050h,000h,050h
;@ Stock_rom_52c1 type=u8 count=30 formula=raw category="Internal" desc="Stock data, 30 bytes, read by the code at fuelcuttrack_store_load_imm; its role not traced."
rom_52c1:       DB  0FFh,07Dh,0EDh,07Dh,0BAh,06Dh,0A1h,060h
                DB  062h,050h,02Eh,033h,000h,033h,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 52D9
;@ CylinderFuelTrim type=u8 count=4 formula=trim_byte_pct category="Fuel" slot=cyltrim.fuel desc="Fuel trim for each cylinder, 1-4, on its own injector time (384h-38Ah; 80h = 0 %). The stock code applies it in closed loop only."
rom_52df:       DB  080h,080h ; 52DF
                DB  080h,080h ; 52E1
;@ BaroFuel type=u8 count=6 colstride=2 formula=raw cols.axis=rom_52e3 cols.stride=2 cols.formula=map_load_axis_mbar category="Fuel" desc="Fuel added against barometric pressure (189h): none at sea level, more as the pressure falls (FFh everywhere is about 40 % more fuel)." at=rom_52e3+1
rom_52e3:       DB  0FFh,000h,0F9h,000h,0DBh,00Fh ; 52E3
                DB  0BDh,02Ch,0A0h,048h,000h,048h ; 52E9
rom_52ef:       DB  0FFh,000h ; 52EF
                DB  070h,000h,050h,05Ah,030h,0A6h,010h,0FFh
                DB  000h,0FFh ; 52F9
;@ InjectorDeadTime type=u16 count=7 colstride=3 formula=p13_inj_ms cols.axis=rom_52fb cols.stride=3 cols.formula=p13_batt_v category="Fuel" desc="Injector dead time against battery voltage (142h): added to every pulse, cranking included - the time the injector takes to open." at=rom_52fb+1
rom_52fb:       DB  0FFh,08Bh,000h,0A7h,08Bh,000h ; 52FB
                DB  092h,0ABh,000h,07Dh,0DDh,000h,069h,036h
                DB  001h,054h,0E5h,001h,000h,0E5h,001h ; 5309
;@ TipInStanding type=u16 count=2 colstride=3 formula=p13_inj_ms category="Tip-in" cols.axis=rom_5310+0 cols.stride=3 cols.formula=raw cols.unit="TPS change" desc="Tip-in fuel standing (under 5 km/h, flag 117h.1 set): the extra pulse (146h) against how fast the throttle opens (0E9h, the change each pass), two points, the extra fuel in between in proportion." at=rom_5310+1
;@ TipInLowRpm type=u16 count=2 colstride=3 formula=p13_inj_ms category="Tip-in" cols.axis=rom_5310+6 cols.stride=3 cols.formula=raw cols.unit="TPS change" desc="Tip-in fuel moving, below about 1600 rpm (the rpm byte under 66h): the extra pulse (146h) against how fast the throttle opens (0E9h, the change each pass), two points, the extra fuel in between in proportion." at=rom_5310+7
;@ TipInLowRpm2 type=u16 count=2 colstride=3 formula=p13_inj_ms category="Tip-in" cols.axis=rom_5310+12 cols.stride=3 cols.formula=raw cols.unit="TPS change" desc="Tip-in fuel moving, below about 1600 rpm, with flag 11Ah.3: the extra pulse (146h) against how fast the throttle opens (0E9h, the change each pass), two points, the extra fuel in between in proportion." at=rom_5310+13
;@ TipInHighRpm type=u16 count=2 colstride=3 formula=p13_inj_ms category="Tip-in" cols.axis=rom_5310+18 cols.stride=3 cols.formula=raw cols.unit="TPS change" desc="Tip-in fuel moving, above about 1600 rpm: the extra pulse (146h) against how fast the throttle opens (0E9h, the change each pass), two points, the extra fuel in between in proportion." at=rom_5310+19
;@ TipInHighRpm2 type=u16 count=2 colstride=3 formula=p13_inj_ms category="Tip-in" cols.axis=rom_5310+24 cols.stride=3 cols.formula=raw cols.unit="TPS change" desc="Tip-in fuel moving, above about 1600 rpm, with flag 11Ah.3: the extra pulse (146h) against how fast the throttle opens (0E9h, the change each pass), two points, the extra fuel in between in proportion." at=rom_5310+25
rom_5310:       DB  099h ; 5310
                DB  0D9h,005h,000h,000h,000h,066h,04Fh,007h
                DB  000h,000h,000h,066h,034h,008h,000h,0D8h
                DB  000h,033h,0A7h,003h,000h,000h,000h,033h
                DB  08Ch,004h,000h,0D8h,000h ; 5329
;@ TipInSet2 type=u8 count=24 formula=raw category="Tip-in" desc="Tip-in: a second set of four two-point tables (6 bytes each: throttle change, pulse word; twice) picked by 2A4h and the rpm byte over 8Ah."
rom_532e:       DB  01Fh,0EEh,000h ; 532E
                DB  000h,000h,001h,028h,0ECh,000h,000h,000h
                DB  001h,01Fh,0E9h,000h,000h,000h,001h,028h
                DB  0ECh,000h,000h,000h,001h ; 5341
;@ TipInBaro type=u8 count=2 colstride=2 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 cols.axis=rom_5346 cols.stride=2 cols.formula=map_load_axis_mbar category="Tip-in" desc="Tip-in fuel against barometric pressure (186h; 80h = 100 %): less at altitude." at=rom_5346+1
rom_5346:       DB  0F9h,080h,089h ; 5346
                DB  040h ; 5349
rom_534a:       DB  0FFh,050h,0E1h,048h,094h,038h,057h ; 534A
                DB  018h,02Eh,000h,000h,000h ; 5351
;@ InjCoolantFactor type=u8 count=7 colstride=2 formula=raw cols.axis=rom_5356 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Against coolant temperature (187h, used while flag 119h.3 is set): multiplied by the count in 0E6h (at most 10h) in the injection time." at=rom_5356+1
rom_5356:       DB  0FFh,068h,0EDh ; 5356
                DB  068h,0D0h,05Dh,0A1h,057h,06Eh,03Ah,028h
                DB  013h,000h,013h ; 5361
;@ InjCoolantFactor2 type=u8 count=7 colstride=2 formula=raw cols.axis=rom_5364 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Against coolant temperature (188h, used while flag 119h.3 is clear): multiplied by the count in 0E6h (at most 14h) in the injection time." at=rom_5364+1
rom_5364:       DB  0FFh,029h,0EDh,029h,0D0h ; 5364
                DB  024h,0A1h,024h,06Eh,023h,028h,010h,000h
                DB  010h ; 5371
;@ LoadHoldCount type=u8 count=2 colstride=2 formula=raw cols.axis=rom_5372 cols.stride=2 cols.formula=map_load_axis_mbar category="Fuel" desc="Against load: a count (r2) held down to zero, then flag 218h.4." at=rom_5372+1
rom_5372:       DB  0FFh,01Eh,000h,00Fh ; 5372
rom_5376:       DB  0FFh,00Ah,000h ; 5376
                DB  019h ; 5379
;@ CrankFuel type=u16 count=7 colstride=3 formula=quarter cols.axis=rom_537a cols.stride=3 cols.formula=honda_temp_c category="Cranking" slot=crankfuel.ect desc="Cranking fuel against coolant temperature (the word / 4, as HTS shows it; 13Eh): the pulse while the starter turns, before the rpm and baro factors." at=rom_537a+1
rom_537a:       DB  0FFh,08Ah,066h,0F5h,08Ah,066h,0E1h ; 537A
                DB  0BAh,037h,0BAh,004h,029h,06Eh,088h,013h
                DB  028h,07Fh,008h,000h,07Fh,008h,0FFh,0FFh
                DB  0FFh,0FFh ; 5391
;@ CrankFuelBaro type=u8 count=2 colstride=2 formula=trim_signed_pct cols.axis=rom_5393 cols.stride=2 cols.formula=map_load_axis_mbar category="Cranking" desc="Cranking fuel against barometric pressure (183h; 80h = 0 %): less fuel at altitude." at=rom_5393+1
rom_5393:       DB  0F5h,080h,089h,04Eh ; 5393
;@ DecelResumeRpm type=u8 count=7 colstride=2 formula=p13_rpm8 cols.axis=rom_5397 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Overrun fuel cut (manual): once cut, the fuel comes back below this rpm, against coolant temperature (16Eh)." at=rom_5397+1
rom_5397:       DB  0FFh,083h ; 5397
                DB  0EDh,083h,094h,06Dh,062h,060h,044h,053h
                DB  02Eh,046h,000h,046h ; 53A1
;@ DecelResumeRpmAuto type=u8 count=7 colstride=2 formula=p13_rpm8 cols.axis=rom_53a5 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Overrun fuel cut (automatic): once cut, the fuel comes back below this rpm, against coolant temperature (16Eh)." at=rom_53a5+1
rom_53a5:       DB  0FFh,083h,0EDh,083h ; 53A5
                DB  0BAh,070h,0A1h,06Ah,062h,060h,02Eh,03Ah
                DB  000h,03Ah ; 53B1
;@ DecelCutRpm type=u8 count=7 colstride=2 formula=p13_rpm8 cols.axis=rom_53b3 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Overrun fuel cut (manual): with the throttle shut, the fuel is cut above this rpm, against coolant temperature (16Fh)." at=rom_53b3+1
rom_53b3:       DB  0FFh,08Dh,0EDh,08Dh,094h,080h ; 53B3
                DB  062h,073h,044h,066h,02Eh,05Ah,000h,05Ah
;@ DecelCutRpmAuto type=u8 count=7 colstride=2 formula=p13_rpm8 cols.axis=rom_53c1 cols.stride=2 cols.formula=honda_temp_c category="Fuel" desc="Overrun fuel cut (automatic): with the throttle shut, the fuel is cut above this rpm, against coolant temperature (16Fh)." at=rom_53c1+1
rom_53c1:       DB  0FFh,08Dh,0EDh,08Dh,0BAh,082h,0A1h,07Dh
                DB  062h,073h,02Eh,050h,000h,050h ; 53C9
rom_53cf:       DB  0FFh,014h ; 53CF
                DB  0FCh,014h,0E0h,013h,0CDh,009h,083h,009h
                DB  000h,009h ; 53D9
;@ DecelCutLoad2 type=u8 count=6 colstride=2 formula=map_load_axis_mbar cols.axis=rom_53db cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Fuel" desc="Overrun fuel cut: the load it needs to be under, against rpm (a second set)." at=rom_53db+1
rom_53db:       DB  0FFh,019h,0FCh,019h,0E0h,00Ch ; 53DB
                DB  0CDh,020h,0C0h,030h,000h,030h ; 53E1
;@ DecelCutLoad type=u8 count=6 colstride=2 formula=map_load_axis_mbar cols.axis=rom_53e7 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Fuel" desc="Overrun fuel cut: the load (less the baro correction) it needs to be under, against rpm." at=rom_53e7+1
rom_53e7:       DB  0FFh,01Dh ; 53E7
                DB  0FCh,01Dh,0E0h,01Dh,0CDh,013h,083h,013h
                DB  000h,013h ; 53F1
;@ DecelCutLoadHold type=u8 count=6 colstride=2 formula=map_load_axis_mbar cols.axis=rom_53f3 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Fuel" desc="Overrun fuel cut, once cut: the load it stays cut under, against rpm." at=rom_53f3+1
rom_53f3:       DB  0FFh,023h,0FCh,023h,0E0h,014h ; 53F3
                DB  0CDh,028h,0C0h,038h,000h,038h ; 53F9
;@ BaroDecelLoad type=u8 count=2 colstride=2 formula=raw cols.axis=rom_53ff cols.stride=2 cols.formula=map_load_axis_mbar category="Fuel" desc="Taken off the load before the overrun cut's load check (197h), against barometric pressure." at=rom_53ff+1
rom_53ff:       DB  0F8h,000h ; 53FF
                DB  000h,030h
;@ RevLimitLowResume type=u16 formula=rpm_period_word unit=rpm category="Limits" slot=stockrev.lowresume desc="The stock rev limiter (low cam): where the fuel comes back. Low cam: VTEC off, or code 22 stored; high cam: VTEC engaged. Fuel is cut above the cut point until the engine falls under the resume point; the boot starts from the high-cam pair as immediates (F4h/FAh)."
revlimit_p1_reset_5403:
                DB  02Ah,01h
                DB  0DFh,00h
;@ RevLimitLowCut type=u16 formula=rpm_period_word unit=rpm category="Limits" slot=stockrev.lowcut desc="The stock rev limiter (low cam): the cut point. Low cam: VTEC off, or code 22 stored; high cam: VTEC engaged. Fuel is cut above the cut point until the engine falls under the resume point; the boot starts from the high-cam pair as immediates (F4h/FAh)."
revlimit_p1_set_5407:
                DB  020h,01h
                DB  0C1h,00h
;@ RevLimitHighResume type=u16 formula=rpm_period_word unit=rpm category="Limits" slot=stockrev.highresume desc="The stock rev limiter (high cam): where the fuel comes back. Low cam: VTEC off, or code 22 stored; high cam: VTEC engaged. Fuel is cut above the cut point until the engine falls under the resume point; the boot starts from the high-cam pair as immediates (F4h/FAh)."
revlimit_p2_reset_540b:
                DB  0FAh,00h
                DB  012h,01h
;@ RevLimitHighCut type=u16 formula=rpm_period_word unit=rpm category="Limits" slot=stockrev.highcut desc="The stock rev limiter (high cam): the cut point. Low cam: VTEC off, or code 22 stored; high cam: VTEC engaged. Fuel is cut above the cut point until the engine falls under the resume point; the boot starts from the high-cam pair as immediates (F4h/FAh)."
revlimit_p2_set_540f:
                DB  0F4h,00h
                DB  0F0h,000h ; 5411
;@ KnockLevels type=u16 count=12 formula=raw category="Knock" desc="Knock: the detection levels by rpm band (162h)."
rom_5413:       DB  066h,086h,033h,083h,000h,080h ; 5413
                DB  0DDh,07Dh,0AAh,07Ah,0AAh,07Ah,066h,086h
                DB  033h,083h,000h,080h,0DDh,07Dh,0AAh,07Ah
                DB  0AAh,07Ah ; 5429
;@ KnockLevels2 type=u16 count=12 formula=raw category="Knock" desc="Knock: detection levels by rpm band (166h; automatic, flag 21Fh.3 clear)."
rom_542b:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 542B
                DB  0FFh,0FFh,0FFh,0FFh,000h,000h,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  000h,000h ; 5441
;@ KnockLevels3 type=u16 count=12 formula=raw category="Knock" desc="Knock: detection levels by rpm band (166h; manual)."
rom_5443:       DB  05Bh,004h,0CAh,004h,039h,005h ; 5443
                DB  0A9h,005h,018h,006h,000h,000h,039h,005h
                DB  0A9h,005h,018h,006h,088h,006h,0F7h,006h
                DB  000h,000h ; 5459
;@ Stock_rom_545b type=u8 count=4 formula=raw category="Internal" desc="Stock data, 4 bytes, read by the code at sensor_bank_gate3_cmp_acc_2; its role not traced."
rom_545b:       DB  04Dh,075h,09Eh,0C5h ; 545B
;@ IdleAirCoolant type=u16 count=9 colstride=3 formula=raw cols.axis=rom_545f cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (260h; manual)." at=rom_545f+1
rom_545f:       DB  0FFh,000h ; 545F
                DB  012h,0F5h,000h,012h,0E4h,080h,009h,0D0h
                DB  080h,009h,0B9h,000h,015h,087h,000h,012h
                DB  058h,000h,00Fh,02Eh,020h,001h,000h,020h
                DB  001h ; 5479
;@ IdleAirCoolantAuto type=u16 count=9 colstride=3 formula=raw cols.axis=rom_547a cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (260h; automatic)." at=rom_547a+1
rom_547a:       DB  0FFh,000h,010h,0F5h,000h,010h,0D8h ; 547A
                DB  000h,010h,0BAh,080h,009h,087h,000h,016h
                DB  067h,000h,016h,04Dh,000h,00Fh,02Eh,020h
                DB  001h,000h,020h,001h ; 5491
;@ IdleAirCoolant3 type=u16 count=9 colstride=3 formula=raw cols.axis=rom_5495 cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (268h; manual)." at=rom_5495+1
rom_5495:       DB  0FFh,000h,040h,0F5h ; 5495
                DB  000h,040h,0E4h,000h,024h,0D0h,000h,024h
                DB  0B9h,000h,02Dh,087h,000h,028h,058h,000h
                DB  020h,02Eh,080h,00Dh,000h,080h,00Dh ; 54A9
;@ IdleAirCoolant3Auto type=u16 count=9 colstride=3 formula=raw cols.axis=rom_54b0 cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (268h; automatic)." at=rom_54b0+1
rom_54b0:       DB  0FFh ; 54B0
                DB  000h,03Ch,0F5h,000h,03Ch,0D8h,000h,028h
                DB  0BAh,000h,01Eh,087h,000h,01Eh,067h,000h
                DB  01Eh,04Dh,000h,018h,02Eh,000h,00Fh,000h
                DB  000h,00Fh ; 54C9
;@ IdleAirCoolant2 type=u16 count=9 colstride=3 formula=raw cols.axis=rom_54cb cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (262h; manual)." at=rom_54cb+1
rom_54cb:       DB  0FFh,000h,026h,0F5h,000h,026h ; 54CB
                DB  0E4h,000h,016h,0D0h,000h,016h,0B9h,000h
                DB  01Bh,087h,000h,018h,058h,000h,014h,02Eh
                DB  000h,00Bh,000h,000h,00Bh ; 54E1
;@ IdleAirCoolant2Auto type=u16 count=9 colstride=3 formula=raw cols.axis=rom_54e6 cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (262h; automatic)." at=rom_54e6+1
rom_54e6:       DB  0FFh,000h,020h ; 54E6
                DB  0F5h,000h,020h,0D8h,000h,020h,0BAh,000h
                DB  019h,087h,000h,01Eh,067h,000h,01Eh,04Dh
                DB  000h,018h,02Eh,000h,00Fh,000h,000h,00Fh
;@ IdleControlRpm type=u8 count=7 colstride=2 formula=raw cols.axis=rom_5501 cols.stride=2 cols.formula=honda_temp_c category="Idle" desc="Idle: an rpm against coolant temperature (295h, the rpm byte): flag 216h.4 set above it (with 10 counts of hysteresis) - manual." at=rom_5501+1
rom_5501:       DB  0FFh,07Ah,0EDh,07Ah,094h,066h,062h,05Dh
                DB  044h,053h,02Eh,046h,000h,046h ; 5509
;@ IdleControlRpmAuto type=u8 count=7 colstride=2 formula=raw cols.axis=rom_550f cols.stride=2 cols.formula=honda_temp_c category="Idle" desc="Idle: an rpm against coolant temperature (295h, the rpm byte): flag 216h.4 set above it (with 10 counts of hysteresis) - automatic." at=rom_550f+1
rom_550f:       DB  0FFh,086h ; 550F
                DB  0EDh,086h,094h,07Ah,062h,070h,044h,066h
                DB  02Eh,066h,000h,066h ; 5519
;@ IdleTarget type=u16 count=7 colstride=3 formula=rpm_period_word cols.axis=rom_551d cols.stride=3 cols.formula=honda_temp_c category="Idle" slot=idle.target desc="Idle speed target against coolant temperature (286h, a crank period): 700 rpm warm, 1500 rpm cold. The idle valve is worked to hold it; just after a start IdleTargetStart is used instead." at=rom_551d+1
rom_551d:       DB  0FFh,0E2h,004h,0EDh ; 551D
                DB  0E2h,004h,094h,0A2h,005h,062h,05Eh,006h
                DB  044h,053h,007h,02Eh,077h,00Ah,000h,077h
                DB  00Ah ; 5531
;@ IdleTargetStart type=u16 count=7 colstride=3 formula=rpm_period_word cols.axis=rom_5532 cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle speed target just after a start, against coolant temperature (286h, a crank period): 950 rpm warm, 1700 rpm cold - for the first few seconds (until the time since start, 0FFh, passes 32h), then IdleTarget." at=rom_5532+1
rom_5532:       DB  0FFh,04Fh,004h,0EDh,04Fh,004h,094h ; 5532
                DB  0E2h,004h,062h,06Dh,005h,044h,01Bh,006h
                DB  02Eh,0B6h,007h,000h,0B6h,007h ; 5541
;@ IdleGains type=u8 count=3 formula=raw category="Idle" desc="Idle valve control: the gains (multiplying the speed error 0B4h into 24Ch, then 24Eh, and 0B2h into 250h) - one of four sets."
rom_5547:       DB  024h,00Ah ; 5547
                DB  02Eh ; 5549
;@ IdleGains2 type=u8 count=3 formula=raw category="Idle" desc="Idle valve control: the gains (flag 216h.7) - one of four sets."
rom_554a:       DB  010h,00Ch,001h ; 554A
;@ IdleGains3 type=u8 count=3 formula=raw category="Idle" desc="Idle valve control: the gains - one of four sets."
rom_554d:       DB  001h,001h,001h ; 554D
;@ IdleGains4 type=u8 count=3 formula=raw category="Idle" desc="Idle valve control: the gains - one of four sets."
rom_5550:       DB  001h ; 5550
                DB  002h,001h,000h ; 5551
;@ Stock_rom_5554 type=u16 count=1 formula=raw category="Internal" desc="Stock data, 2 bytes, read by the code at vemapscalar_gate; its role not traced."
rom_5554:       DB  000h,000h ; 5554
;@ Stock_rom_5556 type=u16 count=1 formula=raw category="Internal" desc="Stock data, 2 bytes, read by the code at vemapscalar_gate; its role not traced."
rom_5556:       DB  000h,00Fh ; 5556
;@ Stock_rom_5558 type=u16 count=1 formula=raw category="Internal" desc="Stock data, 2 bytes, read by the code at warmcold_tm2_check_if_ram220_bit0_clr; its role not traced."
rom_5558:       DB  000h ; 5558
                DB  006h ; 5559
;@ Stock_rom_555a type=u16 count=1 formula=raw category="Internal" desc="Stock data, 2 bytes, read by the code at int_break_load_imm; its role not traced."
rom_555a:       DB  000h,005h ; 555A
;@ IdleCoolantRpm type=u8 count=7 colstride=2 formula=raw cols.axis=rom_555c cols.stride=2 cols.formula=honda_temp_c category="Idle" desc="Idle: an rpm against coolant temperature (the rpm byte), compared with the rpm; above it the idle state's 2F6h is cleared." at=rom_555c+1
rom_555c:       DB  0FFh,070h,0EDh,070h,094h ; 555C
                DB  063h,062h,05Ah,044h,050h,02Eh,043h,000h
                DB  043h ; 5569
;@ IdleCoolantPeriod type=u16 count=7 colstride=3 formula=raw cols.axis=rom_556a cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle: a crank period against coolant temperature, compared with 0B2h; over it the idle state's 2F6h is cleared." at=rom_556a+1
rom_556a:       DB  0FFh,008h,000h,0EDh,008h,000h,094h ; 556A
                DB  012h,000h,062h,025h,000h,044h,02Eh,000h
                DB  02Eh,05Ah,000h,000h,05Ah,000h ; 5579
;@ IdleCoolantStep type=u8 count=7 colstride=2 formula=raw cols.axis=rom_557f cols.stride=2 cols.formula=honda_temp_c category="Idle" desc="Idle: a value against coolant temperature into 2F6h (the idle state's step)." at=rom_557f+1
rom_557f:       DB  0FFh,070h ; 557F
                DB  0EDh,070h,094h,054h,062h,048h,044h,040h
                DB  02Eh,034h,000h,034h ; 5589
;@ IdleCoolantGain type=u8 count=7 colstride=2 formula=raw cols.axis=rom_558d cols.stride=2 cols.formula=honda_temp_c category="Idle" desc="Idle: a multiplier against coolant temperature on the period difference (0B2h)." at=rom_558d+1
rom_558d:       DB  0FFh,01Ah,0EDh,01Ah ; 558D
                DB  094h,010h,062h,00Ah,044h,008h,02Eh,005h
                DB  000h,005h ; 5599
;@ IdleEldRpm2 type=u8 count=5 colstride=2 formula=raw cols.axis=rom_559b cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Idle" desc="Idle air for the electrical load: a second factor against rpm." at=rom_559b+1
rom_559b:       DB  0FFh,063h,04Dh,063h,020h,046h ; 559B
                DB  017h,03Eh,000h,03Eh ; 55A1
;@ IdleEldRpm type=u8 count=5 colstride=2 formula=raw cols.axis=rom_55a5 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Idle" desc="Idle air for the electrical load, against rpm: the ELD reading is scaled by it." at=rom_55a5+1
rom_55a5:       DB  0FFh,059h,04Dh,059h ; 55A5
                DB  02Dh,04Bh,017h,03Eh,000h,03Eh ; 55A9
rom_55af:       DB  0FFh,0C0h ; 55AF
                DB  005h,0A7h,030h,003h,082h,050h,001h,072h
                DB  010h,001h,060h,000h,000h,000h,000h,000h
;@ IdleIntakeAir type=u16 count=5 colstride=3 formula=raw cols.axis=rom_55c1 cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle: against intake air temperature (242h), multiplied with IdleIntakeAirRpm." at=rom_55c1+1
rom_55c1:       DB  0FFh,080h,004h,040h,080h,004h,033h,080h
                DB  006h,02Eh,080h,007h,000h,080h,007h ; 55C9
;@ IdleIntakeAirRpm type=u8 count=5 colstride=2 formula=raw cols.axis=rom_55d0 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Idle" desc="Idle: against rpm, multiplied with IdleIntakeAir (242h)." at=rom_55d0+1
rom_55d0:       DB  0FFh ; 55D0
                DB  0B8h,0A0h,0B8h,080h,09Ch,040h,080h,000h
                DB  080h ; 55D9
;@ IdleCoolantAir type=u16 count=9 colstride=3 formula=raw cols.axis=rom_55da cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle: a value against coolant temperature (23Eh), the idle air the cold engine is held to." at=rom_55da+1
rom_55da:       DB  0FFh,040h,00Bh,0F5h,040h,00Bh,0D0h ; 55DA
                DB  080h,009h,0BAh,000h,008h,094h,000h,00Bh
                DB  057h,080h,00Dh,044h,040h,009h,028h,040h
                DB  005h,000h,040h,005h ; 55F1
;@ IdleAirTargetPeriod type=u16 count=5 colstride=4 formula=raw cols.axis=rom_55f5 cols.type=u16 cols.stride=4 cols.formula=rpm_period_word cols.unit=rpm category="Idle" desc="Idle: the least idle air against the idle target (286h) while cold (coolant byte 38h or more)." at=rom_55f5+2
rom_55f5:       DB  0FFh,0FFh,040h,005h ; 55F5
                DB  0C5h,00Ah,040h,005h,077h,00Ah,040h,005h
                DB  045h,009h,080h,009h,000h,000h,080h,009h
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh
;@ IdleDashpot type=u16 count=8 colstride=3 formula=raw cols.axis=idle_temp_hyst3_tbl cols.stride=3 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Idle" desc="Idle air held open as the revs fall with the throttle shut (the dashpot, 25Eh), against rpm: low cam." at=idle_temp_hyst3_tbl+1
idle_temp_hyst3_tbl:       DB  0FFh,000h,007h,0DAh,000h,007h,0D0h,000h
                DB  024h,0C3h,080h,01Fh,0ADh,050h,012h,090h
                DB  0E0h,00Eh,066h,000h,000h,000h,000h,000h
;@ IdleDashpotHigh type=u16 count=8 colstride=3 formula=raw cols.axis=idle_temp_hyst3_tbl_2 cols.stride=3 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Idle" desc="Idle air held open as the revs fall with the throttle shut (the dashpot, 25Eh), against rpm: VTEC engaged." at=idle_temp_hyst3_tbl_2+1
idle_temp_hyst3_tbl_2:       DB  0FFh,000h,02Ah,0F0h,000h,02Ah,0E0h,000h
                DB  033h,0DAh,0D0h,029h,0D3h,000h,026h,0CAh
                DB  000h,00Bh,0C0h,000h,000h,000h,000h,000h
;@ BaroTable299 type=u8 count=2 colstride=2 formula=raw cols.axis=dcode14_check_tbl cols.stride=2 cols.formula=map_load_axis_mbar category="Sensors" desc="Against barometric pressure (299h)." at=dcode14_check_tbl+1
dcode14_check_tbl:       DB  0F7h,080h,060h,0C2h
;@ IdleAirCoolant4 type=u16 count=9 colstride=3 formula=raw cols.axis=overrev_hardcap_compare_tbl cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (264h; manual)." at=overrev_hardcap_compare_tbl+1
overrev_hardcap_compare_tbl:       DB  0FFh,000h,040h,0F1h,000h,040h,0E7h,000h
                DB  032h,0DEh,000h,028h,0D0h,000h,01Dh,0BAh
                DB  000h,017h,0A1h,000h,010h,062h,000h,000h
                DB  000h,000h,000h
;@ IdleAirCoolant4Auto type=u16 count=9 colstride=3 formula=raw cols.axis=overrev_hardcap_compare_tbl_2 cols.stride=3 cols.formula=honda_temp_c category="Idle" desc="Idle air against coolant temperature (264h; automatic)." at=overrev_hardcap_compare_tbl_2+1
overrev_hardcap_compare_tbl_2:       DB  0FFh,000h,040h,0F1h,000h,040h,0E7h,000h
                DB  03Dh,0DEh,000h,031h,0D0h,000h,022h,0BAh
                DB  000h,019h,0A1h,000h,012h,062h,000h,000h
                DB  000h,000h,000h
;@ IdleValveCurrent type=u16 count=9 colstride=4 formula=raw cols.axis=idle_gear_target_store_tbl cols.type=u16 cols.stride=4 cols.formula=raw category="Idle" desc="Idle: the idle valve's current target (26Eh) against the air wanted (23Ch)." at=idle_gear_target_store_tbl+2
idle_gear_target_store_tbl:       DB  0FFh,0FFh,0C0h,0FFh,000h,040h,000h,0F0h,07Ah,02Ch
                DB  000h,0C0h,0D7h,01Bh,000h,0A0h,0E3h,00Dh,000h,080h
                DB  0DEh,004h,000h,060h,016h,002h,000h,050h,0B4h,000h
                DB  066h,046h,000h,000h,099h,039h,000h,000h,000h,000h
;@ VTECLoad type=u8 count=7 colstride=2 formula=map_load_axis_mbar cols.axis=injector_effective_pw_skip_tbl cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="VTEC" slot=vtec.stock.curve desc="Stock VTEC: the load (the map load byte) needed against rpm, between the with-load and any-load points; 16 counts less once in." at=injector_effective_pw_skip_tbl+1
injector_effective_pw_skip_tbl:       DB  0FFh,000h,0DCh,000h,0D9h,050h,0D4h,0D0h
                DB  0CFh,0F0h,0CDh,0FFh,000h,0FFh,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
;@ InjectorTimingCoolant type=u16 count=8 colstride=3 formula=raw cols.axis=overrev_hardcap_compare_tbl_3 cols.stride=3 cols.formula=honda_temp_c category="Fuel" desc="Against coolant temperature (1B0h, a word): what each cylinder's injector start countdown (398h-) is loaded with on its tooth." at=overrev_hardcap_compare_tbl_3+1
overrev_hardcap_compare_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ VtecChangeTimingHigh type=u8 count=20 formula="(x - 128) / 4" inverse="x * 4 + 128" unit=° decimals=2 cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="VTEC" desc="High cam: the timing added during the VTEC change-over (2C4h, 80h = none; FFh here), against rpm." at=tipin_decay_zero_tbl
;@ VtecChangeTimingLow type=u8 count=20 formula="(x - 128) / 4" inverse="x * 4 + 128" unit=° decimals=2 cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="VTEC" desc="Low cam: the timing added during the VTEC change-over (2C4h, 80h = none), against rpm." at=tipin_decay_zero_tbl-20
tipin_decay_zero_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ MapFailsafeLoad type=u8 count=2 colstride=2 formula=map_load_axis_mbar cols.axis=tbl_tps_5736 cols.stride=2 cols.formula=tps_pct category="Sensors" desc="The load used instead of the MAP sensor's when it has failed (codes 3/5): against throttle - the fail-safe load." at=tbl_tps_5736+1
tbl_tps_5736:       DB  066h,0E0h,01Ah,060h
tbl_ect_simulate_ramp:       DB  0E1h,0CFh,0A0h,06Dh,028h
;@ IdleValveCheckLow type=u16 count=2 colstride=3 formula=raw cols.axis=tbl_dcode14_lo cols.stride=3 cols.formula=p13_batt_v category="Internal" desc="The idle valve check (code 14): the lowest current reading against battery voltage." at=tbl_dcode14_lo+1
tbl_dcode14_lo:       DB  0A7h,0CDh,0FCh,034h,000h,038h
;@ IdleValveCheckHigh type=u16 count=2 colstride=3 formula=raw cols.axis=tbl_dcode14_hi cols.stride=3 cols.formula=p13_batt_v category="Internal" desc="The idle valve check (code 14): the highest current reading against battery voltage." at=tbl_dcode14_hi+1
tbl_dcode14_hi:       DB  0FFh,000h,000h,000h,000h,000h
;@ DecelCutThrottle type=u8 count=2 colstride=2 formula=p13_rpm8 cols.axis=revlimiter_engage_resume_check_tbl cols.stride=2 cols.formula=tps_pct category="Limits" desc="With the throttle nearly shut (under 2Eh) the fuel is cut above this rpm, against throttle (above 2000 rpm whatever the throttle when its sensor has failed, code 7): part of the overrun fuel cut." at=revlimiter_engage_resume_check_tbl+1
revlimiter_engage_resume_check_tbl:       DB  02Eh,060h,022h
dtc_scan_new_code_tbl:       DB  04Dh,00Fh,00Fh,00Fh,02Dh,02Dh,04Bh,00Fh
                DB  000h,00Fh,02Dh,00Fh,02Dh,02Dh,0FFh,000h
                DB  02Dh,006h,02Dh,00Fh,00Fh,02Dh,02Dh,0FFh
                DB  0FFh,007h,007h,014h,0FFh,0FFh,0FFh,0FFh
                DB  0FFh
;@ Stock_clamp_result_store_tbl type=u8 count=6 formula=raw category="Internal" desc="Stock data, 6 bytes, read by the code at clamp_result_store_sub_load_dp; its role not traced."
clamp_result_store_tbl:       DB  02Dh,02Dh,007h,006h,006h,006h
;@ Stock_learn_table1_check_tbl type=u8 count=10 formula=raw category="Internal" desc="Stock data, 10 bytes, read by the code at learn_table1_check; its role not traced."
learn_table1_check_tbl:       DB  019h,000h,019h,019h,019h,0FFh,0FFh,0FFh,0FFh,0B3h
dtc_active_confirm_tbl:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah
                DB  000h,00Ch,00Ch,00Dh,00Eh,011h,000h,000h
                DB  014h,015h,016h,017h,018h,01Eh,01Fh,000h
                DB  000h,019h,01Ah,01Bh,000h,000h,000h,000h
                DB  000h,004h,008h,009h,00Fh,01Eh,01Fh,010h
                DB  000h,004h,008h,009h,000h,000h,000h,000h
                DB  01Dh,0A1h,044h,034h
;@ Stock_tbl_map_sign type=u8 count=4 formula=raw category="Internal" desc="Stock data, 4 bytes, read by the code at overrev_hardcap_compare_store_carry_ram232_bit4; its role not traced."
tbl_map_sign:       DB  000h,000h,000h,000h
;@ Stock_rpm_decel_limit_check_tbl type=u8 count=12 formula=raw category="Internal" desc="Stock data, 12 bytes, read by the code at rpm_decel_limit_check; its role not traced."
rpm_decel_limit_check_tbl:       DB  0D4h,001h,0A9h,003h,053h,007h,000h,000h
                DB  000h,000h,0FFh,0FFh
;@ Stock_crank_sync_exit_jump_tbl type=u8 count=24 formula=raw category="Internal" desc="Stock jump addresses (code; do not edit), 24 bytes, read by the code at crank_sync_exit_jump_clear_acc; its role not traced."
crank_sync_exit_jump_tbl:       DB  084h,094h,0A4h,0B4h,006h,016h,026h,036h
                DB  046h,056h,06Eh,07Eh,08Eh,09Eh,0AEh,0BEh
                DB  00Ch,01Ch,02Ch,03Ch,04Ch,05Ch,064h,074h
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh
;@ Stock_knockretard_store_tbl type=u8 count=3 formula=raw category="Internal" desc="Stock data, 3 bytes, read by the code at knockretard_store_load_ram280; its role not traced."
knockretard_store_tbl:       DB  088h,0FFh,076h
;@ IntakeAirLoad type=u8 count=5 colstride=2 formula=raw cols.axis=sensor_bank_gate3_tbl cols.stride=2 cols.formula=honda_temp_c category="Sensors" desc="Against intake air temperature (into r2, then 280h), with the load over zero." at=sensor_bank_gate3_tbl+1
sensor_bank_gate3_tbl:       DB  0FFh,000h,087h,000h,057h,011h,013h,019h,000h,019h
sensor_bank_gate3_tbl_2:       DB  0FFh,000h,087h,000h,057h,000h,013h,000h,000h,000h
fuelcuttrack_store_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ Stock_fuelcuttrack_store_tbl_2 type=u8 count=10 formula=raw category="Internal" desc="Stock data, 10 bytes, read by the code at fuelcuttrack_store_sub_load_x1; its role not traced."
fuelcuttrack_store_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
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
;@ Stock_idle_temp_hyst3_tbl_3 type=u8 count=8 formula=raw category="Internal" desc="Stock data, 8 bytes, read by the code at idle_temp_hyst3_load_er0; its role not traced."
idle_temp_hyst3_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ Stock_o2trim_add_clamp_tbl type=u16 count=8 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at o2trim_add_clamp_sub_load_imm_3; its role not traced."
o2trim_add_clamp_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
sensor_bank_gate3_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
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
calchecksum_loop_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ RpmScalerLow type=u16 count=20 formula=rpm_period_word category="Axes" desc="Rpm axis of the low-cam maps (crank periods, falling: the rpm rising)."
tbl_rpm_scalar_lo40:       DB  0A6h,00Eh,0C5h,00Ah,076h,00Ah,045h,009h,053h,007h
                DB  0A2h,005h,0E2h,004h,011h,004h,07Ch,003h,0EEh,002h
                DB  09Dh,002h,071h,002h,027h,002h,0EDh,001h,0D4h,001h
                DB  0B4h,001h,08Eh,001h,06Fh,001h,038h,001h,0FAh,000h
;@ RpmScalerHigh type=u16 count=20 formula=rpm_period_word category="Axes" desc="Rpm axis of the high-cam maps (crank periods, falling: the rpm rising)."
tbl_rpm_scalar_hi40:       DB  0A2h,005h,0E2h,004h,011h,004h,07Ch,003h,0EEh,002h
                DB  09Dh,002h,071h,002h,0FAh,001h,0D4h,001h,0BEh,001h
                DB  0A0h,001h,08Eh,001h,077h,001h,061h,001h,04Eh,001h
                DB  038h,001h,020h,001h,013h,001h,0FDh,000h,0EAh,000h
;@ MapScaler type=u8 count=10 formula=map_load_axis_mbar category="Axes" desc="Load axis of the fuel and ignition maps (the map load byte, 288h: (MAP - 1800h) >> 7)."
tbl_map_axis_mbar10:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,0FFh
;@ VESlopeLow type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="VE" desc="The low cam's speed-density base fuel: at each rpm row, the slope against load - the base pulse is this x the load (135h) / 16, plus the offset (VEOffsetLow) x 2. One straight line against load for each rpm row; between rows it is interpolated."
;@ VEOffsetLow type=u8 count=20 formula="x - 128" inverse="x + 128" cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="VE" desc="The low cam's speed-density base fuel: at each rpm row, the offset (80h = none) added, x 2, to the slope (VESlopeLow) x the load / 16." at=tbl_fuel_row_mult_lo40+20
tbl_fuel_row_mult_lo40:       DB  076h,075h,075h,077h,077h,07Ch,080h,080h,081h,088h
                DB  086h,083h,086h,088h,08Ch,093h,093h,095h,094h,085h
                DB  0A1h,0A8h,0AAh,0A9h,0A2h,096h,098h,09Eh,0A6h,09Eh
                DB  099h,09Dh,09Eh,0ABh,09Ah,0A3h,0A3h,0A6h,083h,063h
;@ VESlopeHigh type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="VE" desc="The high cam's speed-density base fuel: at each rpm row, the slope against load - the base pulse is this x the load (135h) / 16, plus the offset (VEOffsetHigh) x 2. One straight line against load for each rpm row; between rows it is interpolated."
;@ VEOffsetHigh type=u8 count=20 formula="x - 128" inverse="x + 128" cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="VE" desc="The high cam's speed-density base fuel: at each rpm row, the offset (80h = none) added, x 2, to the slope (VESlopeHigh) x the load / 16." at=tbl_fuel_row_mult_hi40+20
tbl_fuel_row_mult_hi40:       DB  097h,097h,097h,097h,097h,095h,092h,09Eh,09Ah,09Ah
                DB  094h,094h,09Ah,09Fh,0A1h,0A8h,0AEh,0ADh,0A8h,0A2h
                DB  002h,002h,002h,002h,002h,002h,002h,002h,01Dh,025h
                DB  038h,034h,04Eh,068h,085h,084h,08Ch,07Ah,06Ch,06Ah
;@ FuelLow type=u8 size=20x10 stride=10 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 rows.axis=RpmScalerLow rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Fuel" desc="Low-cam fuel map (P13): the open-loop enrichment on the speed-density base (VE): 80h = 100 %, no enrichment. At 80h or under the ECU stays at its closed-loop 100 %; over 80h it goes open loop and rich by this much, at most FuelMapCap (137.5 % stock). Not a fuel amount like the P30's maps."
tbl_fuel_lo_cam:       DB  080h,080h,080h,090h,08Eh,091h,09Ch,0AEh,0A7h,0A7h
                DB  080h,080h,080h,08Ch,08Eh,08Fh,0A1h,0AEh,0B0h,0B0h
                DB  080h,080h,080h,091h,092h,08Fh,0A1h,0AEh,0AFh,0AFh
                DB  080h,080h,080h,093h,08Fh,090h,0A2h,0AFh,0AEh,0AEh
                DB  080h,080h,080h,095h,091h,093h,094h,0A0h,09Eh,09Eh
                DB  080h,080h,080h,094h,091h,092h,093h,09Dh,09Bh,09Ah
                DB  080h,080h,080h,090h,090h,090h,091h,09Bh,099h,099h
                DB  080h,080h,080h,093h,08Eh,08Eh,092h,09Ch,09Dh,09Ch
                DB  080h,080h,080h,08Fh,08Eh,090h,091h,09Dh,0A1h,0A1h
                DB  080h,080h,080h,090h,08Dh,08Ch,08Fh,099h,09Bh,09Bh
                DB  080h,080h,080h,08Fh,08Fh,08Fh,09Dh,099h,09Ah,09Ah
                DB  080h,080h,080h,092h,092h,092h,095h,09Eh,09Fh,09Fh
                DB  080h,080h,080h,093h,092h,090h,092h,09Eh,09Ch,09Ch
                DB  080h,080h,093h,091h,091h,08Fh,092h,09Eh,09Ch,09Ch
                DB  080h,080h,09Ah,096h,095h,094h,097h,0A1h,09Fh,09Fh
                DB  080h,098h,094h,091h,091h,08Fh,08Eh,09Bh,099h,099h
                DB  080h,097h,095h,094h,092h,092h,09Eh,09Ch,09Bh,09Bh
                DB  080h,09Eh,096h,093h,092h,093h,09Ch,09Bh,09Ah,09Ah
                DB  080h,0A3h,099h,097h,094h,08Ah,093h,091h,08Fh,08Fh
                DB  080h,0A0h,0AAh,0ABh,0ABh,0AAh,0ADh,0ADh,0ADh,0ADh
;@ FuelHigh type=u8 size=20x10 stride=10 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 rows.axis=RpmScalerHigh rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Fuel" desc="High-cam fuel map (P13): the open-loop enrichment on the speed-density base (VE): 80h = 100 %, no enrichment. At 80h or under the ECU stays at its closed-loop 100 %; over 80h it goes open loop and rich by this much, at most FuelMapCap (137.5 % stock). Not a fuel amount like the P30's maps."
tbl_fuel_hi_cam:       DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h
                DB  080h,080h,080h,082h,084h,08Ah,08Dh,09Bh,09Dh,09Dh
                DB  080h,080h,080h,080h,080h,085h,08Eh,09Dh,0A3h,0A3h
                DB  080h,080h,080h,081h,082h,086h,08Ch,097h,099h,099h
                DB  080h,080h,080h,087h,088h,088h,08Eh,09Bh,09Ah,09Ah
                DB  080h,080h,088h,09Ch,089h,08Ah,08Eh,09Eh,095h,095h
                DB  080h,080h,09Fh,095h,092h,090h,093h,092h,096h,096h
                DB  080h,096h,086h,083h,088h,097h,09Ah,099h,098h,098h
                DB  080h,0A0h,095h,090h,092h,09Eh,0A4h,0A7h,0A5h,0A5h
                DB  080h,09Eh,096h,095h,09Ah,0A5h,0A6h,0A5h,0A6h,0A6h
                DB  080h,09Ah,08Fh,08Fh,093h,09Bh,098h,099h,09Bh,09Bh
                DB  080h,09Ch,097h,094h,08Eh,0A1h,09Eh,09Ch,09Bh,09Bh
                DB  080h,092h,099h,099h,0A5h,0A0h,09Fh,09Ch,099h,099h
                DB  080h,099h,0A0h,0A0h,0ACh,0A5h,0A2h,0A1h,09Dh,09Dh
                DB  080h,099h,099h,09Ah,0B0h,0ADh,0A8h,0A8h,0A5h,0A5h
                DB  080h,08Dh,0A4h,0A3h,0ADh,0A9h,0A7h,0A7h,0A3h,0A3h
;@ FuelCorrLowAuto type=u8 size=11x10 stride=10 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 rows.axis=tbl_rpm_scalar_lo40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Fuel" desc="Low cam, automatic: a fuel correction on the map's value for rpm rows 4-13 (18Fh; 80h = 100 %)."
tbl_corr_map_a_623a:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,078h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,079h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,07Bh,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,078h,07Bh,080h,080h,080h
                DB  080h,080h,07Eh,07Eh,07Eh,07Eh,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
;@ FuelCorrLow type=u8 size=11x10 stride=10 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 rows.axis=tbl_rpm_scalar_lo40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Fuel" desc="Low cam, manual: a fuel correction on the map's value for rpm rows 4-13 (18Fh; 80h = 100 %)."
tbl_corr_map_b_62a8:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,078h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,079h,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,07Bh,080h,080h,080h,080h
                DB  080h,080h,07Ah,07Ah,078h,07Bh,080h,080h,080h,080h
                DB  080h,080h,07Eh,07Eh,07Eh,07Eh,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
;@ FuelCorrHighAuto type=u8 size=11x10 stride=10 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 rows.axis=tbl_rpm_scalar_hi40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Fuel" desc="High cam, automatic: a fuel correction on the map's value for rpm rows 4-13 (18Fh; 80h = 100 %)."
tbl_corr_map_c_6316:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
;@ FuelCorrHigh type=u8 size=11x10 stride=10 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 rows.axis=tbl_rpm_scalar_hi40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Fuel" desc="High cam, manual: a fuel correction on the map's value for rpm rows 4-13 (18Fh; 80h = 100 %)."
tbl_corr_map_d_6384:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
;@ Stock_tbl_aux_63f2 type=u8 count=6 formula=raw category="Internal" desc="Stock data, 6 bytes, read by the code at tps_interp_exact_match_andb_acc; its role not traced."
tbl_aux_63f2:       DB  040h,000h,06Bh,0BFh,08Dh,02Bh
;@ IgnitionLow type=u8 size=20x10 stride=10 formula=p13_advance rows.axis=RpmScalerLow rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Ignition" desc="Low-cam ignition map (P13), degrees before TDC."
tbl_ign_lo_cam:       DB  055h,055h,055h,055h,02Eh,00Eh,000h,000h,000h,000h
                DB  055h,055h,055h,055h,030h,00Fh,000h,000h,000h,000h
                DB  055h,055h,055h,055h,038h,010h,000h,000h,000h,000h
                DB  055h,055h,055h,055h,044h,024h,00Ah,006h,002h,002h
                DB  055h,055h,055h,055h,055h,03Bh,01Dh,019h,011h,011h
                DB  074h,074h,074h,072h,06Fh,051h,033h,02Ah,022h,022h
                DB  085h,085h,085h,082h,077h,057h,03Bh,033h,02Fh,02Fh
                DB  090h,090h,090h,08Dh,07Eh,062h,048h,040h,037h,037h
                DB  098h,098h,098h,095h,084h,06Bh,059h,04Ch,04Ch,04Ch
                DB  09Eh,09Eh,09Eh,09Ah,091h,077h,061h,05Dh,05Dh,05Dh
                DB  09Fh,09Fh,09Fh,09Bh,095h,07Eh,072h,06Ah,06Ah,06Ah
                DB  09Fh,09Fh,09Fh,09Bh,093h,080h,072h,06Eh,06Eh,06Eh
                DB  0A4h,0A4h,0A0h,09Bh,099h,08Ah,07Dh,074h,074h,074h
                DB  0A9h,0A6h,0A3h,0A1h,09Eh,08Dh,07Dh,076h,076h,076h
                DB  0ADh,0AAh,0A9h,0A3h,09Eh,08Eh,07Eh,07Bh,07Bh,07Bh
                DB  0B3h,0AEh,0A9h,0A1h,09Bh,08Fh,07Eh,077h,077h,077h
                DB  0B3h,0AEh,0A7h,09Dh,097h,093h,08Fh,086h,07Bh,07Bh
                DB  0B3h,0AEh,0A7h,0A0h,09Bh,095h,091h,086h,082h,082h
                DB  0B3h,0AEh,0A9h,0A7h,0A6h,0A0h,09Bh,099h,093h,093h
                DB  0B3h,0AEh,0A9h,0A7h,0A6h,0A0h,09Bh,099h,093h,093h
;@ IgnitionLowAltAuto type=u8 size=11x10 stride=10 formula=p13_advance unit="deg BTDC" rows.axis=tbl_rpm_scalar_lo40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Ignition" desc="Low cam, automatic: the ignition map used instead of IgnitionLow for rpm rows 4-13 while code 12 is stored or flag 218h.4 is set (degrees before TDC)."
tbl_ign_lo_cam_alt1:       DB  055h,055h,055h,055h,055h,03Bh,01Dh,019h,011h,011h
                DB  074h,074h,074h,072h,06Fh,051h,033h,02Ah,022h,022h
                DB  085h,085h,085h,082h,077h,057h,03Bh,033h,02Fh,02Fh
                DB  090h,090h,090h,08Dh,07Eh,062h,048h,040h,037h,037h
                DB  098h,098h,098h,095h,084h,06Bh,059h,04Ch,04Ch,04Ch
                DB  09Eh,09Eh,09Eh,09Ah,091h,077h,061h,05Dh,05Dh,05Dh
                DB  09Fh,09Fh,09Fh,09Bh,095h,07Eh,072h,06Ah,06Ah,06Ah
                DB  09Fh,09Fh,09Fh,09Bh,093h,080h,072h,06Eh,06Eh,06Eh
                DB  0A4h,0A4h,0A0h,09Bh,099h,08Ah,07Dh,074h,074h,074h
                DB  0A9h,0A6h,0A3h,0A1h,09Eh,08Dh,07Dh,076h,076h,076h
                DB  0ADh,0AAh,0A9h,0A3h,09Eh,08Eh,07Eh,07Bh,07Bh,07Bh
;@ IgnitionLowAlt type=u8 size=11x10 stride=10 formula=p13_advance unit="deg BTDC" rows.axis=tbl_rpm_scalar_lo40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Ignition" desc="Low cam, manual: the ignition map used instead of IgnitionLow for rpm rows 4-13 while code 12 is stored or flag 218h.4 is set (degrees before TDC)."
tbl_ign_lo_cam_alt2:       DB  055h,055h,055h,055h,055h,03Bh,01Dh,019h
                DB  011h,011h,074h,074h,074h,072h,06Fh,051h
                DB  033h,02Ah,022h,022h,085h,085h,085h,082h
                DB  077h,057h,03Bh,033h,02Fh,02Fh,090h,090h
                DB  090h,08Dh,07Eh,062h,048h,040h,037h,037h
                DB  098h,098h,098h,095h,084h,06Bh,059h,04Ch
                DB  04Ch,04Ch,09Eh,09Eh,09Eh,09Ah,091h,077h
fueltbl_range_check_tbl:       DB  061h,05Dh,05Dh,05Dh,09Fh,09Fh,09Fh,09Bh
                DB  095h,07Eh,072h,06Ah,06Ah,06Ah,09Fh,09Fh
                DB  09Fh,09Bh,093h,080h,072h,06Eh,06Eh,06Eh
                DB  0A4h,0A4h,0A0h,09Bh,099h,08Ah,07Dh,074h
                DB  074h,074h,0A9h,0A6h,0A3h,0A1h,09Eh,08Dh
                DB  07Dh,076h,076h,076h,0ADh,0AAh,0A9h,0A3h
                DB  09Eh,08Eh,07Eh,07Bh,07Bh,07Bh
;@ IgnitionHigh type=u8 size=20x10 stride=10 formula=p13_advance rows.axis=RpmScalerHigh rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Ignition" desc="High-cam ignition map (P13), degrees before TDC."
tbl_ign_hi_cam:       DB  08Ah,085h,080h,07Ch,062h,040h,035h,033h,02Fh,02Fh
                DB  08Eh,089h,084h,07Ch,06Dh,046h,042h,040h,03Bh,03Bh
                DB  09Bh,096h,091h,088h,080h,055h,048h,042h,040h,040h
                DB  09Fh,09Ah,095h,08Dh,084h,062h,051h,04Bh,04Ah,04Ah
                DB  0ACh,0A7h,0A2h,099h,091h,073h,062h,05Eh,057h,057h
                DB  0B9h,0B4h,0AFh,0A2h,097h,077h,06Dh,06Bh,064h,064h
                DB  0D2h,0CDh,0C8h,0C0h,0AFh,088h,080h,07Ch,073h,073h
                DB  0E3h,0DEh,0D9h,0D1h,0AFh,0A0h,091h,08Dh,088h,088h
                DB  0E3h,0DEh,0D9h,0D1h,0ADh,09Eh,088h,084h,080h,080h
                DB  0E3h,0DEh,0D9h,0CDh,0AAh,09Bh,07Bh,073h,06Fh,06Fh
                DB  0E3h,0DEh,0D9h,0CDh,0A6h,099h,07Eh,077h,073h,073h
                DB  0E3h,0DEh,0D9h,0C8h,0A0h,097h,088h,080h,080h,080h
                DB  0E6h,0E6h,0E0h,0C4h,0A5h,09Dh,095h,08Dh,08Dh,08Dh
                DB  0E3h,0E3h,0D5h,0C0h,0A8h,09Eh,097h,093h,08Dh,08Dh
                DB  0DAh,0DAh,0C9h,0C0h,0A8h,0A0h,097h,093h,091h,091h
                DB  0D5h,0D5h,0C4h,0B7h,0A4h,09Bh,095h,091h,091h,091h
                DB  0C8h,0C8h,0B7h,0B3h,0A2h,099h,095h,093h,091h,091h
                DB  0CAh,0CAh,0B9h,0B0h,0A2h,099h,095h,093h,091h,091h
                DB  0B6h,0B6h,0A7h,0A0h,09Bh,099h,095h,093h,091h,091h
                DB  0B6h,0B6h,0A7h,0A0h,09Bh,099h,095h,093h,091h,091h
;@ IgnitionHighAltAuto type=u8 size=11x10 stride=10 formula=p13_advance unit="deg BTDC" rows.axis=tbl_rpm_scalar_hi40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Ignition" desc="High cam, automatic: the ignition map used instead of IgnitionHigh for rpm rows 4-13 while code 12 is stored or flag 218h.4 is set (degrees before TDC)."
tbl_ign_hi_cam_alt1:                 DW  0a7ach
o2trim_add_clamp_tbl_2:       DB  0A2h,099h,091h,073h,062h,05Eh,057h,057h
                DB  0B9h,0B4h,0AFh,0A2h,097h,077h,06Dh,06Bh
                DB  064h,064h,0D2h,0CDh,0C8h,0C0h,0AFh,088h
                DB  080h,07Ch,073h,073h,0E3h,0DEh,0D9h,0D1h
                DB  0AFh,0A0h,091h,08Dh,088h,088h,0E3h,0DEh
                DB  0D9h,0D1h,0ADh,09Eh,088h,084h,080h,080h
                DB  0E3h,0DEh,0D9h,0CDh,0AAh,09Bh,07Bh,073h
                DB  06Fh,06Fh,0E3h,0DEh,0D9h,0CDh,0A6h,099h
                DB  07Eh,077h,073h,073h,0E3h,0DEh,0D9h,0C8h
                DB  0A0h,097h,088h,080h,080h,080h,0E6h,0E6h
                DB  0E0h,0C4h,0A5h,09Dh,095h,08Dh,08Dh,08Dh
                DB  0E3h,0E3h,0D5h,0C0h,0A8h,09Eh,097h,093h
                DB  08Dh,08Dh,0DAh,0DAh,0C9h,0C0h,0A8h,0A0h
                DB  097h,093h,091h,091h
;@ IgnitionHighAlt type=u8 size=11x10 stride=10 formula=p13_advance unit="deg BTDC" rows.axis=tbl_rpm_scalar_hi40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="Ignition" desc="High cam, manual: the ignition map used instead of IgnitionHigh for rpm rows 4-13 while code 12 is stored or flag 218h.4 is set (degrees before TDC)."
tbl_ign_hi_cam_alt2:       DB  0ACh,0A7h,0A2h,099h,091h,073h,062h,05Eh,057h,057h
                DB  0B9h,0B4h,0AFh,0A2h,097h,077h,06Dh,06Bh,064h,064h
                DB  0D2h,0CDh,0C8h,0C0h,0AFh,088h,080h,07Ch,073h,073h
                DB  0E3h,0DEh,0D9h,0D1h,0AFh,0A0h,091h,08Dh,088h,088h
                DB  0E3h,0DEh,0D9h,0D1h,0ADh,09Eh,088h,084h,080h,080h
                DB  0E3h,0DEh,0D9h,0CDh,0AAh,09Bh,07Bh,073h,06Fh,06Fh
                DB  0E3h,0DEh,0D9h,0CDh,0A6h,099h,07Eh,077h,073h,073h
                DB  0E3h,0DEh,0D9h,0C8h,0A0h,097h,088h,080h,080h,080h
                DB  0E6h,0E6h,0E0h,0C4h,0A5h,09Dh,095h,08Dh,08Dh,08Dh
                DB  0E3h,0E3h,0D5h,0C0h,0A8h,09Eh,097h,093h,08Dh,08Dh
                DB  0DAh,0DAh,0C9h,0C0h,0A8h,0A0h,097h,093h,091h,091h
;@ EgrMapLowAuto type=u8 size=11x10 stride=10 formula=raw rows.axis=tbl_rpm_scalar_lo40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="EGR" desc="Low cam, automatic: the EGR lift wanted for rpm rows 4-13 and load (added to 290h for the target, 294h), once warm."
injector_effective_pw_skip_tbl_2:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,00Ch,013h,019h,02Dh,000h,000h,000h,000h
                DB  000h,000h,00Ch,013h,029h,03Ch,000h,000h,000h,000h
                DB  000h,000h,00Eh,018h,02Fh,050h,000h,000h,000h,000h
                DB  000h,000h,010h,01Ah,033h,05Ch,000h,000h,000h,000h
                DB  000h,000h,01Bh,025h,03Fh,060h,000h,000h,000h,000h
                DB  000h,000h,01Eh,02Bh,04Eh,060h,000h,000h,000h,000h
                DB  000h,000h,01Fh,030h,052h,060h,000h,000h,000h,000h
                DB  000h,000h,020h,032h,054h,060h,000h,000h,000h,000h
                DB  000h,000h,00Bh,010h,01Ch,020h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
;@ EgrMapLow type=u8 size=11x10 stride=10 formula=raw rows.axis=tbl_rpm_scalar_lo40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="EGR" desc="Low cam, manual: the EGR lift wanted for rpm rows 4-13 and load (added to 290h for the target, 294h), once warm."
injector_effective_pw_skip_tbl_3:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,00Ch,013h,019h,02Dh,000h,000h,000h,000h
                DB  000h,000h,00Ch,013h,029h,03Ch,000h,000h,000h,000h
                DB  000h,000h,00Eh,018h,02Fh,050h,000h,000h,000h,000h
                DB  000h,000h,010h,01Ah,033h,05Ch,000h,000h,000h,000h
                DB  000h,000h,01Bh,025h,03Fh,060h,000h,000h,000h,000h
                DB  000h,000h,01Eh,02Bh,04Eh,060h,000h,000h,000h,000h
                DB  000h,000h,01Fh,030h,052h,060h,000h,000h,000h,000h
                DB  000h,000h,020h,032h,054h,060h,000h,000h,000h,000h
                DB  000h,000h,00Bh,010h,01Ch,020h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
;@ EgrMapHighAuto type=u8 size=11x10 stride=10 formula=raw rows.axis=tbl_rpm_scalar_hi40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="EGR" desc="High cam, automatic: the EGR lift wanted for rpm rows 4-13 and load (all zero: no EGR with VTEC engaged)."
tbl_zero_681c:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
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
;@ EgrMapHigh type=u8 size=11x10 stride=10 formula=raw rows.axis=tbl_rpm_scalar_hi40+8 rows.type=u16 rows.formula=rpm_period_word cols.axis=tbl_map_axis_mbar10 cols.formula=map_load_axis_mbar category="EGR" desc="High cam, manual: the EGR lift wanted for rpm rows 4-13 and load (all zero: no EGR with VTEC engaged)."
tbl_zero_688a:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
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
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
;@ IdleRpmTable type=u16 count=5 colstride=3 formula=raw cols.axis=idle_temp_hyst3_tbl_4 cols.stride=3 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Idle" desc="Idle: a word against rpm, with the idle valve's current check (32Fh)." at=idle_temp_hyst3_tbl_4+1
idle_temp_hyst3_tbl_4:       DB  0FFh,000h,03Ch,0A0h,000h,03Ch,080h,000h
                DB  022h,040h,000h,00Ah,000h,000h,00Ah
;@ OpenLoopThrottle type=u8 count=8 colstride=2 formula=raw cols.axis=tbl_inj_pw_volt_6911 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Fuel" desc="The throttle (less 5 counts when flag 11Ch.4 is set) above which, against rpm, the open-loop enrichment can start (1E5h)." at=tbl_inj_pw_volt_6911+1
tbl_inj_pw_volt_6911:       DB  0FFh,098h,0E0h,098h,0D0h,080h,0C0h,073h
                DB  0A0h,073h,080h,066h,040h,066h,000h,066h
;@ FuelMapCap type=u8 formula="x * 100 / 64" inverse="x * 64 / 100" unit=% decimals=1 category="Fuel" desc="The most open-loop enrichment the fuel maps can give (half scale: 40h = 100 %, 58h = 137.5 % stock): a map value over twice this is held to it."
tbl_dw_6921:                 DW  05858h
;@ OpenLoopCurveHigh type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="Fuel" desc="High cam: an open-loop enrichment limit against rpm (all FFh: none) - the map's value is held to it when flag 11Ch.4 is set." at=tbl_allff_6923
tbl_allff_6923:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ OpenLoopCurveLow type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="Fuel" desc="Low cam: an open-loop enrichment limit against rpm (all FFh: none) - the map's value is held to it when flag 11Ch.4 is set." at=tbl_allff_6937
tbl_allff_6937:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ AccelRpm type=u16 count=7 colstride=3 formula=raw cols.axis=rpm_accel_clamp_tbl cols.stride=3 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="Tip-in" desc="Against rpm (a word): the acceleration count (198h) is checked against it and the period (0B2h)." at=rpm_accel_clamp_tbl+1
rpm_accel_clamp_tbl:       DB  0FFh,056h,000h,0A0h,056h,000h,080h,056h
                DB  000h,06Dh,074h,000h,060h,093h,000h,040h
                DB  0AFh,000h,000h,0AFh,000h,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh
;@ VtecChangeTiming2High type=u8 count=20 formula="(x - 128) / 4" inverse="x * 4 + 128" unit=° decimals=2 cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="VTEC" desc="High cam: the timing added while VTEC is asked for (1B4h) but not engaged yet (2C4h, 80h = none), against rpm." at=tipin_decay_zero_tbl_2
;@ VtecChangeTiming2Low type=u8 count=20 formula="(x - 128) / 4" inverse="x * 4 + 128" unit=° decimals=2 cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="VTEC" desc="Low cam: the timing added while VTEC is asked for (1B4h) but not engaged yet (2C4h, 80h = none), against rpm." at=tipin_decay_zero_tbl_2-20
tipin_decay_zero_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ IgnMinHighVtec type=u8 count=20 formula=p13_advance cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="Ignition" desc="High cam: the least advance against rpm (2B6h) during the VTEC change-over (21Dh.0)." at=scale_result_common_tbl
;@ IgnMinLowVtec type=u8 count=20 formula=p13_advance cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="Ignition" desc="Low cam: the least advance against rpm (2B6h) during the VTEC change-over (21Dh.0)." at=scale_result_common_tbl+20
scale_result_common_tbl:       DB  000h,000h,004h,00Ah,015h,01Eh,022h,037h,048h,04Ch
                DB  051h,057h,05Eh,06Ah,077h,084h,084h,080h,075h,075h
                DB  000h,000h,000h,000h,000h,000h,000h,001h,008h,011h
                DB  01Ah,022h,02Fh,03Ah,040h,045h,04Ch,05Eh,07Bh,07Bh
;@ AtShiftPoints type=u8 count=22 formula=raw category="Transmission" desc="Automatic: shift points against 0DEh, six to a gear (all FFh in this image)."
ign_p40_toggle_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ VtecSolenoidDuty type=u8 count=32 formula=raw category="VTEC" desc="VTEC: the solenoid's drive value (1AEh) by state, while the change-over count (1B6h) is 8 or less."
tbl_cfg_69c6:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,022h,06Eh,022h
                DB  044h,022h,028h,022h,000h,022h,0FFh,000h
                DB  087h,000h,057h,011h,013h,019h,000h,019h
;@ TipInCoolantAsync type=u8 count=7 colstride=2 formula=raw cols.axis=overrev_hardcap_compare_tbl_4 cols.stride=2 cols.formula=honda_temp_c category="Tip-in" desc="The least tip-in pulse against coolant temperature (194h), for the pulse given between the injections." at=overrev_hardcap_compare_tbl_4+1
overrev_hardcap_compare_tbl_4:       DB  0FFh,060h,0D0h,060h,0BAh,060h,087h,060h
                DB  02Eh,050h,028h,040h,000h,040h
;@ IdleRpmMargin type=u8 count=7 colstride=2 formula=raw cols.axis=idle_temp_hyst3_tbl_5 cols.stride=2 cols.formula=honda_temp_c category="Idle" desc="Idle: taken off the idle control rpm (295h), against coolant temperature, before it is compared with the rpm." at=idle_temp_hyst3_tbl_5+1
idle_temp_hyst3_tbl_5:       DB  0FFh,006h,0EDh,006h,094h,006h,062h,006h
                DB  044h,006h,02Eh,019h,000h,019h
;@ KnockFallbackHigh type=u8 count=20 formula=degrees_quarter unit=° cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="Knock" desc="Timing taken out against rpm with VTEC engaged when the knock unit cannot be trusted (its reference check failing, or code 23/24 stored): a fixed retard in place of the knock unit's own (2B4h)."
scale_result_common_tbl_2:       DB  024h,024h,024h,022h,031h,027h,026h,022h,028h,01Bh
                DB  017h,017h,022h,02Ah,022h,019h,01Dh,01Dh,01Dh,01Dh
;@ KnockFallbackLow type=u8 count=20 formula=degrees_quarter unit=° cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="Knock" desc="Timing taken out against rpm on the low cam when the knock unit cannot be trusted (its reference check failing, or code 23/24 stored): a fixed retard in place of the knock unit's own (2B4h)."
scale_result_common_tbl_3:       DB  000h,000h,000h,000h,011h,019h,022h,01Bh,020h,028h
                DB  028h,035h,02Ch,028h,024h,026h,024h,026h,01Dh,01Dh
Cranking_tbl:       DB  0FFh,0FFh,080h,000h,000h,031h,080h,000h
                DB  04Fh,012h,053h,000h,000h,000h,053h,000h
;@ EgrLoadRpm type=u8 count=6 colstride=2 formula=raw cols.axis=injector_effective_pw_skip_tbl_6 cols.stride=2 cols.formula=p13_rpm8 cols.unit=rpm cols.decimals=0 category="EGR" desc="EGR: the load against rpm (flag 11Eh.2) over which the EGR is off (12Fh.4); 38h/40h otherwise." at=injector_effective_pw_skip_tbl_6+1
injector_effective_pw_skip_tbl_6:       DB  0FFh,000h,0B0h,000h,0A0h,070h,060h,070h
                DB  040h,070h,000h,000h
tbl_knock_6a46:       DB  066h,073h,08Ch,099h,080h
;@ IntakeAirTable2CB type=u8 count=2 colstride=2 formula=raw cols.axis=sensor_bank_gate3_tbl_4 cols.stride=2 cols.formula=honda_temp_c category="Sensors" desc="Against intake air temperature (2CBh)." at=sensor_bank_gate3_tbl_4+1
sensor_bank_gate3_tbl_4:       DB  0B3h,000h,0A9h,080h
;@ VtecLoadFloorLow type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="VTEC" desc="Low cam: a load floor against rpm (135h: the load 0E3h, or this if more)." at=tbl_6a4f
tbl_6a4f:       DB  008h,005h,004h,004h,006h,009h,009h,009h,005h,009h
                DB  00Bh,00Ah,009h,005h,00Ah,007h,007h,005h,00Eh,018h
;@ VtecLoadFloorHigh type=u8 count=20 formula=raw cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="VTEC" desc="High cam: a load floor against rpm (135h: the load 0E3h, or this if more)." at=tbl_6a63
tbl_6a63:       DB  034h,034h,034h,034h,034h,034h,034h,026h,028h,028h
                DB  024h,024h,01Bh,012h,00Ah,00Bh,00Eh,012h,016h,016h
;@ FuelRpmMultLow type=u8 count=20 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 cols.axis=tbl_rpm_scalar_lo40 cols.type=u16 cols.formula=rpm_period_word category="Fuel" desc="Low cam: a multiplier against rpm on the fuel map's value (80h = 100 %)."
tbl_corr_map_lo_6a77:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,085h,086h,086h
;@ FuelRpmMultHigh type=u8 count=20 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 cols.axis=tbl_rpm_scalar_hi40 cols.type=u16 cols.formula=rpm_period_word category="Fuel" desc="High cam: a multiplier against rpm on the fuel map's value (80h = 100 %): a few per cent more near the top."
tbl_corr_map_hi_6a8b:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,080h,080h,083h,088h,088h,084h,086h,086h
;@ KnockLevels5 type=u16 count=12 formula=raw category="Knock" desc="Knock: detection levels by rpm band (166h; automatic, flag 21Fh.3 set)."
tbl_knock_retard_6a9f:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,000h,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,000h,000h
;@ KnockLevels4 type=u16 count=12 formula=raw category="Knock" desc="Knock: detection levels by rpm band (166h; manual, flag 21Fh.3 set)."
tbl_knock_ptr_6ab7:       DB  039h,005h,0A9h,005h,018h,006h,088h,006h
                DB  0F7h,006h,000h,000h,018h,006h,088h,006h
                DB  0F7h,006h,067h,007h,0D6h,007h,000h,000h
int_serial_tbl: DW  003C1h                        ; 6ACF
                DW  003C0h                        ; 6AD1
                DW  serial_cmd_4F80               ; 6AD3
                DW  0FFFFh                        ; 6AD5
                DW  0FFFFh                        ; 6AD7
                DW  0FFFFh                        ; 6AD9
                DW  0FFFFh                        ; 6ADB
                DW  0FFFFh                        ; 6ADD
                DW  003C4h                        ; 6ADF
                DW  003C5h                        ; 6AE1
                DW  0FFFFh                        ; 6AE3
                DW  003C6h                        ; 6AE5
                DW  003C7h                        ; 6AE7
                DW  003C8h                        ; 6AE9
                DW  0FFFFh                        ; 6AEB
                DW  003C9h                        ; 6AED
                DW  003DAh                        ; 6AEF
                DW  003D2h                        ; 6AF1
                DW  00075h                        ; 6AF3
                DW  003D3h                        ; 6AF5
                DW  00077h                        ; 6AF7
                DW  003D0h                        ; 6AF9
                DW  0FFFFh                        ; 6AFB
                DW  003D7h                        ; 6AFD
                DW  0006Dh                        ; 6AFF
                DW  003D8h                        ; 6B01
                DW  00073h                        ; 6B03
                DW  0006Fh                        ; 6B05
                DW  0FFFFh                        ; 6B07
                DW  0FFFFh                        ; 6B09
                DW  0FFFFh                        ; 6B0B
                DW  0FFFFh                        ; 6B0D
                DW  00161h                        ; 6B0F
                DW  0FFFFh                        ; 6B11
                DW  00309h                        ; 6B13
                DW  0FFFFh                        ; 6B15
                DW  003C3h                        ; 6B17
                DW  003C2h                        ; 6B19
                DW  00282h                        ; 6B1B
                DW  serial_cmd_4C43               ; 6B1D
                DW  serial_cmd_4C2C               ; 6B1F
                DW  00071h                        ; 6B21
                DW  serial_cmd_4C3B               ; 6B23
                DW  00294h                        ; 6B25
                DW  00291h                        ; 6B27
                DW  0FFFFh                        ; 6B29
                DW  0FFFFh                        ; 6B2B
                DW  0FFFFh                        ; 6B2D
                DW  0FFFFh                        ; 6B2F
                DW  0FFFFh                        ; 6B31
                DW  0FFFFh                        ; 6B33
                DW  0FFFFh                        ; 6B35
                DW  0FFFFh                        ; 6B37
                DW  001A1h                        ; 6B39
                DW  001A2h                        ; 6B3B
                DW  001A0h                        ; 6B3D
                DW  001A9h                        ; 6B3F
                DW  001AAh                        ; 6B41
                DW  001A8h                        ; 6B43
                DW  000F8h                        ; 6B45
                DW  0FFFFh                        ; 6B47
                DW  0FFFFh                        ; 6B49
                DW  0FFFFh                        ; 6B4B
                DW  0FFFFh                        ; 6B4D
                DW  serial_cmd_4E70               ; 6B4F
                DW  00349h                        ; 6B51
                DW  0034Ah                        ; 6B53
                DW  0034Bh                        ; 6B55
                DW  0034Ch                        ; 6B57
                DW  0034Dh                        ; 6B59
                DW  0034Eh                        ; 6B5B
                DW  0034Fh                        ; 6B5D
                DW  00350h                        ; 6B5F
                DW  00351h                        ; 6B61
                DW  00352h                        ; 6B63
                DW  00353h                        ; 6B65
                DW  00354h                        ; 6B67
                DW  00355h                        ; 6B69
                DW  00356h                        ; 6B6B
                DW  00357h                        ; 6B6D
                DW  00358h                        ; 6B6F
                DW  00359h                        ; 6B71
                DW  0035Ah                        ; 6B73
                DW  0035Bh                        ; 6B75
                DW  0035Ch                        ; 6B77
                DW  0035Dh                        ; 6B79
                DW  0FFFFh                        ; 6B7B
                DW  0FFFFh                        ; 6B7D
                DW  0FFFFh                        ; 6B7F
                DW  0FFFFh                        ; 6B81
                DW  0FFFFh                        ; 6B83
                DW  0FFFFh                        ; 6B85
                DW  0FFFFh                        ; 6B87
                DW  0FFFFh                        ; 6B89
                DW  0FFFFh                        ; 6B8B
                DW  0FFFFh                        ; 6B8D
                DW  00338h                        ; 6B8F
                DW  00339h                        ; 6B91
                DW  0033Ah                        ; 6B93
                DW  0033Bh                        ; 6B95
                DW  0033Ch                        ; 6B97
                DW  0033Dh                        ; 6B99
                DW  0033Eh                        ; 6B9B
                DW  0033Fh                        ; 6B9D
                DW  00340h                        ; 6B9F
                DW  00341h                        ; 6BA1
                DW  00342h                        ; 6BA3
                DW  00343h                        ; 6BA5
                DW  00344h                        ; 6BA7
                DW  00345h                        ; 6BA9
                DW  00346h                        ; 6BAB
                DW  00347h                        ; 6BAD
                DW  0FFFFh                        ; 6BAF
                DW  0FFFFh                        ; 6BB1
                DW  0FFFFh                        ; 6BB3
                DW  0FFFFh                        ; 6BB5
                DW  0FFFFh                        ; 6BB7
                DW  0FFFFh                        ; 6BB9
                DW  0FFFFh                        ; 6BBB
                DW  0FFFFh                        ; 6BBD
                DW  serial_cmd_4E90               ; 6BBF
                DW  06D54h                        ; 6BC1
                DW  serial_cmd_4C4B               ; 6BC3
                DW  serial_cmd_4C56               ; 6BC5
                DW  serial_cmd_4C25               ; 6BC7
                DW  0FFFFh                        ; 6BC9
                DW  0FFFFh                        ; 6BCB
                DW  0FFFFh                        ; 6BCD
int_serial_tbl_2:       DB  001h,001h,000h,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  001h,001h,0FFh,001h,001h,001h,0FFh,001h
                DB  001h,001h,001h,001h,001h,001h,0FFh,001h
                DB  001h,001h,001h,001h,0FFh,0FFh,0FFh,0FFh
                DB  001h,0FFh,001h,0FFh,001h,001h,001h,000h
                DB  000h,001h,000h,001h,001h,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,001h,001h,001h
                DB  001h,001h,001h,001h,0FFh,0FFh,0FFh,0FFh
                DB  000h,001h,001h,001h,001h,001h,001h,001h
                DB  001h,0FFh,001h,001h,001h,0FFh,0FFh,001h
                DB  0FFh,001h,001h,0FFh,001h,001h,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  001h,001h,001h,001h,001h,001h,001h,001h
                DB  001h,001h,001h,001h,001h,001h,001h,001h
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  000h,002h,000h,000h,000h,0FFh,0FFh,0FFh
;@ Stock_idle_init_start_tbl type=u8 count=16 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at idle_init_start_load_ram0f8; its role not traced."
idle_init_start_tbl:       DB  014h,002h,024h,001h,02Ch,0A2h,024h,011h
                DB  024h,051h,000h,000h,000h,000h,025h,0C1h
;@ Stock_idle_init_start_tbl_2 type=u8 count=16 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at idle_init_start_load_ram0f8; its role not traced."
idle_init_start_tbl_2:       DB  000h,000h,000h,000h,000h,000h,024h,021h
                DB  029h,082h,029h,0A2h,024h,0B1h,000h,000h
;@ Stock_idle_init_start_tbl_3 type=u8 count=16 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at idle_init_start_load_ram0f8; its role not traced."
idle_init_start_tbl_3:       DB  025h,012h,025h,002h,025h,072h,025h,062h
                DB  000h,000h,026h,032h,025h,0A0h,000h,000h
;@ Stock_idle_init_start_tbl_4 type=u8 count=16 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at idle_init_start_load_ram0f8; its role not traced."
idle_init_start_tbl_4:       DB  025h,032h,025h,022h,025h,042h,01Ah,012h
                DB  000h,000h,026h,022h,026h,052h,000h,000h
;@ Stock_idle_init_start_tbl_5 type=u8 count=16 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at idle_init_start_load_ram0f8; its role not traced."
idle_init_start_tbl_5:       DB  025h,052h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
;@ Stock_idle_init_start_tbl_6 type=u8 count=16 formula=raw category="Internal" desc="Stock data, 16 bytes, read by the code at idle_init_start_load_ram0f8; its role not traced."
idle_init_start_tbl_6:       DB  01Bh,002h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
dtc_active_confirm_tbl_2:DW  dtc_step_4594                 ; 6CAF
                DW  dtc_step_464F                 ; 6CB1
                DW  dtc_step_459E                 ; 6CB3
                DW  dtc_step_45A9                 ; 6CB5
                DW  dtc_step_4641                 ; 6CB7
                DW  dtc_step_45B2                 ; 6CB9
                DW  dtc_step_45BD                 ; 6CBB
                DW  dtc_step_45C7                 ; 6CBD
                DW  dtc_step_45D4                 ; 6CBF
                DW  dtc_step_45DC                 ; 6CC1
                DW  dtc_step_464F                 ; 6CC3
                DW  dtc_step_45E6                 ; 6CC5
                DW  dtc_step_45FA                 ; 6CC7
                DW  dtc_step_4641                 ; 6CC9
                DW  dtc_step_4641                 ; 6CCB
                DW  dtc_step_4641                 ; 6CCD
                DW  dtc_step_4641                 ; 6CCF
                DW  dtc_step_464F                 ; 6CD1
                DW  dtc_step_464F                 ; 6CD3
                DW  dtc_step_4604                 ; 6CD5
                DW  dtc_step_4641                 ; 6CD7
                DW  dtc_step_4641                 ; 6CD9
                DW  dtc_step_4641                 ; 6CDB
                DW  dtc_step_460E                 ; 6CDD
                DW  dtc_step_4611                 ; 6CDF
                DW  dtc_step_4615                 ; 6CE1
                DW  dtc_step_4621                 ; 6CE3
                DW  dtc_step_464F                 ; 6CE5
                DW  dtc_step_4625                 ; 6CE7
                DW  dtc_step_4631                 ; 6CE9
                DW  dtc_step_4639                 ; 6CEB
                DW  dtc_step_464F                 ; 6CED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6CEF
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ Stock_clamp_result_store_tbl_2 type=u8 count=84 formula=raw category="Internal" desc="Stock data, 84 bytes, read by the code at clamp_result_store_andb_acc; its role not traced."
clamp_result_store_tbl_2:       DB  000h,000h,000h,000h,000h,020h,008h,004h
                DB  001h,004h,00Ch,000h,001h,008h,00Ch,000h
                DB  001h,002h,00Ch,000h,002h,001h,00Ch,003h
                DB  002h,001h,01Ch,003h,003h,004h,00Ch,002h
                DB  003h,008h,00Ch,002h,003h,002h,00Ch,002h
                DB  003h,020h,008h,004h,004h,001h,00Ch,000h
                DB  000h,001h,004h,000h,000h,001h,014h,000h
                DB  000h,001h,004h,000h,000h,001h,00Ch,002h
                DB  000h,001h,01Ch,002h,000h,001h,004h,000h
                DB  002h,004h,00Ch,003h,002h,008h,00Ch,003h
                DB  002h,020h,008h,005h ; 6D4F
;@ Stock_rom_6d53 type=u8 count=3 formula=raw category="Internal" desc="Stock data, 3 bytes, read by the code at serial_cmd_4E90; its role not traced."
rom_6d53:       DB  003h,093h,0F0h ; 6D53
;@ Stock_clamp_result_store_tbl_3 type=u8 count=26 formula=raw category="Internal" desc="Stock data, 26 bytes, read by the code at clamp_result_store_addb_acc; its role not traced."
clamp_result_store_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,012h,013h,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh
to_set_pswl4_flag_b_sub_call_4880:     CAL     o2_trim_dp300_read_sub_clear_x1
                LB      A, #041h
                JBS     off(0012fh).7, to_set_pswl4_flag_b_sub_cmp_ram0df
                LB      A, #03eh
to_set_pswl4_flag_b_sub_cmp_ram0df:     CMPB    0dfh, A
                MB      off(0012fh).7, C
                RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
to_set_pswl4_flag_b_sub_if_ram11f_bit3_clr:     JBR     off(0011fh).3, to_set_pswl4_flag_b_sub_cmp_acc
                MOV     er2, #0ffffh
                JBS     off(00120h).0, to_set_pswl4_flag_b_sub_cmp_acc
                MOV     er2, #006f7h
to_set_pswl4_flag_b_sub_cmp_acc:     CMPB    A, off(00178h)
                JGT     to_set_pswl4_flag_b_sub_goto_4775
                J       to_set_pswl4_flag_b_sub_load_er2
to_set_pswl4_flag_b_sub_goto_4775:     J       to_set_pswl4_flag_b_sub_load_ram166
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
to_set_pswl4_flag_b_sub_cmp_r0:     CMPB    r0, off(00179h)
                JGT     to_set_pswl4_flag_b_sub_goto_4775_2
                JBS     off(0012fh).7, to_set_pswl4_flag_b_sub_goto_4775_2
                J       o2trim_add_clamp
to_set_pswl4_flag_b_sub_goto_4775_2:     J       to_set_pswl4_flag_b_sub_load_ram166
                DW  0ffffh
knockretard_store_if_lt_goto_6dca:     JLT     knockretard_store_goto_2419
                CMPB    r0, #000h
                JEQ     knockretard_store_goto_2419
                J       knockretard_store_goto_6e90
knockretard_store_goto_2419:     J       knockretard_store_store_ram2ae
                DB  0FFh,0FFh,0FFh
sensor_bank_gate3_if_ram216_bit1_set:     JBS     off(00216h).1, sensor_bank_gate3_goto_16b7
                LB      A, #005h
                CMPB    A, 0dfh
                JGE     sensor_bank_gate3_goto_16a8
                MOV     X1, #rom_53db
                JBS     off(0021dh).1, sensor_bank_gate3_load_ram289
                MOV     X1, #rom_53cf
sensor_bank_gate3_load_ram289:     LB      A, off(00289h)
                VCAL    0
                ADDB    A, #020h
                JGE     sensor_bank_gate3_cmp_acc_3
                LB      A, #0ffh
sensor_bank_gate3_cmp_acc_3:     CMPB    A, off(00288h)
                JGE     sensor_bank_gate3_goto_16b7
sensor_bank_gate3_goto_16a8:     J       sensor_bank_gate3_load_imm
sensor_bank_gate3_goto_16b7:     J       sensor_bank_gate3_clear_carry
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh
vtec_state_store_set_carry:     SC
                LB      A, off(001b4h)
                JNE     vtec_state_store_store_carry_ram11d_bit2
                RC
vtec_state_store_store_carry_ram11d_bit2:     MB      off(0011dh).2, C
                LB      A, 0efh
                MOV     DP, #tbl_6a63
                J       vtec_state_store_load_x1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
knockretard_store_if_ram216_bit5_clr:     JBR     off(00216h).5, knockretard_store_goto_2457
                JBS     off(0021dh).2, knockretard_store_goto_2457
                J       knockretard_store_clear_acc
knockretard_store_goto_2457:     J       knockretard_store_store_ram2b0
                DB  0FFh,0FFh,0FFh,0FFh
overrev_hardcap_compare_if_ram216_bit6_set:     JBS     off(00216h).6, overrev_hardcap_compare_goto_1314
                JBS     off(0021dh).2, overrev_hardcap_compare_goto_1314
                J       overrev_hardcap_compare_cmp_ram2ce
overrev_hardcap_compare_goto_1314:     J       overrev_hardcap_compare_load_ram2ce
                DB  0FFh,0FFh,0FFh,0FFh
knockretard_store_if_ram21d_bit2_clr:     JBR     off(0021dh).2, knockretard_store_goto_23d8
                RB      off(00230h).5
                J       knockretard_store_goto_4f3e
knockretard_store_goto_23d8:     J       knockretard_store_load_ram289
                DB  0FFh,0FFh,0FFh,0FFh
sensor_bank_gate3_clear_acc:     CLR     A
                CMPB    off(00295h), off(00289h)
                JLE     sensor_bank_gate3_if_ram230_bit4_clr
                JBS     off(00224h).2, sensor_bank_gate3_goto_162b
sensor_bank_gate3_if_ram230_bit4_clr:     JBR     off(00230h).4, sensor_bank_gate3_goto_162b
                J       sensor_bank_gate3_if_ram211_bit1_set
sensor_bank_gate3_goto_162b:     J       sensor_bank_gate3_store_ram280
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh
fuelcuttrack_store_sub_load_x1:     MOV     X1, #fuelcuttrack_store_tbl_2
                JBS     off(0011dh).1, fuelcuttrack_store_sub_return
                MOV     X1, #fuelcuttrack_store_tbl
fuelcuttrack_store_sub_return:     RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
knockretard_store_addb_acc:     ADDB    A, off(00281h)
                JLT     knockretard_store_load_imm_3
                SRAB    A
                ROLB    A
                JGE     knockretard_store_vcal_7_2
knockretard_store_load_imm_3:     LB      A, #07fh
knockretard_store_vcal_7_2:     VCAL    7
                J       knockretard_store_store_ram2ae
                DW  0ffffh
knockretard_store_clear_ram230_bit5:     RB      off(00230h).5
                LB      A, #004h
                MB      C, (00128h-00180h)[USP].1
                JLT     knockretard_store_store_ram29c
                LB      A, #007h
                JBS     off(0021ah).6, knockretard_store_store_ram29c
                LB      A, #009h
                CMPB    off(00289h), #098h
                JGE     knockretard_store_store_ram29c
                LB      A, #005h
                CMPB    off(00289h), #050h
                JGE     knockretard_store_store_ram29c
                LB      A, #003h
knockretard_store_store_ram29c:     STB     A, off(0029ch)
                J       knockretard_store_load_r0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh
knock_div_calc4_if_ram21d_bit0_set:     JBS     off(0021dh).0, knock_div_calc4_goto_1a9c
                JBR     off(0021dh).2, knock_div_calc4_goto_1aa2
knock_div_calc4_goto_1a9c:     J       knock_div_calc4_load_imm
knock_div_calc4_goto_1aa2:     J       knock_div_calc4_load_ram2ed
                DB  0FFh,0FFh,0FFh,0FFh
transit_flag_common_sub_load_dp:     MOV     DP, #00348h
                SB      off(00232h).6
                RT
transit_flag_common_clear_ram232_bit6:     RB      off(00232h).6
                J       transit_flag_common_return
int_break_set_ram232_bit6:     SB      off(00232h).6
                JNE     int_break_goto_08f6
                MOV     DP, #00332h
                J       int_break_clear_dp_ind
int_break_goto_08f6:     J       int_break_load_dp_2
int_break_sub_clear_ram232_bit6:     RB      off(00232h).6
                MOV     LRB, #00011h
                RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
dtc_active_confirm_vcal_4:     VCAL    4
                MOV     DP, #00334h
                J       dtc_active_confirm_load_x1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh
injector_effective_pw_skip_if_ram11a_bit1_clr:     JBR     off(0011ah).1, injector_effective_pw_skip_if_ram11d_bit0_clr
                J       injector_effective_pw_skip_subb_acc
injector_effective_pw_skip_if_ram11d_bit0_clr:     JBR     off(0011dh).0, injector_effective_pw_skip_goto_35c2
                ADDB    A, #020h
                JGE     injector_effective_pw_skip_goto_35c2
                LB      A, #0ffh
injector_effective_pw_skip_goto_35c2:     J       injector_effective_pw_skip_cmp_acc_8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
vss_clamp_common_load_ram210:     L       A, off(00210h)
                JNE     vss_clamp_common_goto_37d5
                L       A, off(00212h)
                AND     A, #074fdh
                JNE     vss_clamp_common_goto_37d5
                J       vss_clamp_common_cmp_ram0d9
vss_clamp_common_goto_37d5:     J       vss_clamp_common_clear_ram229_bit4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
injector_effective_pw_skip_if_ram121_bit0_set:     JBS     off(00121h).0, injector_effective_pw_skip_if_ram112_bit5_clr
                J       injector_effective_pw_skip_andb_r0
injector_effective_pw_skip_if_ram112_bit5_clr:     JBR     off(00112h).5, injector_effective_pw_skip_goto_35db
                JBS     off(0012eh).7, injector_effective_pw_skip_set_ram11d_bit1_2
injector_effective_pw_skip_goto_35db:     J       injector_effective_pw_skip_load_ram110
injector_effective_pw_skip_set_ram11d_bit1_2:     SB      off(0011dh).1
                RB      off(0011ah).1
                J       injector_effective_pw_skip_load_dp
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
vemapscalar_gate_if_ram212_bit5_set:     JBS     off(00212h).5, vemapscalar_gate_goto_153e
                JBR     off(0021dh).1, vemapscalar_gate_goto_153e
                J       vemapscalar_gate_call_add24_clamp_neg1
vemapscalar_gate_goto_153e:     J       vemapscalar_gate_load_x1
vemapscalar_gate_if_ram212_bit5_set_2:     JBS     off(00212h).5, vemapscalar_gate_goto_156c
                JBR     off(0021dh).1, vemapscalar_gate_goto_156c
                J       vemapscalar_gate_call_4977
vemapscalar_gate_goto_156c:     J       vemapscalar_gate_load_x1_2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
calchecksum_loop_sub_div_acc:     DIV
                DIV
                J       calchecksum_loop_sub_load_dp
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh
crank_sync_flag_high_if_ram111_bit0_clr:     JBR     off(00111h).0, crank_sync_flag_high_goto_02b0
                RB      off(0011ah).7
                J       crank_sync_flag_high_load_ram13c
crank_sync_flag_high_goto_02b0:     J       crank_sync_flag_high_clear_trnsit_bit6
                DB  0FFh,0FFh,0FFh,0FFh
ofc_enable_check_load_ram1f3:     LB      A, off(001f3h)
                JEQ     ofc_enable_check_goto_2f03
                SB      off(0011bh).3
                J       fuelcuttrack_store_clear_pswl_bit4
ofc_enable_check_goto_2f03:     J       revlimiter_fuelcut_set_if_ram12d_bit7_set
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh
tipin_gate_common_if_ram130_bit6_set:       JBS     off(00130h).6, tipin_gate_common_goto_2c96
                JBS     off(00130h).4, tipin_gate_common_goto_2ca8
tipin_gate_common_goto_2c96:     J       tipin_gate_common_if_ram11c_bit6_set
tipin_gate_common_goto_2ca8:     J       tipin_gate_common_set_ram131_bit0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh
warmcold_tm2_check_set_ram09f_bit4:     SB      09fh.4
                RB      09bh.2
                J       warmcold_tm2_check_store_ram294
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
idle_temp_hyst3_cmp_ram298:     CMPB    off(00298h), #000h
                JEQ     idle_temp_hyst3_sra_acc
                J       idle_temp_hyst3_add_acc
idle_temp_hyst3_decb_ram298:     DECB    off(00298h)
                JLT     idle_temp_hyst3_load_imm_5
idle_temp_hyst3_sra_acc:     SRA     A
                ROL     A
                JGE     idle_temp_hyst3_goto_3c64
idle_temp_hyst3_load_imm_5:     L       A, #07fffh
idle_temp_hyst3_goto_3c64:     J       idle_temp_hyst3_store_ram284
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh
idle_temp_hyst3_load_er1:     L       A, er1
                JLT     idle_temp_hyst3_load_imm_6
                J       idle_temp_hyst3_add_acc_2
idle_temp_hyst3_if_lt_goto_705f:     JLT     idle_temp_hyst3_load_imm_6
                SRA     A
                ROL     A
                JGE     idle_temp_hyst3_goto_403a
idle_temp_hyst3_load_imm_6:     L       A, #07fffh
idle_temp_hyst3_goto_403a:     J       idle_temp_hyst3_load_x1_5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh
overrev_hardcap_compare_if_ram212_bit0_set:     JBS     off(00212h).0, overrev_hardcap_compare_goto_144c
                MB      C, 098h.1
                JLT     overrev_hardcap_compare_goto_144c
                J       overrev_hardcap_compare_if_ram216_bit1_set
overrev_hardcap_compare_goto_144c:     J       overrev_hardcap_compare_set_ram216_bit2
                DW  0ffffh
int_crank_task_if_ram110_bit7_clr:     JBR     off(00110h).7, int_crank_task_goto_024b
                SB      off(00127h).4
                J       int_crank_task_load_ram0bc_2
int_crank_task_goto_024b:     J       int_crank_task_clear_trnsit_bit7
                DB  0FFh,0FFh,0FFh,0FFh
tipin_gate_common_sub_store_carry_ram11d_bit5:     MB      off(0011dh).5, C
                JBS     off(0011fh).5, tipin_gate_common_sub_store_carry_ram11c_bit5
                MB      C, off(0011ch).4
tipin_gate_common_sub_store_carry_ram11c_bit5:     MB      off(0011ch).5, C
                RT
                DB  0FFh,0FFh,0FFh
idle_temp_hyst3_sub_add_acc:     ADD     A, off(00248h)
                SRA     A
                ROL     A
                JGE     idle_temp_hyst3_sub_store_er2
                L       A, #07fffh
idle_temp_hyst3_sub_store_er2:     ST      A, er2
                RT
idle_temp_hyst3_if_ge_goto_70b0:     JGE     idle_temp_hyst3_vcal_7
                L       A, #07fffh
idle_temp_hyst3_vcal_7:     VCAL    7
                ST      A, er2
                J       idle_temp_hyst3_load_ram244
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh
rpm_decel_limit_check_if_ram230_bit1_set:     JBS     off(00230h).1, rpm_decel_limit_check_goto_20dc
                RC
                LB      A, off(002bah)
                JEQ     rpm_decel_limit_check_goto_20dc
                CMPCB   A, rom_20d9
rpm_decel_limit_check_goto_20dc:     J       rpm_decel_limit_check_store_carry_ram223_bit5
                DB  0FFh
crankfuel_clamp_max_clear_x1:     CLR     X1
                MOVB    r1, #004h
                RB      TRNSIT.3
                J       crankfuel_clamp_max_srlb_r0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
vss_ect_gate_load_r4:     MOVB    r4, #032h
                JBR     off(0021bh).1, vss_ect_gate_load_ram2f1
                JBR     off(00217h).0, vss_ect_gate_load_ram2f1
                J       vss_ect_gate_load_ram2d6
vss_ect_gate_load_ram2f1:     MOVB    off(002f1h), r4
                J       idle_stage_alt_start
vss_ect_gate_if_ram218_bit0_clr:     JBR     off(00218h).0, vss_ect_gate_load_ram2f1_2
                J       vss_ect_gate_goto_711d
vss_ect_gate_load_ram2f1_2:     MOVB    off(002f1h), r4
                J       vss_ect_gate_load_ram2d3
vss_ect_gate_load_stk:     L       A, (00160h-00180h)[USP]
                CMPC    A, rom_17a8
                JGE     vss_ect_gate_nop_acc
                CMPC    A, rom_17ad
                JGT     vss_ect_gate_load_ram2f1_3
vss_ect_gate_nop_acc:     NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                CMPB    0d9h, #03ch
                JLE     vss_ect_gate_goto_17eb
                LB      A, off(002f1h)
                JNE     vss_ect_gate_goto_17b1
vss_ect_gate_goto_17eb:     J       idle_stage_c0_load_clear_ram218_bit0
vss_ect_gate_load_ram2f1_3:     MOVB    off(002f1h), r4
vss_ect_gate_goto_17b1:     J       vss_ect_gate_load_r3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ Stock_vcal_4_tbl type=u16 count=4 formula=raw category="Internal" desc="Stock data, 8 bytes, read by the code at vcal_4_load_imm; its role not traced."
vcal_4_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh
vss_clamp_common_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,000h
                org     07fffh
checksum_fix:   checksum                ; 7FFF: set by the assembler so the 8-bit sum of the image is 0 (what the ROM checks: at boot and in the background)