;==================================================================================================
; p13.asm -- fully annotated listing (labels/comments only; firmware bytes unchanged)
; Built in two passes (see ANNOTATION_REPORT.md and p13_manual_notes.txt):
;  1) reference pass: label names + [H]/[CG]/[N]/[HD2]/[P30]/[P08]/[HTS120] comments transferred
;     from HTS115.asm / CromeGold / Neptune / HD2 / p30 / p08-911-243 / HTS.120 onto matched code;
;     unmatched labels got structural <context>_<action> names.
;  2) manual pass (this header, and comments tagged [flow]/[info]): p13 itself was followed from the
;     vectors through the supervisor, background tasks and map engines. Untagged/[flow] comments are
;     verified against THIS ROM; claims taken from p13info.txt are quoted with their [info] tags and
;     marked (p13info ...) -- two of them needed corrections (652E vs 642E; 2EAC is an immediate).
; Verified: assembles with asm662 byte-identical to the raw listing.
; Naming: this is an MSM66911. SFRs, vectors and the labels built from them use the 66911 names
;   (OkiRomSim ProcessorProfile.Msm66911), declared as EQUs below so the bytes do not depend on the
;   assembler's built-in SFR set. Comments tagged [H]/[CG]/[N]/[HD2]/[P30]/[P08] were carried over from
;   66207 ROMs; where one names a 66207 register or pin (P4.1, ADCR6, SRSTAT...), the code is right.
;
; RAM map (verified uses; raw addresses stay numeric in the code):
;   09Bh      output latch: bit0 MIL(CEL), bit1 shift-light-style output [p13info CEL @1A4B]
;   0A4h      MAP sensor ADC word                  [p13info 0A4]
;   0ABh      TPS raw ADC byte (scaled -> 0178h)   [p13info 0AB]
;   0AEh      RPM word (FFFFh = invalid/no signal) [p13info 0AE]
;   0C6h/0CAh/0CCh  interpolated scalars: 0C6 MAP column, 0CA lo-cam RPM, 0CC hi-cam RPM
;   0D8h      IAT scaled (fault default 086h)      [HTS115-equiv]
;   0D9h      ECT scaled (fault default 062h; hot flags vs 61h/65h) [p13info 0D9 ?? -> confirmed]
;   0DBh      temperature-ish byte (MIL warm-up gate 07Dh) ; raw = 03D7h
;   0DCh      battery voltage (raw ADCR2H copy; "ADCR6h" in 66207 naming)
;   0DFh      VSS km/h                             [p13info 0DF]
;   0EAh/0ECh/0EDh/0EEh/0EFh  table indices: 0ED=column(MAP), 0EE=row lo-cam, 0EF=row hi-cam
;   0E3h/0E5h/0E6h/0E8h/0E9h/0E0h  sensor deltas / defaults region
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
; ROM map / tweak points (see [info] block comments at the addresses):
;   0C1E/0C23 rev-limit boot defaults (immediates @0C21 FAh resume, @0C26 F4h cut) [p13info]
;  [info/p13info+verified] checksum watchdog. The loop at 0D06 adds ROM words (X1) into 00000h[X2],
;    result stored via 0D12, pass counter 03A6h counts 0200h sweeps; after the last pass this
;    reads LCB A,07FF1h. 0x7FF1 is BEYOND the programmed ROM (image ends 07FF0) so it reads 0.
;    p13info patch: replace bytes 909DF17F (@0D22) with 03360D00 (= J 0D36 + NOP) to skip the
;    flag test entirely and disable checksum enforcement. Same 0x7FF0/7FF1/7FF2 'factory/debug'
;    flags' are read at 0F6F/0F76/0A1D/1918/1962/19E7/19F5/1A32... (all read 0 on a stock EPROM).
;   0D22  checksum flag read LCB A,07FF1h; p13info patch 909DF17F -> 03360D00 disables checksum
;  [flow] rev-limit source select. 0218h.5 mirrors (0D9h ECT >= 61h/65h) hot/cold. Two limit-word
;    pairs feed the engage code at 2E7A: pair @5403/5407 (012Ah/0120h, selected when 0212h.5 set)
;    and pair @540B/540F (00FAh/00F4h, the default; also the boot immediates). Words go through
;    add24_clamp_neg1 (CAL 4983), results land in 016Ch (resume) and 016Ah (cut) as 16-bit words.
;    p13info names these low-cam(5403/5407) / high-cam(540B/540F); 02D0h is a 1Eh-tick recheck timer.
;   1520  rev-limit pair select (ECT hot/cold + 0212h.5); p13info '2-step @157D' = the store path
;  [flow] MIL / shift-light condition mixers (p13info 'CEL stuff @1A4B' -> this block).
;    Output-latch byte 09Bh: bit0 and bit1 are written from combinations of fault flag bits
;    (0216h.1, 0213h.0/.1, 02Fh.3/.4), A/C input 0224h.3, all gated by 0DBh < 07Dh (warm-up inhibit).
;    09Bh.2 is written by the ign code (280C) and consumed at 7023.
;   1A3F  MIL/shift-light mixers (p13info 'CEL @1A4B')    1B4D A/C cut (p13info 'AC @1B4D')
;  [flow] MAP sensor limit check (p13info 'Map sensor check @1F57'). 0A4h is the MAP ADC word;
;    SWAP takes the HIGH byte: > A1h sets 098h.0 (boost-range/high-pressure side -> boost-code hook),
;    < 0Bh = below atmospheric (vacuum side). 0ABh raw TPS is scaled to TPS% via the 2-word scale
;    pair tbl_tps_5736 (VCAL 2) -> 0178h. 0E5h/0E6h latch TPS-delta limits; 370h..37Ch[USP] summed
;    at 1FAD is the injector-duty/pulse accumulator.
;   1F57  MAP boost-range check (p13info 'boost @1F57')   2EA9 speed limiter (immediate @2EAC=FFh off)
;   5403/5407, 540B/540F  rev-limit word pairs           5441h knock handler pointer words
;  [info] ===== calibration map area (ROM) =====  (p13info ROM list, checked against the code)
;    6000  tbl_rpm_scalar_lo40   40 x 16b  low-cam RPM/rev scalar row (p13info 'Low Cam Rev Scalar')
;    6028  tbl_rpm_scalar_hi40   40 x 16b  high-cam row; scalar -> 0CCh, row index -> 0EFh
;    6050  tbl_map_axis_mbar10   10 x  8b  MAP column axis raw-ADC scale (p13info 6050 mBar) -> 0EDh
;    605A/6082  40 x 16b each    low/high cam fuel row multipliers (p13info 605A/6082, 'multiplier?')
;    60AA  tbl_fuel_lo_cam       200 B     low-cam fuel map 10 col x 20 row -> base fuel 0193h
;    6172  tbl_fuel_hi_cam       200 B     high-cam fuel map
;    623A/62A8  110 B each       80h-based correction maps (p13info 'extra tables', real dips to 77h)
;    6316/6384  110 B each       all-80h correction maps (disabled, p13info 'all 80s')
;    63F8  tbl_ign_lo_cam        200 B     low-cam ignition map  (p13info 63F8)
;    64C0/652E  100 B each       alt low-cam ign tables (p13info said 64C0 & 642E -- 652E in code)
;    659C  tbl_ign_hi_cam        200 B     high-cam ignition map (p13info 659C)
;    6664/66D2  100 B each       alt high-cam ign tables (p13info 6664 & 66D2)
;    681C/688A  all-00 tables    disabled correction maps (p13info 'all 00s')
;    6911  2-word (voltage, value) pairs used as injector pw-vs-battery lookup at 2C44
;    6923/6937  all-FF tables    used as pass-through correction when 011Ch.4/.5 flags set
;    69C6  VTEC duty table  6A46/6A9F knock retard  6AB7 knock handler pointers (== 5441 words)
;    6A77/6A8B  20 B each        80h-based per-cam correction applied to base fuel
;    ====================================================================
;   6000..6B00 calibration maps -- see the [info] table at 6000
;   7FF0h-7FF3h factory/debug flags past the image end (read 0; p13info 'debug @7FF1')
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
int_start_vec:            DW  int_start        ; 0000 8307
int_break_vec:            DW  int_break        ; 0002 8D07
int_WDT_vec:              DW  int_WDT          ; 0004 4807
int_NMI_vec:              DW  int_NMI          ; 0006 5C07
int_ckp_tdc_capture_vec:  DW  int_ckp_tdc_capture; 0008 B201
int_crank_task_vec:       DW  int_crank_task   ; 000A EB01
int_halt_timer_vec:       DW  int_spurious_irq_trap; 000C 4207
int_vss_capture_vec:      DW  int_vss_capture  ; 000E 8101
int_timer_overflow_vec:   DW  int_timer_overflow; 0010 7001
int_pwm0_pin_vec:         DW  int_spurious_irq_trap; 0012 4207
int_pwm0_software_vec:    DW  int_spurious_irq_trap; 0014 4207
int_spare_2B0_vec:        DW  int_spurious_irq_trap; 0016 4207
int_spare_2B4_vec:        DW  int_spurious_irq_trap; 0018 4207
int_pwm1_pin_vec:         DW  int_spurious_irq_trap; 001A 4207
int_tick_10ms_vec:        DW  int_tick_10ms    ; 001C 6C01
int_adc_complete_vec:     DW  int_spurious_irq_trap; 001E 4207
int_serial_vec:           DW  int_serial       ; 0020 4300
int_ignition_oneshot_vec: DW  int_spurious_irq_trap; 0022 4207
int_oneshots_44_4A_vec:   DW  int_spurious_irq_trap; 0024 4207
int_injector_oneshots_vec: DW int_spurious_irq_trap; 0026 4207
vcal_0_vec:               DW  vcal_0           ; 0028 9E43
vcal_1_vec:               DW  vcal_1           ; 002A 0544
vcal_2_vec:               DW  vcal_2           ; 002C DA43
vcal_3_vec:               DW  vcal_3           ; 002E 6B44
vcal_4_vec:               DW  vcal_4           ; 0030 9236
vcal_5_vec:               DW  vcal_5           ; 0032 9F44
vcal_6_vec:               DW  vcal_6           ; 0034 9E44
vcal_7_vec:               DW  vcal_7           ; 0036 8E44
code_start:     DB  004h,03Ch,05Ch,000h ; 0038
int_NMI_set_sbycon_bit0:     SB      SBYCON.0               ; 003C 0 208 ??? C51018
                NOP                            ; 003F 0 208 ??? 00
                J       int_start              ; 0040 0 208 ??? 038307
;  [flow] int_serial: the serial interrupt (Int12, vector 0020h; RX and TX share it - the 66207 name
;    "int_a2d_finished" this listing used to carry is that slot on the other part). It is also the
;    main background-task kick-off.
;    bit 0a0h.7 selects the path: path A (004B, LRB->088) is the small result-collector: it hands the
;    just-converted ACCH channel to the table at 03F0h[X1] and pushes the byte result into STBUF 07Ch
;    (SRBUF is 07Dh, both at 004B path; p13info datalogging note confirmed against this code).
;    path B (00DB, LRB->3B0) runs the background task chain that contains all fuel/ignition math
;    (LRB 100/200/280/3B0 contexts below are all these tasks).
;    Boot normally ends up jumping into this chain via 0040.
int_serial: MB      C, 0a0h.7              ; 0043 0 ??? ??? C5A02F
                JGE     int_serial_load_ie             ; 0046 0 ??? ??? CD03
                J       int_serial_load_ie_2             ; 0048 0 ??? ??? 03DB00
int_serial_load_ie:     L       A, IE                  ; 004B 1 ??? ??? E51A
                PUSHS   A                      ; 004D 1 ??? ??? 55
                MOV     IE, #00001h            ; 004E 1 ??? ??? B51A980100
                SB      PSWH.0                 ; 0053 1 ??? ??? A218
                MOVB    PSWL, #002h            ; 0055 1 ??? ??? A39802
                MOV     LRB, #00011h           ; 0058 1 088 ??? 571100
                MOV     DP, #003f0h            ; 005B 1 088 ??? 62F003
                SB      0a0h.3                 ; 005E 1 088 ??? C5A01B
                LB      A, SRBUF                ; 0061 0 088 ??? F57D
                JBS     off(0007eh).3, int_serial_clear_ram07e_bit3 ; 0063 0 088 ??? EB7E03
                STB     A, [DP]                ; 0066 0 088 ??? D2
                SJ      int_serial_store_ram07c             ; 0067 0 088 ??? CB23
int_serial_clear_ram07e_bit3:     RB      SRSTAT.3                 ; 0069 0 088 ??? C57E0B
                JBS     off(ACC).7, int_serial_store_acch ; 006C 0 088 ??? EF0609
                ANDB    A, #007h               ; 006F 0 088 ??? D607
                STB     A, ACCH                ; 0071 0 088 ??? D507
                LB      A, [DP]                ; 0073 0 088 ??? F2
                MOV     DP, A                  ; 0074 0 088 ??? 52
                LB      A, [DP]                ; 0075 0 088 ??? F2
                SJ      int_serial_store_ram07c             ; 0076 0 088 ??? CB14
int_serial_store_acch:     STB     A, ACCH                ; 0078 0 088 ??? D507
                ANDB    A, #0f0h               ; 007A 0 088 ??? D6F0
                CMPB    A, #0a0h               ; 007C 0 088 ??? C6A0
                JNE     int_serial_store_ram07c             ; 007E 0 088 ??? CE0C
                LB      A, ACCH                ; 0080 0 088 ??? F507
                ANDB    A, #007h               ; 0082 0 088 ??? D607
                CLRB    ACCH                   ; 0084 0 088 ??? C50715
                MOV     X1, A                  ; 0087 0 088 ??? 50
                LB      A, [DP]                ; 0088 0 088 ??? F2
                STB     A, 003f1h[X1]          ; 0089 0 088 ??? D0F103
int_serial_store_ram07c:     STB     A, STBUF                ; 008C 0 088 ??? D57C
                POPS    A                      ; 008E 1 088 ??? 65
                RB      PSWH.0                 ; 008F 1 088 ??? A208
                ST      A, IE                  ; 0091 1 088 ??? D51A
                RTI                            ; 0093 1 088 ??? 02
                DB  0C5h,0A0h,02Fh,0CDh,003h,003h,0DBh,000h ; 0094
                DB  0E5h,01Ah,055h,0B5h,01Ah,098h,001h,000h ; 009C
                DB  0A2h,018h,0A3h,098h,002h,057h,060h,000h ; 00A4
                DB  0FAh,0C5h,07Eh,00Bh,0C9h,002h,086h,001h ; 00AC
                DB  0C5h,07Eh,00Ah,0C9h,002h,086h,002h,0D5h ; 00B4
                DB  007h,0F5h,07Dh,052h,042h,0C9h,00Ch,063h ; 00BC
                DB  0CAh,00Ch,0E2h,0F5h,006h,0C5h,007h,07Ch ; 00C4
                DB  0A0h,0CBh,004h,062h,0A0h,003h,0F2h,0D5h ; 00CC
                DB  07Ch,065h,0A2h,008h,0D5h,01Ah,002h ; 00D4
int_serial_load_ie_2:     L       A, IE                  ; 00DB 1 ??? ??? E51A
                PUSHS   A                      ; 00DD 1 ??? ??? 55
                MOV     LRB, #00076h           ; 00DE 1 3B0 ??? 577600
                MOVB    PSWL, #002h            ; 00E1 1 3B0 ??? A39802
                MOV     IE, #00001h            ; 00E4 1 3B0 ??? B51A980100
                SB      PSWH.0                 ; 00E9 1 3B0 ??? A218
                JBS     off(003bch).0, int_serial_clear_ram3bc_bit1 ; 00EB 1 3B0 ??? E8BC02
                SJ      int_serial_load_r0             ; 00EE 1 3B0 ??? CB33
int_serial_clear_ram3bc_bit1:     RB      off(003bch).1          ; 00F0 1 3B0 ??? C4BC09
                JEQ     int_serial_cmp_r5             ; 00F3 1 3B0 ??? C905
                RB      off(003bch).0          ; 00F5 1 3B0 ??? C4BC08
                SJ      int_serial_goto_0166             ; 00F8 1 3B0 ??? CB26
int_serial_cmp_r5:     CMPB    r5, #002h              ; 00FA 1 3B0 ??? 25C002
                JNE     int_serial_load_r5             ; 00FD 1 3B0 ??? CE05
                LB      A, r2                  ; 00FF 0 3B0 ??? 7A
                STB     A, STBUF                ; 0100 0 3B0 ??? D57C
                SJ      int_serial_addb_acc             ; 0102 0 3B0 ??? CB10
int_serial_load_r5:     LB      A, r5                  ; 0104 0 3B0 ??? 7D
                CMPB    A, r2                  ; 0105 0 3B0 ??? 4A
                JGT     int_serial_goto_0166             ; 0106 0 3B0 ??? C818
                JEQ     int_serial_set_ram3bc_bit1             ; 0108 0 3B0 ??? C90E
                LB      A, off(003bah)         ; 010A 0 3B0 ??? F4BA
                CAL     int_serial_sub_cmp_acc             ; 010C 0 3B0 ??? 32F44B
                INCB    off(003bah)            ; 010F 0 3B0 ??? C4BA16
                STB     A, STBUF                ; 0112 0 3B0 ??? D57C
int_serial_addb_acc:     ADDB    A, r6                  ; 0114 0 3B0 ??? 0E
                STB     A, r6                  ; 0115 0 3B0 ??? 8E
                SJ      int_serial_incb_r5             ; 0116 0 3B0 ??? CB07
int_serial_set_ram3bc_bit1:     SB      off(003bch).1          ; 0118 0 3B0 ??? C4BC19
                CLRB    A                      ; 011B 0 3B0 ??? FA
                SUBB    A, r6                  ; 011C 0 3B0 ??? 2E
                STB     A, STBUF                ; 011D 0 3B0 ??? D57C
int_serial_incb_r5:     INCB    r5                     ; 011F 0 3B0 ??? AD
int_serial_goto_0166:     J       int_serial_clear_pswh_bit0             ; 0120 1 3B0 ??? 036601
int_serial_load_r0:     MOVB    r0, SRBUF               ; 0123 1 3B0 ??? C57D48
                LB      A, r7                  ; 0126 0 3B0 ??? 7F
                JNE     int_serial_cmp_r5_2             ; 0127 0 3B0 ??? CE0B
                MOVB    off(003b9h), r1        ; 0129 0 3B0 ??? 217CB9
                MOVB    r1, r0                 ; 012C 0 3B0 ??? 2049
                MOVB    r6, r0                 ; 012E 0 3B0 ??? 204E
                MOVB    r5, #001h              ; 0130 0 3B0 ??? 9D01
                SJ      int_serial_load_r7             ; 0132 0 3B0 ??? CB1E
int_serial_cmp_r5_2:     CMPB    r5, #001h              ; 0134 0 3B0 ??? 25C001
                JNE     int_serial_load_r2             ; 0137 0 3B0 ??? CE04
                MOVB    r2, r0                 ; 0139 0 3B0 ??? 204A
                SJ      int_serial_load_r0_2             ; 013B 0 3B0 ??? CB11
int_serial_load_r2:     LB      A, r2                  ; 013D 0 3B0 ??? 7A
                SUBB    A, #001h               ; 013E 0 3B0 ??? A601
                CMPB    A, r5                  ; 0140 0 3B0 ??? 4D
                JEQ     int_serial_load_r6             ; 0141 0 3B0 ??? C913
                CMPB    r5, #002h              ; 0143 0 3B0 ??? 25C002
                JNE     int_serial_load_r4             ; 0146 0 3B0 ??? CE04
                MOVB    r3, r0                 ; 0148 0 3B0 ??? 204B
                SJ      int_serial_load_r0_2             ; 014A 0 3B0 ??? CB02
int_serial_load_r4:     MOVB    r4, r0                 ; 014C 0 3B0 ??? 204C
int_serial_load_r0_2:     LB      A, r0                  ; 014E 0 3B0 ??? 78
                ADDB    r6, A                  ; 014F 0 3B0 ??? 2681
                INCB    r5                     ; 0151 0 3B0 ??? AD
int_serial_load_r7:     MOVB    r7, #002h              ; 0152 0 3B0 ??? 9F02
                SJ      int_serial_clear_pswh_bit0             ; 0154 0 3B0 ??? CB10
int_serial_load_r6:     LB      A, r6                  ; 0156 0 3B0 ??? 7E
                ADDB    A, r0                  ; 0157 0 3B0 ??? 08
                JNE     int_serial_clear_r7             ; 0158 0 3B0 ??? CE0A
                LB      A, r1                  ; 015A 0 3B0 ??? 79
                ANDB    A, #0e0h               ; 015B 0 3B0 ??? D6E0
                CMPB    A, #020h               ; 015D 0 3B0 ??? C620
                JNE     int_serial_clear_r7             ; 015F 0 3B0 ??? CE03
                SB      off(003bch).2          ; 0161 0 3B0 ??? C4BC1A
int_serial_clear_r7:     CLRB    r7                     ; 0164 0 3B0 ??? 2715
int_serial_clear_pswh_bit0:     RB      PSWH.0                 ; 0166 1 3B0 ??? A208
                POPS    A                      ; 0168 1 3B0 ??? 65
                ST      A, IE                  ; 0169 1 3B0 ??? D51A
                RTI                            ; 016B 1 3B0 ??? 02
int_tick_10ms: SB      09eh.3                 ; 016C 0 ??? ??? C59E1B
                RTI                            ; 016F 0 ??? ??? 02
int_timer_overflow: RB      09eh.1                 ; 0170 0 ??? ??? C59E09
                JNE     int_timer_overflow_clear_ram09e_bit2             ; 0173 0 ??? ??? CE03
                INCB    0f7h                   ; 0175 0 ??? ??? C5F716
int_timer_overflow_clear_ram09e_bit2:     RB      09eh.2                 ; 0178 0 ??? ??? C59E0A
                JNE     int_timer_overflow_return             ; 017B 0 ??? ??? CE03
                INCB    0f6h                   ; 017D 0 ??? ??? C5F616
int_timer_overflow_return:     RTI                            ; 0180 0 ??? ??? 02
int_vss_capture: L       A, IE                  ; 0181 1 ??? ??? E51A
                PUSHS   A                      ; 0183 1 ??? ??? 55
                MOV     IE, #00001h            ; 0184 1 ??? ??? B51A980100
                SB      PSWH.0                 ; 0189 1 ??? ??? A218
                L       A, CAP3                ; 018B 1 ??? ??? E55E
                CMP     A, #08000h             ; 018D 1 ??? ??? C60080
                JGE     int_vss_capture_xchg_acc             ; 0190 1 ??? ??? CD0B
                MB      C, IRQ.4               ; 0192 1 ??? ??? C5182C
                JGE     int_vss_capture_xchg_acc             ; 0195 1 ??? ??? CD06
                INCB    0f6h                   ; 0197 1 ??? ??? C5F616
                SB      09eh.2                 ; 019A 1 ??? ??? C59E1A
int_vss_capture_xchg_acc:     XCHG    A, 0b8h                ; 019D 1 ??? ??? B5B810
                ST      A, 0b6h                ; 01A0 1 ??? ??? D5B6
                LB      A, 0f6h                ; 01A2 0 ??? ??? F5F6
                STB     A, 0bah                ; 01A4 0 ??? ??? D5BA
                SB      0a0h.1                 ; 01A6 0 ??? ??? C5A019
                CLRB    0f6h                   ; 01A9 0 ??? ??? C5F615
                POPS    A                      ; 01AC 1 ??? ??? 65
                RB      PSWH.0                 ; 01AD 1 ??? ??? A208
                ST      A, IE                  ; 01AF 1 ??? ??? D51A
                RTI                            ; 01B1 1 ??? ??? 02
int_ckp_tdc_capture:       MB      C, TCON.4              ; 01B2 0 ??? ??? C5542C
                JLT     int_ckp_tdc_capture_set_irq_bit1             ; 01B5 0 ??? ??? CA30
                RB      0a0h.5                 ; 01B7 0 ??? ??? C5A00D
                JEQ     int_ckp_tdc_capture_clear_ram0a0_bit6             ; 01BA 0 ??? ??? C90D
                L       A, CAP0                ; 01BC 1 ??? ??? E558
                SUB     A, TIMER               ; 01BE 1 ??? ??? B556A2
                ADD     A, 0c0h                ; 01C1 1 ??? ??? B5C082
                JLT     int_ckp_tdc_capture_store_ignb             ; 01C4 1 ??? ??? CA01
                CLR     A                      ; 01C6 1 ??? ??? F9
int_ckp_tdc_capture_store_ignb:     ST      A, IGNB                ; 01C7 1 ??? ??? D564
int_ckp_tdc_capture_clear_ram0a0_bit6:     RB      0a0h.6                 ; 01C9 1 ??? ??? C5A00E
                JEQ     int_ckp_tdc_capture_load_carry_ram09f_bit5             ; 01CC 1 ??? ??? C90D
                L       A, CAP0                ; 01CE 1 ??? ??? E558
                SUB     A, TIMER               ; 01D0 1 ??? ??? B556A2
                ADD     A, 0beh                ; 01D3 1 ??? ??? B5BE82
                JLT     int_ckp_tdc_capture_store_igna             ; 01D6 1 ??? ??? CA01
                CLR     A                      ; 01D8 1 ??? ??? F9
int_ckp_tdc_capture_store_igna:     ST      A, IGNA                ; 01D9 1 ??? ??? D562
int_ckp_tdc_capture_load_carry_ram09f_bit5:     MB      C, 09fh.5              ; 01DB 1 ??? ??? C59F2D
                JLT     int_ckp_tdc_capture_set_irq_bit1             ; 01DE 1 ??? ??? CA07
                RB      ADSCAN.4                ; 01E0 1 ??? ??? C5660C
                MOVB    ADSCAN, #056h           ; 01E3 1 ??? ??? C5669856
int_ckp_tdc_capture_set_irq_bit1:     SB      IRQ.1                  ; 01E7 1 ??? ??? C51819
                RTI                            ; 01EA 1 ??? ??? 02
int_crank_task:  L       A, IE                  ; 01EB 1 ??? ??? E51A
                PUSHS   A                      ; 01ED 1 ??? ??? 55
                MOV     IE, #00001h            ; 01EE 1 ??? ??? B51A980100
                SB      PSWH.0                 ; 01F3 1 ??? ??? A218
                MOVB    PSWL, #002h            ; 01F5 1 ??? ??? A39802
                MOV     LRB, #00021h           ; 01F8 1 108 ??? 572100
                MOV     USP, #00280h           ; 01FB 1 108 280 A1988002
                L       A, (00214h-00280h)[USP] ; 01FF 1 108 280 E394
                ST      A, off(00114h)         ; 0201 1 108 280 D414
                JBR     off(00114h).7, int_crank_task_load_ram1a0 ; 0203 1 108 280 DF143B
                SB      off(00127h).4          ; 0206 1 108 280 C4271C
                JBS     off(00110h).7, int_crank_task_goto_0738 ; 0209 1 108 280 EF100F
                JBS     off(00110h).3, int_crank_task_load_ram0bc ; 020C 1 108 280 EB1012
                RB      TRNSIT.7                 ; 020F 1 108 280 C5290F
                JEQ     dtc04_ckp_latch             ; 0212 1 108 280 C90A
                RB      09ch.0                 ; 0214 1 108 280 C59C08
                MOVB    off(001a0h), #02dh     ; 0217 1 108 280 C4A0982D
int_crank_task_goto_0738:     J       crank_cycle_er2_store_load_ram11a             ; 021B 1 108 280 033807
dtc04_ckp_latch:     SB      09ch.0                 ; 021E 1 108 280 C59C18
int_crank_task_load_ram0bc:     MOVB    0bch, #000h            ; 0221 1 108 280 C5BC9800
                LB      A, #003h               ; 0225 0 108 280 7703
                RB      TRNSIT.6                 ; 0227 0 108 280 C5290E
                JNE     crank_tooth_count_store             ; 022A 0 108 280 CE0A
                LB      A, off(0013ch)         ; 022C 0 108 280 F43C
                ADDB    A, #006h               ; 022E 0 108 280 8606
                CMPB    A, #018h               ; 0230 0 108 280 C618
                JLT     crank_tooth_count_store             ; 0232 0 108 280 CA02
                LB      A, #003h               ; 0234 0 108 280 7703 ; [HTS120] >= 24) ACCL = 3
crank_tooth_count_store:     STB     A, off(0013ch)         ; 0236 0 108 280 D43C
                RB      P3.3                   ; 0238 0 108 280 C5240B
                CAL     crank_tooth_count_store_sub_clear_ram0a0_bit6             ; 023B 0 108 280 325046
                J       crank_sync_exit_jump_clear_ram12c             ; 023E 0 108 280 033703
int_crank_task_load_ram1a0:     MOVB    off(001a0h), #02dh     ; 0241 1 108 280 C4A0982D
                JBR     off(00127h).3, int_crank_task_clear_trnsit_bit7_2 ; 0245 1 108 280 DB2724
                J       int_crank_task_if_ram110_bit7_clr             ; 0248 1 108 280 038070
int_crank_task_clear_trnsit_bit7:     RB      TRNSIT.7                 ; 024B 1 108 280 C5290F
                JNE     crank_sync_lost_path             ; 024E 1 108 280 CE30
                RB      09fh.2                 ; 0250 1 108 280 C59F0A
                JNE     crank_sync_lost_path             ; 0253 1 108 280 CE2B
int_crank_task_load_ram0bc_2:     LB      A, 0bch                ; 0255 0 108 280 F5BC
                ADDB    A, #001h               ; 0257 0 108 280 8601
                CMPB    A, #006h               ; 0259 0 108 280 C606
                JLT     crank_sync_flag_high_store_ram0bc             ; 025B 0 108 280 CA4E
                JBS     off(00110h).7, int_crank_task_incb_ram0bd ; 025D 0 108 280 EF1006
dtc08_tdc_latch_2: SB      09ch.1                 ; 0260 0 108 280 C59C19
                SB      off(00127h).6          ; 0263 0 108 280 C4271E
int_crank_task_incb_ram0bd:     INCB    0bdh                   ; 0266 0 108 280 C5BD16
                CLRB    A                      ; 0269 0 108 280 FA
                SJ      crank_sync_flag_high_store_ram0bc             ; 026A 0 108 280 CB3F
int_crank_task_clear_trnsit_bit7_2:     RB      TRNSIT.7                 ; 026C 1 108 280 C5290F
                RB      09fh.2                 ; 026F 1 108 280 C59F0A
                RB      TRNSIT.6                 ; 0272 1 108 280 C5290E
                MB      C, 09fh.1              ; 0275 1 108 280 C59F29
                JGE     crank_sync_exit_jump             ; 0278 1 108 280 CD03
                SB      off(00127h).4          ; 027A 1 108 280 C4271C
crank_sync_exit_jump:     J       crank_sync_exit_jump_clear_ram12c             ; 027D 1 108 280 033703
crank_sync_lost_path:     SB      off(00127h).4          ; 0280 1 108 280 C4271C
                RB      off(00127h).6          ; 0283 1 108 280 C4270E
                MOVB    off(001a1h), #02dh     ; 0286 1 108 280 C4A1982D
                L       A, 0bch                ; 028A 1 108 280 E5BC
                CMP     A, #00005h             ; 028C 1 108 280 C60500
                JEQ     crank_sync_flag_high_clear_acc             ; 028F 1 108 280 C917
                SB      off(0011ah).7          ; 0291 1 108 280 C41A1F
                JLT     crank_sync_flag_mid             ; 0294 1 108 280 CA0A
                CMP     A, #00105h             ; 0296 1 108 280 C60501
                JGE     crank_sync_flag_high             ; 0299 1 108 280 CD0A
                SB      09dh.0                 ; 029B 1 108 280 C59D18
                SJ      crank_sync_flag_high_clear_acc             ; 029E 1 108 280 CB08
crank_sync_flag_mid:     SB      off(00127h).5          ; 02A0 1 108 280 C4271D
                SJ      crank_sync_flag_high_clear_acc             ; 02A3 1 108 280 CB03
crank_sync_flag_high:     SB      09dh.1                 ; 02A5 1 108 280 C59D19
crank_sync_flag_high_clear_acc:     CLRB    A                      ; 02A8 0 108 280 FA
                STB     A, 0bdh                ; 02A9 0 108 280 D5BD
crank_sync_flag_high_store_ram0bc:     STB     A, 0bch                ; 02AB 0 108 280 D5BC
                J       crank_sync_flag_high_if_ram111_bit0_clr             ; 02AD 0 108 280 03D06F
crank_sync_flag_high_clear_trnsit_bit6:     RB      TRNSIT.6                 ; 02B0 0 108 280 C5290E
                JNE     crank_sync_flag_high_clear_ram127_bit7             ; 02B3 0 108 280 CE28
crank_sync_flag_high_load_ram13c:     LB      A, off(0013ch)         ; 02B5 0 108 280 F43C
                ADDB    A, #001h               ; 02B7 0 108 280 8601
                CMPB    A, #018h               ; 02B9 0 108 280 C618
                JLT     crank_sync_flag_common_store_ram13c             ; 02BB 0 108 280 CA42
                JBS     off(00111h).0, crank_sync_flag_high_incb_ram13d ; 02BD 0 108 280 E81106
dtc09_cyp_latch: SB      09ch.2                 ; 02C0 0 108 280 C59C1A
                SB      off(00127h).7          ; 02C3 0 108 280 C4271F
crank_sync_flag_high_incb_ram13d:     INCB    off(0013dh)            ; 02C6 0 108 280 C43D16
                CLRB    A                      ; 02C9 0 108 280 FA
                SJ      crank_sync_flag_common_store_ram13c             ; 02CA 0 108 280 CB33
crank_window_flag_check2:     RB      off(00127h).5          ; 02CC 1 108 280 C4270D
                JGE     crank_sync_flag_common_clear_acc             ; 02CF 1 108 280 CD2B
                JEQ     crank_sync_flag_common             ; 02D1 1 108 280 C926
                SB      09dh.0                 ; 02D3 1 108 280 C59D18
                SJ      crank_sync_flag_common_clear_acc             ; 02D6 1 108 280 CB24
crank_sync_flag_low:     SB      09dh.1                 ; 02D8 1 108 280 C59D19
                SJ      crank_sync_flag_common_clear_acc             ; 02DB 1 108 280 CB1F
crank_sync_flag_high_clear_ram127_bit7:     RB      off(00127h).7          ; 02DD 0 108 280 C4270F
                MOVB    off(001a2h), #007h     ; 02E0 0 108 280 C4A29807
                L       A, off(0013ch)         ; 02E4 1 108 280 E43C
                CMP     A, #00017h             ; 02E6 1 108 280 C61700
                JNE     crank_window_flag_check2             ; 02E9 1 108 280 CEE1
                RB      off(00127h).5          ; 02EB 1 108 280 C4270D
                JNE     crank_sync_flag_low             ; 02EE 1 108 280 CEE8
                RB      off(0011ah).7          ; 02F0 1 108 280 C41A0F
                CMPB    0bch, #003h            ; 02F3 1 108 280 C5BCC003
                JEQ     crank_sync_flag_common_clear_acc             ; 02F7 1 108 280 C903
crank_sync_flag_common:     SB      09dh.2                 ; 02F9 1 108 280 C59D1A
crank_sync_flag_common_clear_acc:     CLRB    A                      ; 02FC 0 108 280 FA
                STB     A, off(0013dh)         ; 02FD 0 108 280 D43D
crank_sync_flag_common_store_ram13c:     STB     A, off(0013ch)         ; 02FF 0 108 280 D43C
                JBS     off(00110h).7, crank_tooth_mod6_calc ; 0301 0 108 280 EF1003
                JBR     off(00127h).6, crank_sync_flag_common_if_ram111_bit0_set ; 0304 0 108 280 DE2715
crank_tooth_mod6_calc:     CLR     A                      ; 0307 1 108 280 F9
                MOVB    r0, #006h              ; 0308 1 108 280 9806
                LB      A, off(0013ch)         ; 030A 0 108 280 F43C
                ADDB    A, #003h               ; 030C 0 108 280 8603
                DIVB                           ; 030E 0 108 280 A236
                LB      A, r1                  ; 0310 0 108 280 79
                STB     A, 0bch                ; 0311 0 108 280 D5BC
                JBS     off(00111h).0, crank_tooth_mod6_calc_set_ram11a_bit0 ; 0313 0 108 280 E81103
                JBR     off(00127h).7, crank_sync_flag_common_if_ram111_bit0_set ; 0316 0 108 280 DF2703
crank_tooth_mod6_calc_set_ram11a_bit0:     SB      off(0011ah).0          ; 0319 0 108 280 C41A18
crank_sync_flag_common_if_ram111_bit0_set:     JBS     off(00111h).0, crank_tooth_wrap_calc ; 031C 0 108 280 E81103
                JBR     off(00127h).7, crank_sync_exit_jump_clear_ram12c ; 031F 0 108 280 DF2715
crank_tooth_wrap_calc:     MOVB    r0, #006h              ; 0322 0 108 280 9806
                LB      A, 0bch                ; 0324 0 108 280 F5BC
                ADDB    A, #003h               ; 0326 0 108 280 8603
                SUBB    A, r0                  ; 0328 0 108 280 28
                JGE     crank_tooth_wrap_store             ; 0329 0 108 280 CD01
                ADDB    A, r0                  ; 032B 0 108 280 08
crank_tooth_wrap_store:     STB     A, r2                  ; 032C 0 108 280 8A
                CLR     A                      ; 032D 1 108 280 F9
                LB      A, off(0013ch)         ; 032E 0 108 280 F43C
                DIVB                           ; 0330 0 108 280 A236
                MULB                           ; 0332 0 108 280 A234
                ADDB    A, r2                  ; 0334 0 108 280 0A
                STB     A, off(0013ch)         ; 0335 0 108 280 D43C
crank_sync_exit_jump_clear_ram12c:     CLRB    off(0012ch)            ; 0337 0 108 280 C42C15
                JBS     off(00127h).2, crank_sync_exit_jump_clear_acc ; 033A 0 108 280 EA271B
                LB      A, off(0019dh)         ; 033D 0 108 280 F49D
                JEQ     crank_sync_exit_jump_load_ram0bc             ; 033F 0 108 280 C903
                J       crank_sync_exit_jump_clear_carry             ; 0341 0 108 280 03C603
crank_sync_exit_jump_load_ram0bc:     LB      A, 0bch                ; 0344 0 108 280 F5BC
                JBS     off(00128h).2, crank_sync_exit_jump_if_ram114_bit7_set ; 0346 0 108 280 EA2805
                JNE     crank_sync_exit_jump_clear_carry             ; 0349 0 108 280 CE7B
                SB      off(00128h).2          ; 034B 0 108 280 C4281A
crank_sync_exit_jump_if_ram114_bit7_set:     JBS     off(00114h).7, crank_sync_exit_jump_set_ram127_bit2 ; 034E 0 108 280 EF1404
                CMPB    A, #001h               ; 0351 0 108 280 C601
                JNE     crank_sync_exit_jump_clear_carry             ; 0353 0 108 280 CE71
crank_sync_exit_jump_set_ram127_bit2:     SB      off(00127h).2          ; 0355 0 108 280 C4271A
crank_sync_exit_jump_clear_acc:     CLR     A                      ; 0358 1 108 280 F9
                LB      A, off(0013ch)         ; 0359 0 108 280 F43C
                MOV     X1, A                  ; 035B 0 108 280 50
                LCB     A, crank_sync_exit_jump_tbl[X1]        ; 035C 0 108 280 90ABC357
                STB     A, r2                  ; 0360 0 108 280 8A
                ANDB    A, #003h               ; 0361 0 108 280 D603
                STB     A, r0                  ; 0363 0 108 280 88
                LB      A, r2                  ; 0364 0 108 280 7A
                SWAPB                          ; 0365 0 108 280 83
                ANDB    A, #00fh               ; 0366 0 108 280 D60F
                STB     A, r1                  ; 0368 0 108 280 89
                JNE     crank_sync_exit_jump_if_ram114_bit7_clr             ; 0369 0 108 280 CE04
                ANDB    off(00129h), #0b5h     ; 036B 0 108 280 C429D0B5
crank_sync_exit_jump_if_ram114_bit7_clr:     JBR     off(00114h).7, crank_sync_exit_jump_if_ram129_bit6_set ; 036F 0 108 280 DF1409
                CMPB    A, #00bh               ; 0372 0 108 280 C60B
                JNE     crank_sync_exit_jump_if_ram129_bit6_set             ; 0374 0 108 280 CE05
                RB      off(00129h).6          ; 0376 0 108 280 C4290E
                SJ      crank_sync_exit_jump_load_imm             ; 0379 0 108 280 CB13
crank_sync_exit_jump_if_ram129_bit6_set:     JBS     off(00129h).6, crank_sync_exit_jump_load_imm ; 037B 0 108 280 EE2910
                CMPB    A, off(0019bh)         ; 037E 0 108 280 C79B
                JLT     crank_sync_exit_jump_load_imm             ; 0380 0 108 280 CA0C
                LB      A, r0                  ; 0382 0 108 280 78
                SBR     off(0012ch)            ; 0383 0 108 280 C42C11
                ADDB    A, #004h               ; 0386 0 108 280 8604
                RBR     P3SF                     ; 0388 0 108 280 C52212
                SB      off(00129h).6          ; 038B 0 108 280 C4291E
crank_sync_exit_jump_load_imm:     LB      A, #003h               ; 038E 0 108 280 7703
                CMPB    r1, #006h              ; 0390 0 108 280 21C006
                SBCB    A, r0                  ; 0393 0 108 280 38
                STB     A, off(0019ch)         ; 0394 0 108 280 D49C
                LB      A, r1                  ; 0396 0 108 280 79
                SUBB    A, #006h               ; 0397 0 108 280 A606
                JGE     crank_sync_exit_jump_if_ne_goto_03a3             ; 0399 0 108 280 CD02
                ADDB    A, #00ch               ; 039B 0 108 280 860C
crank_sync_exit_jump_if_ne_goto_03a3:     JNE     crank_sync_exit_jump_if_ram114_bit7_clr_2             ; 039D 0 108 280 CE04
                ANDB    off(00129h), #07ah     ; 039F 0 108 280 C429D07A
crank_sync_exit_jump_if_ram114_bit7_clr_2:     JBR     off(00114h).7, crank_sync_exit_jump_if_ram129_bit7_set ; 03A3 0 108 280 DF1409
                CMPB    A, #00bh               ; 03A6 0 108 280 C60B
                JNE     crank_sync_exit_jump_if_ram129_bit7_set             ; 03A8 0 108 280 CE05
                RB      off(00129h).7          ; 03AA 0 108 280 C4290F
                SJ      crank_sync_exit_jump_clear_carry             ; 03AD 0 108 280 CB17
crank_sync_exit_jump_if_ram129_bit7_set:     JBS     off(00129h).7, crank_sync_exit_jump_clear_carry ; 03AF 0 108 280 EF2914
                CMPB    A, off(0019bh)         ; 03B2 0 108 280 C79B
                JLT     crank_sync_exit_jump_clear_carry             ; 03B4 0 108 280 CA10
                LB      A, r2                  ; 03B6 0 108 280 7A
                ANDB    A, #00ch               ; 03B7 0 108 280 D60C
                SRLB    A                      ; 03B9 0 108 280 63
                SRLB    A                      ; 03BA 0 108 280 63
                SBR     off(0012ch)            ; 03BB 0 108 280 C42C11
                ADDB    A, #004h               ; 03BE 0 108 280 8604
                RBR     P3SF                     ; 03C0 0 108 280 C52212
                SB      off(00129h).7          ; 03C3 0 108 280 C4291F
crank_sync_exit_jump_clear_carry:     RC                             ; 03C6 0 108 280 95
                LB      A, 0bch                ; 03C7 0 108 280 F5BC
                JNE     crank_sync_exit_jump_store_carry_ram12e_bit3             ; 03C9 0 108 280 CE1A
                JBR     off(00127h).4, crank_sync_exit_jump_store_carry_ram12e_bit3 ; 03CB 0 108 280 DC2717
                INCB    off(0019eh)            ; 03CE 0 108 280 C49E16
                JBS     off(00132h).2, crank_sync_exit_jump_store_carry_ram12e_bit3 ; 03D1 0 108 280 EA3211
                CLRB    A                      ; 03D4 0 108 280 FA
                JBR     off(0011ah).6, crank_sync_exit_jump_andb_ram19e ; 03D5 0 108 280 DE1A07
                LB      A, #001h               ; 03D8 0 108 280 7701
                JBR     off(00128h).1, crank_sync_exit_jump_andb_ram19e ; 03DA 0 108 280 D92802
                LB      A, #003h               ; 03DD 0 108 280 7703
crank_sync_exit_jump_andb_ram19e:     ANDB    off(0019eh), A         ; 03DF 0 108 280 C49ED1
                JNE     crank_sync_exit_jump_store_carry_ram12e_bit3             ; 03E2 0 108 280 CE01
                SC                             ; 03E4 0 108 280 85
crank_sync_exit_jump_store_carry_ram12e_bit3:     MB      off(0012eh).3, C       ; 03E5 0 108 280 C42E3B
                LB      A, 0bch                ; 03E8 0 108 280 F5BC
                SLLB    A                      ; 03EA 0 108 280 53
                EXTND                          ; 03EB 1 108 280 F8
                MOV     X1, A                  ; 03EC 1 108 280 50
                MOV     er3, off(00138h)       ; 03ED 1 108 280 B4384B
                L       A, CAP0                ; 03F0 1 108 280 E558
                ST      A, off(00138h)         ; 03F2 1 108 280 D438
                MOVB    r0, 0f7h               ; 03F4 1 108 280 C5F748
                SB      off(00127h).3          ; 03F7 1 108 280 C4271B
                JEQ     rpm_period_reset_loop_clear_ram0f7             ; 03FA 1 108 280 C939
                CMP     A, #08000h             ; 03FC 1 108 280 C60080
                JGE     crank_sync_exit_jump_sub_acc             ; 03FF 1 108 280 CD09
                MB      C, IRQ.4               ; 0401 1 108 280 C5182C
                JGE     crank_sync_exit_jump_sub_acc             ; 0404 1 108 280 CD04
                INCB    r0                     ; 0406 1 108 280 A8
                SB      09eh.1                 ; 0407 1 108 280 C59E19
crank_sync_exit_jump_sub_acc:     SUB     A, er3                 ; 040A 1 108 280 2B
                SBCB    r0, #000h              ; 040B 1 108 280 20B000
                JBR     off(00114h).7, crank_sync_exit_jump_if_eq_goto_0430 ; 040E 1 108 280 DF141C
                CLRB    r1                     ; 0411 1 108 280 2115
                MOV     er2, #00006h           ; 0413 1 108 280 46980600
                DIV                            ; 0417 1 108 280 9037
                CMPB    r0, #000h              ; 0419 1 108 280 20C000
                JEQ     rpm_period_reset_calc             ; 041C 1 108 280 C901
                CLR     A                      ; 041E 1 108 280 F9
rpm_period_reset_calc:     ST      A, off(00136h)         ; 041F 1 108 280 D436
                MOV     X1, #0000ch            ; 0421 1 108 280 600C00
rpm_period_reset_loop:     DEC     X1                     ; 0424 1 108 280 80
                DEC     X1                     ; 0425 1 108 280 80
                ST      A, 00370h[X1]          ; 0426 1 108 280 D07003
                JGT     rpm_period_reset_loop             ; 0429 1 108 280 C8F9
                SJ      rpm_period_reset_loop_clear_ram0f7             ; 042B 1 108 280 CB08
crank_sync_exit_jump_if_eq_goto_0430:     JEQ     crank_sync_exit_jump_store_ram136             ; 042D 1 108 280 C901
                CLR     A                      ; 042F 1 108 280 F9
crank_sync_exit_jump_store_ram136:     ST      A, off(00136h)         ; 0430 1 108 280 D436
                ST      A, 00370h[X1]          ; 0432 1 108 280 D07003
rpm_period_reset_loop_clear_ram0f7:     CLRB    0f7h                   ; 0435 1 108 280 C5F715
                LB      A, off(0013ch)         ; 0438 0 108 280 F43C
                CMPB    A, #002h               ; 043A 0 108 280 C602
                JLT     rpm_period_reset_loop_store_carry_ram131_bit5             ; 043C 0 108 280 CA04
                MOVB    r0, #013h              ; 043E 0 108 280 9813
                CMPB    r0, A                  ; 0440 0 108 280 20C1
rpm_period_reset_loop_store_carry_ram131_bit5:     MB      off(00131h).5, C       ; 0442 0 108 280 C4313D
                LB      A, 0bch                ; 0445 0 108 280 F5BC
                CMPB    A, #005h               ; 0447 0 108 280 C605
                JNE     rpm_period_reset_loop_load_carry_p3_bit3             ; 0449 0 108 280 CE03
                SLLB    off(001b3h)            ; 044B 0 108 280 C4B3D7
rpm_period_reset_loop_load_carry_p3_bit3:     MB      C, P3.3                ; 044E 0 108 280 C5242B
                JLT     rpm_period_reset_loop_load_dp             ; 0451 0 108 280 CA03
                JBR     off(0011ah).5, rpm_period_reset_loop_load_dp_2 ; 0453 0 108 280 DD1A08
rpm_period_reset_loop_load_dp:     MOV     DP, #00004h            ; 0456 0 108 280 620400
rpm_period_reset_loop_nop_acc:     NOP                            ; 0459 0 108 280 00
                JRNZ    DP, rpm_period_reset_loop_nop_acc         ; 045A 0 108 280 30FD
                SJ      crank_a0_update_set_ram09f_bit5             ; 045C 0 108 280 CB3B
rpm_period_reset_loop_load_dp_2:     MOV     DP, #00396h            ; 045E 0 108 280 629603
                MB      C, 09fh.0              ; 0461 0 108 280 C59F28
                JBS     off(001b3h).2, rpm_period_reset_loop_store_carry_pswl_bit4 ; 0464 0 108 280 EAB30F
                MOV     DP, #0038eh            ; 0467 0 108 280 628E03
                MB      C, 09eh.6              ; 046A 0 108 280 C59E2E
                JBR     off(00131h).5, rpm_period_reset_loop_store_carry_pswl_bit4 ; 046D 0 108 280 DD3106
                MOV     DP, #00392h            ; 0470 0 108 280 629203
                MB      C, 09eh.7              ; 0473 0 108 280 C59E2F
rpm_period_reset_loop_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 0476 0 108 280 A33C
                CMPB    A, #005h               ; 0478 0 108 280 C605
                JEQ     crank_a0_update             ; 047A 0 108 280 C911
                CMPB    A, #000h               ; 047C 0 108 280 C600
                JLE     crank_a0_update_set_ram09f_bit5             ; 047E 0 108 280 CF19
                CMPB    A, #004h               ; 0480 0 108 280 C604
                JGE     crank_a0_update_set_ram09f_bit5             ; 0482 0 108 280 CD15
                CMPB    A, 0c4h                ; 0484 0 108 280 C5C4C2
                JGE     crank_a0_update_set_ram09f_bit5             ; 0487 0 108 280 CD10
                CMPB    A, [DP]                ; 0489 0 108 280 C2C2
                JGE     crank_a0_update_set_ram09f_bit5             ; 048B 0 108 280 CD0C
crank_a0_update:     L       A, [DP]                ; 048D 1 108 280 E2
                ST      A, 0c4h                ; 048E 1 108 280 D5C4
                DEC     DP                     ; 0490 1 108 280 82
                LB      A, [DP]                ; 0491 0 108 280 F2
                STB     A, 0c3h                ; 0492 0 108 280 D5C3
                MB      C, PSWL.4              ; 0494 0 108 280 A32C
                MB      off(00132h).1, C       ; 0496 0 108 280 C43239
crank_a0_update_set_ram09f_bit5:     SB      09fh.5                 ; 0499 0 108 280 C59F1D
                JNE     crank_a0_update_load_adcr6             ; 049C 0 108 280 CE1C
                JBR     off(0012eh).3, crank_a0_update_clear_adscan_bit4 ; 049E 0 108 280 DB2E0A
                LB      A, P3                  ; 04A1 0 108 280 F524
                ANDB    A, #0f8h               ; 04A3 0 108 280 D6F8
                XORB    A, #0ffh               ; 04A5 0 108 280 F6FF
                ANDB    A, #00fh               ; 04A7 0 108 280 D60F
                STB     A, P3                  ; 04A9 0 108 280 D524
crank_a0_update_clear_adscan_bit4:     RB      ADSCAN.4                ; 04AB 0 108 280 C5660C
                MB      C, ADSCAN.5             ; 04AE 0 108 280 C5662D
                JGE     crank_a0_update_load_adscan             ; 04B1 0 108 280 CD03
                SB      09fh.4                 ; 04B3 0 108 280 C59F1C
crank_a0_update_load_adscan:     MOVB    ADSCAN, #010h           ; 04B6 0 108 280 C5669810
crank_a0_update_load_adcr6:     L       A, ADCR6               ; 04BA 1 108 280 E574
                ST      A, 0a4h                ; 04BC 1 108 280 D5A4
                CLR     er1                    ; 04BE 1 108 280 4515
                L       A, ADCR7               ; 04C0 1 108 280 E576
                ST      A, er0                 ; 04C2 1 108 280 88
                XCHG    A, 0a6h                ; 04C3 1 108 280 B5A610
                XCHG    A, 0a8h                ; 04C6 1 108 280 B5A810
                CMPB    off(00179h), #0a0h     ; 04C9 1 108 280 C479C0A0
                JGE     crankfuel_clamp_max_load_ram14a             ; 04CD 1 108 280 CD48
                JBR     off(00127h).2, crankfuel_clamp_max_load_ram14a ; 04CF 1 108 280 DA2745
                JBS     off(00114h).7, crankfuel_clamp_max_load_ram14a ; 04D2 1 108 280 EF1442
                JBS     off(00110h).6, crankfuel_clamp_max_load_ram14a ; 04D5 1 108 280 EE103F
                MB      C, 098h.2              ; 04D8 1 108 280 C5982A
                JLT     crankfuel_clamp_max_load_ram14a             ; 04DB 1 108 280 CA3A
                JBS     off(0011dh).0, crankfuel_clamp_max_load_ram14a ; 04DD 1 108 280 E81D37
                JBS     off(00114h).0, crankfuel_clamp_max_load_ram14a ; 04E0 1 108 280 E81434
                JBR     off(0012dh).5, crankfuel_clamp_max_load_ram14a ; 04E3 1 108 280 DD2D31
                SUB     er0, A                 ; 04E6 1 108 280 44A1
                JLE     crankfuel_clamp_max_load_ram14a             ; 04E8 1 108 280 CF2D
                CMP     er0, #00400h           ; 04EA 1 108 280 44C00004
                JLE     crankfuel_clamp_max_load_ram14a             ; 04EE 1 108 280 CF27
                L       A, #031cch             ; 04F0 1 108 280 67CC31
                MUL                            ; 04F3 1 108 280 9035
                MOV     er0, #005a9h           ; 04F5 1 108 280 4498A905
                L       A, er1                 ; 04F9 1 108 280 35
                ADD     A, #000b5h             ; 04FA 1 108 280 86B500
                JLT     crank_a0_update_load_er0             ; 04FD 1 108 280 CA03
                CMP     A, er0                 ; 04FF 1 108 280 48
                JLT     crank_a0_update_load_r1             ; 0500 1 108 280 CA01
crank_a0_update_load_er0:     L       A, er0                 ; 0502 1 108 280 34
crank_a0_update_load_r1:     MOVB    r1, off(00186h)        ; 0503 1 108 280 C48649
                CLRB    r0                     ; 0506 1 108 280 2015
                MUL                            ; 0508 1 108 280 9035
                SLL     A                      ; 050A 1 108 280 53
                L       A, er1                 ; 050B 1 108 280 35
                ROL     A                      ; 050C 1 108 280 33
                JLT     crankfuel_clamp_max             ; 050D 1 108 280 CA04
                ADD     A, off(00142h)         ; 050F 1 108 280 8742
                JGE     crankfuel_clamp_max_store_er1             ; 0511 1 108 280 CD03
crankfuel_clamp_max:     L       A, #0ffffh             ; 0513 1 108 280 67FFFF
crankfuel_clamp_max_store_er1:     ST      A, er1                 ; 0516 1 108 280 89
crankfuel_clamp_max_load_ram14a:     MOV     off(0014ah), er1       ; 0517 1 108 280 457C4A
                LB      A, off(0012ch)         ; 051A 0 108 280 F42C
                JNE     crankfuel_clamp_max_store_r0             ; 051C 0 108 280 CE03
                J       crankfuel_clamp_max_load_ram14a_2             ; 051E 0 108 280 03B905
crankfuel_clamp_max_store_r0:     STB     A, r0                  ; 0521 0 108 280 88
                J       crankfuel_clamp_max_clear_x1             ; 0522 0 108 280 03F070
                DB  000h ; 0525
crankfuel_clamp_max_srlb_r0:     SRLB    r0                     ; 0526 0 108 280 20E7
                JBS     off(0011ah).0, injtimer_countdown_store_load_r1 ; 0528 0 108 280 E81A65
                JGE     crankfuel_clamp_max_load_ram14e             ; 052B 0 108 280 CD69
                JBR     off(0011dh).0, crankfuel_clamp_max_clear_acc ; 052D 0 108 280 D81D36
                LB      A, off(001b6h)         ; 0530 0 108 280 F4B6
                SUBB    A, #001h               ; 0532 0 108 280 A601
                JGE     injtimer_countdown_store             ; 0534 0 108 280 CD02
                LB      A, #007h               ; 0536 0 108 280 7707
injtimer_countdown_store:     STB     A, off(001b6h)         ; 0538 0 108 280 D4B6
                CMPB    A, #007h               ; 053A 0 108 280 C607
                JGT     injtimer_countdown_store_clear_ram1b3_bit0             ; 053C 0 108 280 C838
                MBR     C, off(001aeh)         ; 053E 0 108 280 C4AE21
                JLT     injtimer_countdown_store_sbr_ram1af             ; 0541 0 108 280 CA1B
                SUBB    A, #004h               ; 0543 0 108 280 A604
                ANDB    A, #007h               ; 0545 0 108 280 D607
                RBR     off(001afh)            ; 0547 0 108 280 C4AF12
                JEQ     injtimer_countdown_store_load_tbl_x1             ; 054A 0 108 280 C904
                L       A, off(001b0h)         ; 054C 1 108 280 E4B0
                SJ      injtimer_countdown_store_store_tbl_x1             ; 054E 1 108 280 CB09
injtimer_countdown_store_load_tbl_x1:     L       A, 00398h[X1]          ; 0550 1 108 280 E09803
                SUB     A, #0ffffh             ; 0553 1 108 280 A6FFFF
                JGE     injtimer_countdown_store_store_tbl_x1             ; 0556 1 108 280 CD01
                CLR     A                      ; 0558 1 108 280 F9
injtimer_countdown_store_store_tbl_x1:     ST      A, 00398h[X1]          ; 0559 1 108 280 D09803
                SJ      injtimer_countdown_store_clear_ram1b3_bit0             ; 055C 1 108 280 CB18
injtimer_countdown_store_sbr_ram1af:     SBR     off(001afh)            ; 055E 0 108 280 C4AF11
                SB      off(001b3h).0          ; 0561 0 108 280 C4B318
                SJ      injtimer_countdown_store_load_r1             ; 0564 0 108 280 CB2A
crankfuel_clamp_max_clear_acc:     CLR     A                      ; 0566 1 108 280 F9
                MOV     X2, A                  ; 0567 1 108 280 51
                ST      A, 00398h[X2]          ; 0568 1 108 280 D19803
                ST      A, 0039ah[X2]          ; 056B 1 108 280 D19A03
                ST      A, 0039ch[X2]          ; 056E 1 108 280 D19C03
                ST      A, 0039eh[X2]          ; 0571 1 108 280 D19E03
                ST      A, off(001aeh)         ; 0574 1 108 280 D4AE
injtimer_countdown_store_clear_ram1b3_bit0:     RB      off(001b3h).0          ; 0576 1 108 280 C4B308
                L       A, 00384h[X1]          ; 0579 1 108 280 E08403
                ADD     A, 00398h[X1]          ; 057C 1 108 280 B0980382
                JGE     injtimer_countdown_store_store_tbl_x1_2             ; 0580 1 108 280 CD03
                L       A, #0ffffh             ; 0582 1 108 280 67FFFF
injtimer_countdown_store_store_tbl_x1_2:     ST      A, 0004ch[X1]          ; 0585 1 108 280 D04C00
                CMP     A, #00003h             ; 0588 1 108 280 C60300
                JLT     injtimer_countdown_store_load_r1             ; 058B 1 108 280 CA03
                SB      off(00127h).1          ; 058D 1 108 280 C42719
injtimer_countdown_store_load_r1:     LB      A, r1                  ; 0590 0 108 280 79
                SBR     P3SF                     ; 0591 0 108 280 C52211
                SJ      injtimer_countdown_store_inc_x1             ; 0594 0 108 280 CB15
crankfuel_clamp_max_load_ram14e:     L       A, off(0014eh)         ; 0596 1 108 280 E44E
                JEQ     injtimer_countdown_store_inc_x1             ; 0598 1 108 280 C911
                CMP     A, 0004ch[X1]          ; 059A 1 108 280 B04C00C2
                JGE     crankfuel_clamp_max_store_tbl_x1             ; 059E 1 108 280 CD08
                CMP     0004ch[X1], #0ffffh    ; 05A0 1 108 280 B04C00C0FFFF
                JNE     injtimer_countdown_store_inc_x1             ; 05A6 1 108 280 CE03
crankfuel_clamp_max_store_tbl_x1:     ST      A, 0004ch[X1]          ; 05A8 1 108 280 D04C00
injtimer_countdown_store_inc_x1:     INC     X1                     ; 05AB 1 108 280 70
                INC     X1                     ; 05AC 1 108 280 70
                INCB    r1                     ; 05AD 1 108 280 A9
                CMPB    r1, #008h              ; 05AE 1 108 280 21C008
                JGE     injtimer_countdown_store_clear_ram14e             ; 05B1 1 108 280 CD03
                J       crankfuel_clamp_max_srlb_r0             ; 05B3 1 108 280 032605
injtimer_countdown_store_clear_ram14e:     CLR     off(0014eh)            ; 05B6 1 108 280 B44E15
crankfuel_clamp_max_load_ram14a_2:     L       A, off(0014ah)         ; 05B9 1 108 280 E44A
                JEQ     crankfuel_clamp_max_load_ram0bc             ; 05BB 1 108 280 C923
                ST      A, er0                 ; 05BD 1 108 280 88
                LB      A, off(0019ch)         ; 05BE 0 108 280 F49C
                EXTND                          ; 05C0 1 108 280 F8
                MOV     X1, A                  ; 05C1 1 108 280 50
                SLL     X1                     ; 05C2 1 108 280 90D7
                SBR     off(00129h)            ; 05C4 1 108 280 C42911
                JNE     crankfuel_clamp_max_load_ram19c             ; 05C7 1 108 280 CE04
                L       A, er0                 ; 05C9 1 108 280 34
                CAL     crankfuel_clamp_max_sub_cmp_acc             ; 05CA 1 108 280 325F46
crankfuel_clamp_max_load_ram19c:     LB      A, off(0019ch)         ; 05CD 0 108 280 F49C
                ADDB    A, #001h               ; 05CF 0 108 280 8601
                ANDB    A, #003h               ; 05D1 0 108 280 D603
                EXTND                          ; 05D3 1 108 280 F8
                MOV     X1, A                  ; 05D4 1 108 280 50
                SLL     X1                     ; 05D5 1 108 280 90D7
                SBR     off(00129h)            ; 05D7 1 108 280 C42911
                JNE     crankfuel_clamp_max_load_ram0bc             ; 05DA 1 108 280 CE04
                L       A, er0                 ; 05DC 1 108 280 34
                CAL     crankfuel_clamp_max_sub_cmp_acc             ; 05DD 1 108 280 325F46
crankfuel_clamp_max_load_ram0bc:     LB      A, 0bch                ; 05E0 0 108 280 F5BC
                ADDB    A, #001h               ; 05E2 0 108 280 8601
                CMPB    A, 0c4h                ; 05E4 0 108 280 C5C4C2
                JEQ     crankfuel_clamp_max_load_ram0c5             ; 05E7 0 108 280 C90C
                CMPB    A, #006h               ; 05E9 0 108 280 C606
                JNE     crankfuel_clamp_max_clear_ram127_bit1             ; 05EB 0 108 280 CE30
                LB      A, 0c4h                ; 05ED 0 108 280 F5C4
                JEQ     crankfuel_clamp_max_load_ram0c5             ; 05EF 0 108 280 C904
                CMPB    A, #0ffh               ; 05F1 0 108 280 C6FF
                JNE     crankfuel_clamp_max_clear_ram127_bit1             ; 05F3 0 108 280 CE28
crankfuel_clamp_max_load_ram0c5:     LB      A, 0c5h                ; 05F5 0 108 280 F5C5
                STB     A, ACCH                ; 05F7 0 108 280 D507
                CLRB    A                      ; 05F9 0 108 280 FA
                MOV     er0, off(00136h)       ; 05FA 0 108 280 B43648
                MUL                            ; 05FD 0 108 280 9035
                CLR     A                      ; 05FF 1 108 280 F9
                JBS     off(0011ah).5, crankfuel_clamp_max_set_ram0a0_bit6 ; 0600 1 108 280 ED1A07
                CMPB    0c4h, #0ffh            ; 0603 1 108 280 C5C4C0FF
                JEQ     crankfuel_clamp_max_load_ram138             ; 0607 1 108 280 C906
                L       A, er1                 ; 0609 1 108 280 35
crankfuel_clamp_max_set_ram0a0_bit6:     SB      0a0h.6                 ; 060A 1 108 280 C5A01E
                SJ      crankfuel_clamp_max_store_ram0be             ; 060D 1 108 280 CB0C
crankfuel_clamp_max_load_ram138:     L       A, off(00138h)         ; 060F 1 108 280 E438
                SUB     A, TIMER               ; 0611 1 108 280 B556A2
                ADD     A, er1                 ; 0614 1 108 280 09
                JLT     crankfuel_clamp_max_store_igna             ; 0615 1 108 280 CA01
                CLR     A                      ; 0617 1 108 280 F9
crankfuel_clamp_max_store_igna:     ST      A, IGNA                ; 0618 1 108 280 D562
                L       A, er1                 ; 061A 1 108 280 35
crankfuel_clamp_max_store_ram0be:     ST      A, 0beh                ; 061B 1 108 280 D5BE
crankfuel_clamp_max_clear_ram127_bit1:     RB      off(00127h).1          ; 061D 0 108 280 C42709
                JEQ     crankfuel_clamp_max_if_ram114_bit7_clr             ; 0620 0 108 280 C911
                JBS     off(0011fh).2, crankfuel_clamp_max_if_ram111_bit7_set ; 0622 0 108 280 EA1F03
                JBR     off(0011fh).3, crankfuel_clamp_max_if_ram114_bit7_clr ; 0625 0 108 280 DB1F0B
crankfuel_clamp_max_if_ram111_bit7_set:     JBS     off(00111h).7, crankfuel_clamp_max_if_ram114_bit7_clr ; 0628 0 108 280 EF1108
                RB      TRNSIT.3                 ; 062B 0 108 280 C5290B
                JNE     crankfuel_clamp_max_if_ram114_bit7_clr             ; 062E 0 108 280 CE03
dtc16_injector_latch: SB      09ch.6                 ; 0630 0 108 280 C59C1E
crankfuel_clamp_max_if_ram114_bit7_clr:     JBR     off(00114h).7, crankfuel_clamp_max_load_ram0bc_2 ; 0633 0 108 280 DF1403
                J       crankfuel_clamp_max_load_imm_3             ; 0636 0 108 280 03C906
crankfuel_clamp_max_load_ram0bc_2:     LB      A, 0bch                ; 0639 0 108 280 F5BC
                JEQ     crankfuel_clamp_max_load_imm             ; 063B 0 108 280 C940
                CMPB    A, #003h               ; 063D 0 108 280 C603
                JGE     crankfuel_clamp_max_cmp_acc             ; 063F 0 108 280 CD03
                J       crank_cycle_er2_store_set_carry             ; 0641 0 108 280 03E406
crankfuel_clamp_max_cmp_acc:     CMPB    A, #005h               ; 0644 0 108 280 C605
                JNE     crankfuel_clamp_max_if_ram11a_bit5_set             ; 0646 0 108 280 CE05
                JBS     off(00132h).1, crankfuel_clamp_max_clear_acc_2 ; 0648 0 108 280 E93211
                SJ      crank_cycle_er2_store_goto_06e4             ; 064B 0 108 280 CB2E
crankfuel_clamp_max_if_ram11a_bit5_set:     JBS     off(0011ah).5, crank_cycle_period_saturate ; 064D 0 108 280 ED1A23
                CMPB    A, #003h               ; 0650 0 108 280 C603
                MOV     DP, #00376h            ; 0652 0 108 280 627603
                CLR     er2                    ; 0655 0 108 280 4615
                JBS     off(00132h).1, crank_cycle_alt_dp ; 0657 0 108 280 E93205
                JEQ     crank_cycle_alt_dp_load_er0             ; 065A 0 108 280 C90A
crankfuel_clamp_max_clear_acc_2:     CLR     A                      ; 065C 1 108 280 F9
                SJ      crank_cycle_er2_store             ; 065D 1 108 280 CB17
crank_cycle_alt_dp:     MOV     DP, #00372h            ; 065F 0 108 280 627203
                JNE     crank_cycle_alt_dp_load_er0             ; 0662 0 108 280 CE02
                MOV     er2, [DP]              ; 0664 0 108 280 B24A
crank_cycle_alt_dp_load_er0:     MOV     er0, [DP]              ; 0666 0 108 280 B248
                LB      A, 0c3h                ; 0668 0 108 280 F5C3
                STB     A, ACCH                ; 066A 0 108 280 D507
                CLRB    A                      ; 066C 0 108 280 FA
                MUL                            ; 066D 0 108 280 9035
                L       A, er2                 ; 066F 1 108 280 36
                ADD     A, er1                 ; 0670 1 108 280 09
                JGE     crank_cycle_er2_store             ; 0671 1 108 280 CD03
crank_cycle_period_saturate:     L       A, #0ffffh             ; 0673 1 108 280 67FFFF
crank_cycle_er2_store:     ST      A, 0c0h                ; 0676 1 108 280 D5C0
                SB      0a0h.5                 ; 0678 1 108 280 C5A01D
crank_cycle_er2_store_goto_06e4:     SJ      crank_cycle_er2_store_set_carry             ; 067B 0 108 280 CB67
crankfuel_clamp_max_load_imm:     LB      A, #002h               ; 067D 0 108 280 7702
                JBS     off(0011bh).5, crankfuel_clamp_max_srlb_acc ; 067F 0 108 280 ED1B3F
                CMPB    0f1h, #024h            ; 0682 0 108 280 C5F1C024
                JNE     crankfuel_clamp_max_cmp_ram1a1             ; 0686 0 108 280 CE03
                SB      off(00132h).0          ; 0688 0 108 280 C43218
crankfuel_clamp_max_cmp_ram1a1:     CMPB    off(001a1h), #028h     ; 068B 0 108 280 C4A1C028
                JLE     crankfuel_clamp_max_set_ram127_bit4             ; 068F 0 108 280 CF1D
                MOV     DP, #00370h            ; 0691 0 108 280 627003
crankfuel_clamp_max_load_dp_ind:     L       A, [DP]                ; 0694 1 108 280 E2
                JEQ     crankfuel_clamp_max_clear_acc_3             ; 0695 1 108 280 C914
                INC     DP                     ; 0697 1 108 280 72
                INC     DP                     ; 0698 1 108 280 72
                CMP     DP, #0037ch            ; 0699 1 108 280 92C07C03
                JLT     crankfuel_clamp_max_load_dp_ind             ; 069D 1 108 280 CAF5
                JBS     off(00132h).0, crankfuel_clamp_max_load_imm_2 ; 069F 1 108 280 E8320F
                JBS     off(00110h).5, crankfuel_clamp_max_clear_acc_3 ; 06A2 1 108 280 ED1006
                CMPB    0d9h, #028h            ; 06A5 1 108 280 C5D9C028
                JLT     crankfuel_clamp_max_load_imm_2             ; 06A9 1 108 280 CA06
crankfuel_clamp_max_clear_acc_3:     CLRB    A                      ; 06AB 0 108 280 FA
                SJ      crankfuel_clamp_max_srlb_acc             ; 06AC 0 108 280 CB13
crankfuel_clamp_max_set_ram127_bit4:     SB      off(00127h).4          ; 06AE 0 108 280 C4271C
crankfuel_clamp_max_load_imm_2:     LB      A, #005h               ; 06B1 0 108 280 7705
                STB     A, 0c4h                ; 06B3 0 108 280 D5C4
                CLRB    A                      ; 06B5 0 108 280 FA
                STB     A, 0c5h                ; 06B6 0 108 280 D5C5
                LB      A, #0ffh               ; 06B8 0 108 280 77FF
                STB     A, 0c3h                ; 06BA 0 108 280 D5C3
                SB      off(00132h).1          ; 06BC 0 108 280 C43219
                LB      A, #003h               ; 06BF 0 108 280 7703
crankfuel_clamp_max_srlb_acc:     SRLB    A                      ; 06C1 0 108 280 63
                MB      off(0011ah).5, C       ; 06C2 0 108 280 C41A3D
                SRLB    A                      ; 06C5 0 108 280 63
                MB      P3.3, C                ; 06C6 0 108 280 C5243B
crankfuel_clamp_max_load_imm_3:     L       A, #000f3h             ; 06C9 1 108 280 67F300
                CMP     A, 0aeh                ; 06CC 1 108 280 B5AEC2
                JGE     crankfuel_clamp_max_load_ram1a3             ; 06CF 1 108 280 CD0C
                JBS     off(00111h).6, crankfuel_clamp_max_clear_carry ; 06D1 1 108 280 EE1108
                JBS     off(0011ah).7, crankfuel_clamp_max_clear_carry ; 06D4 1 108 280 EF1A05
                RB      TRNSIT.4                 ; 06D7 1 108 280 C5290C
                JEQ     dtc15_ign_output_latch             ; 06DA 1 108 280 C905
crankfuel_clamp_max_clear_carry:     RC                             ; 06DC 1 108 280 95
crankfuel_clamp_max_load_ram1a3:     MOVB    off(001a3h), #006h     ; 06DD 1 108 280 C4A39806
dtc15_ign_output_latch:     MB      09ch.3, C              ; 06E1 1 108 280 C59C3B
crank_cycle_er2_store_set_carry:     SC                             ; 06E4 1 108 280 85
                JBS     off(00114h).7, crank_cycle_er2_store_store_carry_ram09f_bit5 ; 06E5 1 108 280 EF140B
                JBR     off(00127h).2, crank_cycle_er2_store_store_carry_ram09f_bit5 ; 06E8 1 108 280 DA2708
                RC                             ; 06EB 1 108 280 95
                JBR     off(00128h).0, crank_cycle_er2_store_store_carry_ram09f_bit5 ; 06EC 1 108 280 D82804
                LB      A, 0bch                ; 06EF 0 108 280 F5BC
                CMPB    A, #005h               ; 06F1 0 108 280 C605
crank_cycle_er2_store_store_carry_ram09f_bit5:     MB      09fh.5, C              ; 06F3 0 108 280 C59F3D
                JBS     off(00121h).1, crank_cycle_er2_store_load_ram176 ; 06F6 0 108 280 E92103
                J       crank_cycle_er2_store_if_ram12e_bit3_clr             ; 06F9 0 108 280 033207
crank_cycle_er2_store_load_ram176:     L       A, off(00176h)         ; 06FC 1 108 280 E476
                MB      C, P4.1                ; 06FE 1 108 280 C52129
                ROR     A                      ; 0701 1 108 280 43
                MB      C, P4.2                ; 0702 1 108 280 C5212A
                ROR     A                      ; 0705 1 108 280 43
                CMPB    0bch, #000h            ; 0706 1 108 280 C5BCC000
                JNE     crank_cycle_er2_store_store_ram176             ; 070A 1 108 280 CE03
                ST      A, 0d0h                ; 070C 1 108 280 D5D0
                CLR     A                      ; 070E 1 108 280 F9
crank_cycle_er2_store_store_ram176:     ST      A, off(00176h)         ; 070F 1 108 280 D476
                LB      A, 0bch                ; 0711 0 108 280 F5BC
                CMPB    A, #001h               ; 0713 0 108 280 C601
                JNE     crank_a8_p3sf_output             ; 0715 0 108 280 CE04
                L       A, 0ceh                ; 0717 1 108 280 E5CE
                ST      A, off(00174h)         ; 0719 1 108 280 D474
crank_a8_p3sf_output:     L       A, off(00174h)         ; 071B 1 108 280 E474
                ST      A, er0                 ; 071D 1 108 280 88
                SRL     A                      ; 071E 1 108 280 63
                SRL     A                      ; 071F 1 108 280 63
                ST      A, off(00174h)         ; 0720 1 108 280 D474
                ANDB    r0, #003h              ; 0722 1 108 280 20D003
                MOV     DP, #0c000h            ; 0725 1 108 280 6200C0
                LB      A, (00226h-00280h)[USP] ; 0728 0 108 280 F3A6
                ANDB    A, #0fch               ; 072A 0 108 280 D6FC
                ORB     A, r0                  ; 072C 0 108 280 68
                STB     A, (00226h-00280h)[USP] ; 072D 0 108 280 D3A6
                XORB    A, #024h               ; 072F 0 108 280 F624
                STB     A, [DP]                ; 0731 0 108 280 D2
crank_cycle_er2_store_if_ram12e_bit3_clr:     JBR     off(0012eh).3, crank_cycle_er2_store_load_ram11a ; 0732 0 108 280 DB2E03
                J       crank_cycle_er2_store_set_ram132_bit2             ; 0735 0 108 280 03D51E
crank_cycle_er2_store_load_ram11a:     L       A, off(0011ah)         ; 0738 1 108 280 E41A
                ST      A, (0021ah-00280h)[USP] ; 073A 1 108 280 D39A
                POPS    A                      ; 073C 1 108 280 65
                RB      PSWH.0                 ; 073D 1 108 280 A208
                ST      A, IE                  ; 073F 1 108 280 D51A
                RTI                            ; 0741 1 108 280 02
; [flow] int_spurious_irq_trap: every interrupt vector this ROM never enables points here. It stamps
;    trap reason 047h in 0D4h and goes through fault_retry_check (retry budget, then BRK -> int_break).
int_spurious_irq_trap:  MOVB    0d4h, #047h            ; 0742 0 ??? ??? C5D49847
                SJ      fault_retry_check             ; 0746 0 ??? ??? CB04
;  [flow] int_WDT: watchdog vector. Stamps 0D4h=48h then fault_retry_check: 0D6h counts retries,
;    exhausted -> latch 09Eh.0 and BRK (full re-init through int_break). Same framework as HTS115.
int_WDT:        MOVB    0d4h, #048h            ; 0748 0 ??? ??? C5D49848
fault_retry_check:     LB      A, 0d6h                ; 074C 0 ??? ??? F5D6
                JEQ     fault_retry_check_set_ram09e_bit0             ; 074E 0 ??? ??? C905
                DECB    0d6h                   ; 0750 0 ??? ??? C5D617
                JNE     fault_retry_check_nop_acc             ; 0753 0 ??? ??? CE03
fault_retry_check_set_ram09e_bit0:     SB      09eh.0                 ; 0755 0 ??? ??? C59E18
fault_retry_check_nop_acc:     NOP                            ; 0758 0 ??? ??? 00
                NOP                            ; 0759 0 ??? ??? 00
                NOP                            ; 075A 0 ??? ??? 00
                BRK                            ; 075B 0 ??? ??? FF
;  [flow] int_NMI: latch-and-standby. Tests 09Fh.7 edge bit, optional DP snapshot, then reprograms
;    the port/timer/ADC control registers, runs the STPACP unlock sequence (5, then 10) and sets
;    SBYCON to enter STOP/HALT. Reached from int_break when P4.4 reads low.
int_NMI:        MOV     LRB, #00041h           ; 075C 0 208 ??? 574100
                RB      09fh.7                 ; 075F 0 208 ??? C59F0F
                JEQ     int_NMI_load_carry_pwm1con_bit4             ; 0762 0 208 ??? C901
                STB     A, [DP]                ; 0764 0 208 ??? D2
int_NMI_load_carry_pwm1con_bit4:     MB      C, PWM1CON.4                ; 0765 0 208 ??? C52C2C
                JLT     int_start_clear_ram0d4             ; 0768 0 208 ??? CA1F
                SB      P2A.1                  ; 076A 0 208 ??? C52519
                RB      ADSCAN.4                ; 076D 0 208 ??? C5660C
                RB      ADSEL.3                ; 0770 0 208 ??? C5670B
                CLR     IE                     ; 0773 0 208 ??? B51A15
                SB      SBYCON.2               ; 0776 0 208 ??? C5101A
                LB      A, #005h               ; 0779 0 208 ??? 7705
                STB     A, STPACP              ; 077B 0 208 ??? D513
                SLLB    A                      ; 077D 0 208 ??? 53
                STB     A, STPACP              ; 077E 0 208 ??? D513
                J       int_NMI_set_sbycon_bit0             ; 0780 0 208 ??? 033C00
;  [flow] int_start: reset vector. Clears the fault flags 09Eh.0/.5 and 0D4h, then BRK to enter the
;    supervisor at int_break -- all real init runs from there.
int_start:      RB      09eh.0                 ; 0783 0 ??? ??? C59E08
                RB      09eh.5                 ; 0786 0 ??? ??? C59E0D
int_start_clear_ram0d4:     CLRB    0d4h                   ; 0789 0 ??? ??? C5D415
                BRK                            ; 078C 0 ??? ??? FF
;  [flow] int_break: supervisor/re-init. USP supervisor stack=047Fh; P4.4 low -> NMI standby;
;    otherwise dispatches on the 0D4h reason byte (63h->49h 'retry' path via fault_retry_check) and
;    otherwise runs the full boot/init below (LRB->088, ADC config, default RAM image from 0B9B on).
int_break:      MOV     SSP, #0047fh           ; 078D 0 ??? ??? A0987F04
                MB      C, PWM1CON.4                ; 0791 0 ??? ??? C52C2C
                JGE     int_NMI                ; 0794 0 ??? ??? CDC6
                CLR     LRB                    ; 0796 0 ??? ??? A415
                LB      A, 0d4h                ; 0798 0 ??? ??? F5D4
                JEQ     int_break_load_ram00f             ; 079A 0 ??? ??? C90B
                CMPB    A, #063h               ; 079C 0 ??? ??? C663
                JNE     int_break_load_ram00f             ; 079E 0 ??? ??? CE07
                MOVB    0d4h, #049h            ; 07A0 0 ??? ??? C5D49849
                J       fault_retry_check             ; 07A4 0 ??? ??? 034C07
int_break_load_ram00f:     MOVB    PCLK, #0a4h            ; 07A7 0 ??? ??? C50F98A4
                MOV     OS0, #0ffffh           ; 07AB 0 ??? ??? B54498FFFF
                RB      PSWH.0                 ; 07B0 0 ??? ??? A208
                CLR     A                      ; 07B2 1 ??? ??? F9
                ST      A, IE                  ; 07B3 1 ??? ??? D51A
                ST      A, IRQ                 ; 07B5 1 ??? ??? D518
                MB      C, PSWH.4              ; 07B7 1 ??? ??? A22C
                JGE     int_break_load_ram0d4             ; 07B9 1 ??? ??? CD5D
                MB      C, PSWH.0              ; 07BB 1 ??? ??? A228
                JLT     int_break_load_ram0d4             ; 07BD 1 ??? ??? CA59
                L       A, #05555h             ; 07BF 1 ??? ??? 675555
                ST      A, ASSP                ; 07C2 1 ??? ??? D500
                CMP     SSP, #05555h           ; 07C4 1 ??? ??? A0C05555
                JNE     int_break_load_ram0d4             ; 07C8 1 ??? ??? CE4E
                MOV     LRB, A                 ; 07CA 1 ??? ??? A48A
                CMP     A, LRB                 ; 07CC 1 ??? ??? A4C2
                JNE     int_break_load_ram0d4             ; 07CE 1 ??? ??? CE48
                ST      A, IE                  ; 07D0 1 ??? ??? D51A
                CMP     A, IE                  ; 07D2 1 ??? ??? B51AC2
                JNE     int_break_load_ram0d4             ; 07D5 1 ??? ??? CE41
                SLL     A                      ; 07D7 1 ??? ??? 53
                MB      PSWH.6, C              ; 07D8 1 ??? ??? A23E
                JEQ     int_break_load_ram0d4             ; 07DA 1 ??? ??? C93C
                ST      A, ASSP                ; 07DC 1 ??? ??? D500
                CMP     SSP, #0aaaah           ; 07DE 1 ??? ??? A0C0AAAA
                JNE     int_break_load_ram0d4             ; 07E2 1 ??? ??? CE34
                MOV     SSP, #0047fh           ; 07E4 1 ??? ??? A0987F04
                MOV     LRB, A                 ; 07E8 1 ??? ??? A48A
                CMP     A, LRB                 ; 07EA 1 ??? ??? A4C2
                JNE     int_break_load_ram0d4             ; 07EC 1 ??? ??? CE2A
                ST      A, IE                  ; 07EE 1 ??? ??? D51A
                CMP     A, IE                  ; 07F0 1 ??? ??? B51AC2
                JNE     int_break_load_ram0d4             ; 07F3 1 ??? ??? CE23
                MOVB    PSWL, #055h            ; 07F5 1 ??? ??? A39855
                LB      A, PSW                 ; 07F8 0 ??? ??? F504
                MB      C, PSWH.4              ; 07FA 0 ??? ??? A22C
                JLT     int_break_load_ram0d4             ; 07FC 0 ??? ??? CA1A
                ANDB    A, #037h               ; 07FE 0 ??? ??? D637
                CMPB    A, #015h               ; 0800 0 ??? ??? C615
                JNE     int_break_load_ram0d4             ; 0802 0 ??? ??? CE14
                MOVB    PSWL, #0aah            ; 0804 0 ??? ??? A398AA
                LB      A, PSW                 ; 0807 0 ??? ??? F504
                ANDB    A, #037h               ; 0809 0 ??? ??? D637
                CMPB    A, #022h               ; 080B 0 ??? ??? C622
                JNE     int_break_load_ram0d4             ; 080D 0 ??? ??? CE09
                CLR     A                      ; 080F 1 ??? ??? F9
                ST      A, IE                  ; 0810 1 ??? ??? D51A
                SB      PSWH.0                 ; 0812 1 ??? ??? A218
                MB      C, PSWH.0              ; 0814 1 ??? ??? A228
                JLT     int_break_load_wdt             ; 0816 1 ??? ??? CA07
int_break_load_ram0d4:     MOVB    0d4h, #046h            ; 0818 1 ??? ??? C5D49846
                J       fault_retry_check_nop_acc             ; 081C 1 ??? ??? 035807
int_break_load_wdt:     MOVB    WDT, #03ch             ; 081F 1 ??? ??? C511983C
                MOV     LRB, #00011h           ; 0823 1 088 ??? 571100
                MOVB    PSWL, #000h            ; 0826 1 088 ??? A39800
                MB      C, P4.5                ; 0829 1 088 ??? C5212D
                MB      09fh.1, C              ; 082C 1 088 ??? C59F39
                MOVB    P2A, #06fh             ; 082F 1 088 ??? C525986F
                MOVB    P4SF, #001h            ; 0833 1 088 ??? C51F9801
                MOVB    P4IO, #011h              ; 0837 1 088 ??? C5209811
                MOVB    P4, #011h              ; 083B 1 088 ??? C5219811
                MOVB    P3SF, #0f0h              ; 083F 1 088 ??? C52298F0
                MOVB    P3IO, #0ffh            ; 0843 1 088 ??? C52398FF
                MOVB    P3, #007h              ; 0847 1 088 ??? C5249807
                MOVB    P2SF, #006h            ; 084B 1 088 ??? C5269806
                MOVB    P2IO, #006h            ; 084F 1 088 ??? C5279806
                MOVB    P2, #0f0h              ; 0853 1 088 ??? C52898F0
                CLRB    043h                   ; 0857 1 088 ??? C54315
                MOVB    OSIE, #0f0h            ; 085A 1 088 ??? C54298F0
                MOVB    TCON, #089h            ; 085E 1 088 ??? C5549889
                CLRB    TCON2                  ; 0862 1 088 ??? C55515
                MOVB    IGNCON, #010h          ; 0865 1 088 ??? C5619810
                L       A, #05555h             ; 0869 1 088 ??? 675555
                MOV     X1, A                  ; 086C 1 088 ??? 50
                CMP     A, X1                  ; 086D 1 088 ??? 90C2
                JNE     int_break_load_ram0d4_2             ; 086F 1 088 ??? CE49
                MOV     X2, A                  ; 0871 1 088 ??? 51
                CMP     A, X2                  ; 0872 1 088 ??? 91C2
                JNE     int_break_load_ram0d4_2             ; 0874 1 088 ??? CE44
                MOV     DP, A                  ; 0876 1 088 ??? 52
                CMP     A, DP                  ; 0877 1 088 ??? 92C2
                JNE     int_break_load_ram0d4_2             ; 0879 1 088 ??? CE3F
                SLL     A                      ; 087B 1 088 ??? 53
                MOV     X1, A                  ; 087C 1 088 ??? 50
                CMP     A, X1                  ; 087D 1 088 ??? 90C2
                JNE     int_break_load_ram0d4_2             ; 087F 1 088 ??? CE39
                MOV     X2, A                  ; 0881 1 088 ??? 51
                CMP     A, X2                  ; 0882 1 088 ??? 91C2
                JNE     int_break_load_ram0d4_2             ; 0884 1 088 ??? CE34
                MOV     DP, A                  ; 0886 1 088 ??? 52
                CMP     A, DP                  ; 0887 1 088 ??? 92C2
                JNE     int_break_load_ram0d4_2             ; 0889 1 088 ??? CE2F
                MOV     DP, #0e000h            ; 088B 1 088 ??? 6200E0
                MOVB    [DP], #09bh            ; 088E 1 088 ??? C2989B
                MOV     DP, #00086h            ; 0891 1 088 ??? 628600
int_break_load_dp_ind:     L       A, [DP]                ; 0894 1 088 ??? E2
                SB      09fh.7                 ; 0895 1 088 ??? C59F1F
                MOV     [DP], #05555h          ; 0898 1 088 ??? B2985555
                CMP     [DP], #05555h          ; 089C 1 088 ??? B2C05555
                JNE     int_break_load_ram0d4_2             ; 08A0 1 088 ??? CE18
                MOV     [DP], #0aaaah          ; 08A2 1 088 ??? B298AAAA
                CMP     [DP], #0aaaah          ; 08A6 1 088 ??? B2C0AAAA
                JNE     int_break_load_ram0d4_2             ; 08AA 1 088 ??? CE0E
                ST      A, [DP]                ; 08AC 1 088 ??? D2
                RB      09fh.7                 ; 08AD 1 088 ??? C59F0F
                INC     DP                     ; 08B0 1 088 ??? 72
                INC     DP                     ; 08B1 1 088 ??? 72
                CMP     DP, #0047fh            ; 08B2 1 088 ??? 92C07F04
                JLT     int_break_load_dp_ind             ; 08B6 1 088 ??? CADC
                SJ      int_break_load_dp             ; 08B8 1 088 ??? CB07
int_break_load_ram0d4_2:     MOVB    0d4h, #04ah            ; 08BA 1 088 ??? C5D4984A
                J       fault_retry_check_nop_acc             ; 08BE 1 088 ??? 035807
int_break_load_dp:     MOV     DP, #00300h            ; 08C1 1 088 ??? 620003
                CMPB    [DP], #05ah            ; 08C4 1 088 ??? C2C05A
                RC                             ; 08C7 1 088 ??? 95
                JNE     int_break_store_carry_ram09f_bit6             ; 08C8 1 088 ??? CE03
                MB      C, SBYCON.7            ; 08CA 1 088 ??? C5102F
int_break_store_carry_ram09f_bit6:     MB      09fh.6, C              ; 08CD 1 088 ??? C59F3E
                JGE     int_break_clear_acc             ; 08D0 1 088 ??? CD3B
                MOV     LRB, #00041h           ; 08D2 1 208 ??? 574100
                JBR     off(00233h).0, int_break_goto_6edd ; 08D5 1 208 ??? D83308
                JBR     off(00233h).1, int_break_goto_6edd ; 08D8 1 208 ??? D93305
                CMPB    r6, #018h              ; 08DB 1 208 ??? 26C018
                JNE     int_break_call_456d             ; 08DE 1 208 ??? CE10
int_break_goto_6edd:     J       int_break_set_ram232_bit6             ; 08E0 1 208 ??? 03DD6E
int_break_clear_dp_ind:     RB      [DP].7                 ; 08E3 1 208 ??? C20F
                JNE     int_break_load_dp_3             ; 08E5 1 208 ??? CE14
                MOV     DP, #00348h            ; 08E7 1 208 ??? 624803
                RB      [DP].0                 ; 08EA 1 208 ??? C208
                JNE     int_break_load_dp_2             ; 08EC 1 208 ??? CE08
                SJ      int_break_clear_ram233_bit0             ; 08EE 1 208 ??? CB14
int_break_call_456d:     CAL     dtc_active_confirm_sub_clear_acc             ; 08F0 1 208 ??? 326D45
                CAL     dtc_active_confirm_sub_load_dp             ; 08F3 1 208 ??? 32174B
int_break_load_dp_2:     MOV     DP, #00332h            ; 08F6 1 208 ??? 623203
                RB      [DP].7                 ; 08F9 1 208 ??? C20F
int_break_load_dp_3:     MOV     DP, #00348h            ; 08FB 1 208 ??? 624803
                RB      [DP].0                 ; 08FE 1 208 ??? C208
                CAL     cfgvariant_checksum_calc             ; 0900 1 208 ??? 32E84A
                ST      A, [DP]                ; 0903 1 208 ??? D2
int_break_clear_ram233_bit0:     RB      off(00233h).0          ; 0904 1 208 ??? C43308
                RB      off(00233h).1          ; 0907 1 208 ??? C43309
                CAL     int_break_sub_clear_ram232_bit6             ; 090A 1 208 ??? 32EB6E
int_break_clear_acc:     CLRB    A                      ; 090D 0 088 ??? FA
                MB      C, 09fh.1              ; 090E 0 088 ??? C59F29
                ROLB    A                      ; 0911 0 088 ??? 33
                MB      C, 09eh.0              ; 0912 0 088 ??? C59E28
                ROLB    A                      ; 0915 0 088 ??? 33
                MB      C, 09eh.5              ; 0916 0 088 ??? C59E2D
                ROLB    A                      ; 0919 0 088 ??? 33
                MB      C, 09fh.6              ; 091A 0 088 ??? C59F2E
                ROLB    A                      ; 091D 0 088 ??? 33
                STB     A, r0                  ; 091E 0 088 ??? 88
                SRLB    A                      ; 091F 0 088 ??? 63
                LB      A, 0d4h                ; 0920 0 088 ??? F5D4
                JGE     int_break_store_carry_pswl_bit4             ; 0922 0 088 ??? CD03
                JEQ     int_break_store_carry_pswl_bit4             ; 0924 0 088 ??? C901
                RC                             ; 0926 0 088 ??? 95
int_break_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 0927 0 088 ??? A33C
                STB     A, r1                  ; 0929 0 088 ??? 89
                MOVB    r2, 0d6h               ; 092A 0 088 ??? C5D64A
                MOV     DP, #00301h            ; 092D 0 088 ??? 620103
                MOVB    r3, [DP]               ; 0930 0 088 ??? C24B
                MOV     DP, #0035eh            ; 0932 0 088 ??? 625E03
                MOV     X1, [DP]               ; 0935 0 088 ??? B278
                INC     DP                     ; 0937 0 088 ??? 72
                INC     DP                     ; 0938 0 088 ??? 72
                MOV     X2, [DP]               ; 0939 0 088 ??? B279
                CLR     A                      ; 093B 1 088 ??? F9
                MOV     DP, #00090h            ; 093C 1 088 ??? 629000
                MOV     USP, #00300h           ; 093F 1 088 300 A1980003
int_break_store_dp_ind:     ST      A, [DP]                ; 0943 1 088 300 D2
                INC     DP                     ; 0944 1 088 300 72
                INC     DP                     ; 0945 1 088 300 72
                CMP     DP, off(00086h)        ; 0946 1 088 300 92C386
                JLT     int_break_store_dp_ind             ; 0949 1 088 300 CAF8
                CMP     USP, #00480h           ; 094B 1 088 300 A1C08004
                JGE     int_break_load_r0             ; 094F 1 088 300 CD0C
                MOV     USP, #00480h           ; 0951 1 088 480 A1988004
                JBR     off(PSW).4, int_break_store_dp_ind ; 0955 1 088 480 DC04EB
                MOV     DP, #00364h            ; 0958 1 088 480 626403
                SJ      int_break_store_dp_ind             ; 095B 1 088 480 CBE6
int_break_load_r0:     LB      A, r0                  ; 095D 0 088 300 78
                SRLB    A                      ; 095E 0 088 300 63
                MB      09fh.6, C              ; 095F 0 088 300 C59F3E
                SRLB    A                      ; 0962 0 088 300 63
                MB      09eh.5, C              ; 0963 0 088 300 C59E3D
                SRLB    A                      ; 0966 0 088 300 63
                MB      09eh.0, C              ; 0967 0 088 300 C59E38
                SRLB    A                      ; 096A 0 088 300 63
                MB      09fh.1, C              ; 096B 0 088 300 C59F39
                LB      A, r1                  ; 096E 0 088 300 79
                STB     A, 0d4h                ; 096F 0 088 300 D5D4
                STB     A, 0d5h                ; 0971 0 088 300 D5D5
                JBR     off(SBYCON).7, int_break_load_dp_4 ; 0973 0 088 300 DF1003
                JNE     int_break_load_dp_4             ; 0976 0 088 300 CE01
                LB      A, r3                  ; 0978 0 088 300 7B
int_break_load_dp_4:     MOV     DP, #00301h            ; 0979 0 088 300 620103
                STB     A, [DP]                ; 097C 0 088 300 D2
                LB      A, r1                  ; 097D 0 088 300 79
                JBR     off(0009fh).6, int_break_load_r2 ; 097E 0 088 300 DE9F05
                JNE     int_break_load_ram0d6             ; 0981 0 088 300 CE05
                JBS     off(0009eh).0, int_break_load_ram0d6 ; 0983 0 088 300 E89E02
int_break_load_r2:     MOVB    r2, #010h              ; 0986 0 088 300 9A10
int_break_load_ram0d6:     MOVB    off(000d6h), r2        ; 0988 0 088 300 227CD6
                MOVB    0d7h, #001h            ; 098B 0 088 300 C5D79801
                MOV     DP, #0035eh            ; 098F 0 088 300 625E03
                L       A, X1                  ; 0992 1 088 300 40
                JBS     off(SBYCON).7, int_break_store_dp_ind_2 ; 0993 1 088 300 EF1002
                CLR     A                      ; 0996 1 088 300 F9
                MOV     X2, A                  ; 0997 1 088 300 51
int_break_store_dp_ind_2:     ST      A, [DP]                ; 0998 1 088 300 D2
                INC     DP                     ; 0999 1 088 300 72
                INC     DP                     ; 099A 1 088 300 72
                L       A, X2                  ; 099B 1 088 300 41
                ST      A, [DP]                ; 099C 1 088 300 D2
                MB      C, 09fh.6              ; 099D 1 088 300 C59F2E
                JGE     int_break_clear_acc_2             ; 09A0 1 088 300 CD17
                CMPB    0d4h, #04bh            ; 09A2 1 088 300 C5D4C04B
                JEQ     int_break_clear_acc_2             ; 09A6 1 088 300 C911
                MOV     X1, #011c1h            ; 09A8 1 088 300 60C111
int_break_dec_x1:     DEC     X1                     ; 09AB 1 088 300 80
                JNE     int_break_dec_x1             ; 09AC 1 088 300 CEFD
                L       A, OS0                 ; 09AE 1 088 300 E544
                XOR     A, #0ffffh             ; 09B0 1 088 300 F6FFFF
                MOV     DP, #0032ah            ; 09B3 1 088 300 622A03
                ST      A, [DP]                ; 09B6 1 088 300 D2
                SJ      int_break_load_adsel             ; 09B7 1 088 300 CB31
int_break_clear_acc_2:     CLRB    A                      ; 09B9 0 088 300 FA
                CLRB    r0                     ; 09BA 0 088 300 2015
                MOV     DP, #07ffeh            ; 09BC 0 088 300 62FE7F
int_break_rom_load_dp_ind:     LC      A, [DP]                ; 09BF 0 088 300 92A8
                ADDB    A, ACCH                ; 09C1 0 088 300 C50782
                ADDB    r0, A                  ; 09C4 0 088 300 2081
                DEC     DP                     ; 09C6 0 088 300 82
                JRNZ    DP, int_break_rom_load_dp_ind         ; 09C7 0 088 300 30F6
                MOVB    WDT, #03ch             ; 09C9 0 088 300 C511983C
                MOVB    WDT, #0c3h             ; 09CD 0 088 300 C51198C3
                LB      A, 085h                ; 09D1 0 088 300 F585
                JNE     int_break_rom_load_dp_ind             ; 09D3 0 088 300 CEEA
                LC      A, [DP]                ; 09D5 0 088 300 92A8
                ADDB    A, ACCH                ; 09D7 0 088 300 C50782
                ADDB    A, r0                  ; 09DA 0 088 300 08
                JEQ     int_break_load_adsel             ; 09DB 0 088 300 C90D
                LCB     A, 07ff1h              ; 09DD 0 088 300 909DF17F
                JEQ     int_break_load_adsel             ; 09E1 0 088 300 C907
                MOVB    0d4h, #04bh            ; 09E3 0 088 300 C5D4984B
                J       fault_retry_check_nop_acc             ; 09E7 0 088 300 035807
int_break_load_adsel:     MOVB    ADSEL, #000h           ; 09EA 1 088 300 C5679800
                RB      ADSCAN.4                ; 09EE 1 088 300 C5660C
                MOVB    ADSCAN, #010h           ; 09F1 1 088 300 C5669810
                CLR     DP                     ; 09F5 1 088 300 9215
int_break_store_carry_r0_bit0:     MB      r0.0, C                ; 09F7 1 088 300 2038
                JRNZ    DP, int_break_store_carry_r0_bit0         ; 09F9 1 088 300 30FC
                CAL     vss_clamp_common_sub_clear_pswh_bit0             ; 09FB 1 088 300 32984A
                LB      A, 0bbh                ; 09FE 0 088 300 F5BB
                JNE     int_break_store_carry_r0_bit0             ; 0A00 0 088 300 CEF5
                CAL     percyl_counter_gate_sub_load_dp             ; 0A02 0 088 300 32304D
                LB      A, #020h               ; 0A05 0 088 300 7720
                STB     A, STTMR               ; 0A07 0 088 300 D578
                STB     A, STTM                ; 0A09 0 088 300 D579
                MOVB    SCONA, #080h           ; 0A0B 0 088 300 C57A9880
                MOVB    SCONB, #080h            ; 0A0F 0 088 300 C57B9880
                MOVB    SRSTAT, #020h            ; 0A13 0 088 300 C57E9820
                LCB     A, 07ff1h              ; 0A17 0 088 300 909DF17F
                JNE     int_break_load_dp_5             ; 0A1B 0 088 300 CE06
                LCB     A, 07ff3h              ; 0A1D 0 088 300 909DF37F
                SJ      int_break_sllb_acc             ; 0A21 0 088 300 CB04
int_break_load_dp_5:     MOV     DP, #003dfh            ; 0A23 0 088 300 62DF03
                LB      A, [DP]                ; 0A26 0 088 300 F2
int_break_sllb_acc:     SLLB    A                      ; 0A27 0 088 300 53
                MB      0a0h.7, C              ; 0A28 0 088 300 C5A03F
                JLT     int_break_clear_acc_3             ; 0A2B 0 088 300 CA12
                LB      A, #004h               ; 0A2D 0 088 300 7704
                STB     A, STTMR               ; 0A2F 0 088 300 D578
                STB     A, STTM                ; 0A31 0 088 300 D579
                MOVB    SCONA, #085h           ; 0A33 0 088 300 C57A9885
                CLR     A                      ; 0A37 1 088 300 F9
                CAL     int_break_sub_load_ram07b             ; 0A38 1 088 300 32204E
                MOVB    SRSTAT, #020h            ; 0A3B 1 088 300 C57E9820
int_break_clear_acc_3:     CLR     A                      ; 0A3F 1 088 300 F9
                LCB     A, 07ff1h              ; 0A40 1 088 300 909DF17F
                MB      C, PSWH.6              ; 0A44 1 088 300 A22E
                LC      A, 00020h              ; 0A46 1 088 300 909C2000
                JGE     int_break_cmp_acc             ; 0A4A 1 088 300 CD05
                CMP     A, #00094h             ; 0A4C 1 088 300 C69400
                JEQ     int_break_set_ieh_bit4             ; 0A4F 1 088 300 C90C
int_break_cmp_acc:     CMP     A, #00043h             ; 0A51 1 088 300 C64300
                JEQ     int_break_set_ieh_bit4             ; 0A54 1 088 300 C907
                MOVB    0d4h, #052h            ; 0A56 1 088 300 C5D49852
                J       fault_retry_check_nop_acc             ; 0A5A 1 088 300 035807
int_break_set_ieh_bit4:     SB      IEH.4                  ; 0A5D 1 088 300 C51B1C
                NOP                            ; 0A60 1 088 300 00
                CLR     IE                     ; 0A61 1 088 300 B51A15
                RB      IRQ.4                  ; 0A64 1 088 300 C5180C
                MOV     TIMER, #0fffeh         ; 0A67 1 088 300 B55698FEFF
                DIVB                           ; 0A6C 1 088 300 A236
                NOP                            ; 0A6E 1 088 300 00
                DIVB                           ; 0A6F 1 088 300 A236
                NOP                            ; 0A71 1 088 300 00
                MULB                           ; 0A72 1 088 300 A234
                NOP                            ; 0A74 1 088 300 00
                RB      IRQ.4                  ; 0A75 1 088 300 C5180C
                JEQ     int_break_load_ram0d4_3             ; 0A78 1 088 300 C907
                L       A, TIMER               ; 0A7A 1 088 300 E556
                CMP     A, #00006h             ; 0A7C 1 088 300 C60600
                JLT     int_break_load_igna             ; 0A7F 1 088 300 CA07
int_break_load_ram0d4_3:     MOVB    0d4h, #053h            ; 0A81 1 088 300 C5D49853
                J       fault_retry_check_nop_acc             ; 0A85 1 088 300 035807
int_break_load_igna:     L       A, IGNA                ; 0A88 1 088 300 E562
                JNE     int_break_load_ram0d4_4             ; 0A8A 1 088 300 CE40
                L       A, IGNB                ; 0A8C 1 088 300 E564
                JNE     int_break_load_ram0d4_4             ; 0A8E 1 088 300 CE3C
                CMPB    IGNCON, #010h          ; 0A90 1 088 300 C561C010
                JNE     int_break_load_ram0d4_4             ; 0A94 1 088 300 CE36
                MB      C, P2.2                ; 0A96 1 088 300 C5282A
                JGE     int_break_load_ram0d4_4             ; 0A99 1 088 300 CD31
                MOV     IGNA, #00003h          ; 0A9B 1 088 300 B562980300
                MOV     IGNB, #00007h          ; 0AA0 1 088 300 B564980700
                MB      C, P2.2                ; 0AA5 1 088 300 C5282A
                JGE     int_break_load_ram0d4_4             ; 0AA8 1 088 300 CD22
                MOV     DP, #00008h            ; 0AAA 1 088 300 620800
int_break_loop_dp:     JRNZ    DP, int_break_loop_dp         ; 0AAD 1 088 300 30FE
                MB      C, P2.2                ; 0AAF 1 088 300 C5282A
                JLT     int_break_load_ram0d4_4             ; 0AB2 1 088 300 CA18
                CMP     IGNA, #0ffffh          ; 0AB4 1 088 300 B562C0FFFF
                JNE     int_break_load_ram0d4_4             ; 0AB9 1 088 300 CE11
                MOV     DP, #00006h            ; 0ABB 1 088 300 620600
int_break_loop_dp_2:     JRNZ    DP, int_break_loop_dp_2         ; 0ABE 1 088 300 30FE
                MB      C, P2.2                ; 0AC0 1 088 300 C5282A
                JGE     int_break_load_ram0d4_4             ; 0AC3 1 088 300 CD07
                CMP     IGNB, #0ffffh          ; 0AC5 1 088 300 B564C0FFFF
                JEQ     int_break_load_ram0d4_5             ; 0ACA 1 088 300 C907
int_break_load_ram0d4_4:     MOVB    0d4h, #054h            ; 0ACC 1 088 300 C5D49854
                J       fault_retry_check_nop_acc             ; 0AD0 1 088 300 035807
int_break_load_ram0d4_5:     LB      A, 0d4h                ; 0AD3 0 088 300 F5D4
                JEQ     int_break_load_p3             ; 0AD5 0 088 300 C904
                CMPB    A, #055h               ; 0AD7 0 088 300 C655
                JNE     int_break_load_lrb             ; 0AD9 0 088 300 CE67
int_break_load_p3:     LB      A, P3                  ; 0ADB 0 088 300 F524
                ANDB    A, #0f0h               ; 0ADD 0 088 300 D6F0
                XORB    A, #0f0h               ; 0ADF 0 088 300 F6F0
                JNE     int_break_load_ram0d4_6             ; 0AE1 0 088 300 CE58
                L       A, INJ0                ; 0AE3 1 088 300 E54C
                JNE     int_break_load_ram0d4_6             ; 0AE5 1 088 300 CE54
                L       A, INJ1                ; 0AE7 1 088 300 E54E
                JNE     int_break_load_ram0d4_6             ; 0AE9 1 088 300 CE50
                L       A, INJ2                ; 0AEB 1 088 300 E550
                JNE     int_break_load_ram0d4_6             ; 0AED 1 088 300 CE4C
                L       A, INJ3                ; 0AEF 1 088 300 E552
                JNE     int_break_load_ram0d4_6             ; 0AF1 1 088 300 CE48
                L       A, #00004h             ; 0AF3 1 088 300 670400
                ST      A, INJ0                ; 0AF6 1 088 300 D54C
                ST      A, INJ1                ; 0AF8 1 088 300 D54E
                ST      A, INJ2                ; 0AFA 1 088 300 D550
                ST      A, INJ3                ; 0AFC 1 088 300 D552
                CMP     A, INJ0                ; 0AFE 1 088 300 B54CC2
                JLT     int_break_load_ram0d4_6             ; 0B01 1 088 300 CA38
                CMP     A, INJ1                ; 0B03 1 088 300 B54EC2
                JLT     int_break_load_ram0d4_6             ; 0B06 1 088 300 CA33
                CMP     A, INJ2                ; 0B08 1 088 300 B550C2
                JLT     int_break_load_ram0d4_6             ; 0B0B 1 088 300 CA2E
                CMP     A, INJ3                ; 0B0D 1 088 300 B552C2
                JLT     int_break_load_ram0d4_6             ; 0B10 1 088 300 CA29
                LB      A, P3                  ; 0B12 0 088 300 F524
                ANDB    A, #0f0h               ; 0B14 0 088 300 D6F0
                JNE     int_break_load_ram0d4_6             ; 0B16 0 088 300 CE23
                MUL                            ; 0B18 0 088 300 9035
                DIV                            ; 0B1A 0 088 300 9037
                L       A, #0ffffh             ; 0B1C 1 088 300 67FFFF
                CMP     A, INJ0                ; 0B1F 1 088 300 B54CC2
                JNE     int_break_load_ram0d4_6             ; 0B22 1 088 300 CE17
                CMP     A, INJ1                ; 0B24 1 088 300 B54EC2
                JNE     int_break_load_ram0d4_6             ; 0B27 1 088 300 CE12
                CMP     A, INJ2                ; 0B29 1 088 300 B550C2
                JNE     int_break_load_ram0d4_6             ; 0B2C 1 088 300 CE0D
                CMP     A, INJ3                ; 0B2E 1 088 300 B552C2
                JNE     int_break_load_ram0d4_6             ; 0B31 1 088 300 CE08
                LB      A, P3                  ; 0B33 0 088 300 F524
                ANDB    A, #0f0h               ; 0B35 0 088 300 D6F0
                XORB    A, #0f0h               ; 0B37 0 088 300 F6F0
                JEQ     int_break_load_lrb             ; 0B39 0 088 300 C907
int_break_load_ram0d4_6:     MOVB    0d4h, #055h            ; 0B3B 0 088 300 C5D49855
                J       fault_retry_check_nop_acc             ; 0B3F 0 088 300 035807
int_break_load_lrb:     MOV     LRB, #00041h           ; 0B42 0 208 300 574100
                MOV     USP, #00380h           ; 0B45 0 208 380 A1988003
                SB      09fh.6                 ; 0B49 0 208 380 C59F1E
                JEQ     int_break_load_imm             ; 0B4C 0 208 380 C904
                LB      A, 0d4h                ; 0B4E 0 208 380 F5D4
                JEQ     int_break_load_stk             ; 0B50 0 208 380 C927
int_break_load_imm:     L       A, #0ffffh             ; 0B52 1 208 380 67FFFF
                ST      A, (00316h-00380h)[USP] ; 0B55 1 208 380 D396
                ST      A, (0031ch-00380h)[USP] ; 0B57 1 208 380 D39C
                ST      A, (00322h-00380h)[USP] ; 0B59 1 208 380 D3A2
                ST      A, (00328h-00380h)[USP] ; 0B5B 1 208 380 D3A8
                L       A, #08000h             ; 0B5D 1 208 380 670080
                ST      A, (00304h-00380h)[USP] ; 0B60 1 208 380 D384
                ST      A, (00308h-00380h)[USP] ; 0B62 1 208 380 D388
                ST      A, (0030ch-00380h)[USP] ; 0B64 1 208 380 D38C
                LC      A, 0555ah              ; 0B66 1 208 380 909C5A55
                ST      A, (0030eh-00380h)[USP] ; 0B6A 1 208 380 D38E
                SB      off(0022ah).7          ; 0B6C 1 208 380 C42A1F
                MOVB    (0032fh-00380h)[USP], #078h ; 0B6F 1 208 380 C3AF9878
                CLRB    (0032eh-00380h)[USP]   ; 0B73 1 208 380 C3AE15
                NOP                            ; 0B76 1 208 380 00
                NOP                            ; 0B77 1 208 380 00
                NOP                            ; 0B78 1 208 380 00
int_break_load_stk:     MOVB    (00300h-00380h)[USP], #05ah ; 0B79 1 208 380 C380985A
                MOV     USP, #00180h           ; 0B7D 1 208 180 A1988001
                SB      SBYCON.7               ; 0B81 1 208 180 C5101F
                MOV     X2, #00336h            ; 0B84 1 208 180 613603
                LB      A, 00000h[X2]          ; 0B87 0 208 180 F10000
                SLLB    A                      ; 0B8A 0 208 180 53
                MB      PSWH.6, C              ; 0B8B 0 208 180 A23E
                SLLB    A                      ; 0B8D 0 208 180 53
                JGE     int_break_andb_tbl_x2             ; 0B8E 0 208 180 CD06
                JNE     int_break_andb_tbl_x2             ; 0B90 0 208 180 CE04
                CLR     A                      ; 0B92 1 208 180 F9
                CAL     vcal_4_sub_clear_acc             ; 0B93 1 208 180 32F24C
int_break_andb_tbl_x2:     ANDB    00000h[X2], #03fh      ; 0B96 1 208 180 C10000D03F
                LB      A, ADCR2H              ; 0B9B 0 208 180 F56D
                STB     A, 0dch                ; 0B9D 0 208 180 D5DC
                MOV     DP, #003d0h            ; 0B9F 0 208 180 62D003
                LB      A, [DP]                ; 0BA2 0 208 180 F2
                STB     A, 0dah                ; 0BA3 0 208 180 D5DA
                MOV     DP, #003d7h            ; 0BA5 0 208 180 62D703
                LB      A, [DP]                ; 0BA8 0 208 180 F2
                STB     A, 0dbh                ; 0BA9 0 208 180 D5DB
                MOVB    0d8h, #086h            ; 0BAB 0 208 180 C5D89886
                MOV     DP, #003dah            ; 0BAF 0 208 180 62DA03
                LB      A, [DP]                ; 0BB2 0 208 180 F2
                MOV     DP, #003a4h            ; 0BB3 0 208 180 62A403
                STB     A, [DP]                ; 0BB6 0 208 180 D2
                CAL     ect_fault_range_check_sub_load_dp             ; 0BB7 0 208 180 32464A
                MOVB    0d9h, #062h            ; 0BBA 0 208 180 C5D99862
                MOVB    0e0h, #0f9h            ; 0BBE 0 208 180 C5E098F9
                LB      A, #025h               ; 0BC2 0 208 180 7725
                STB     A, 0ddh                ; 0BC4 0 208 180 D5DD
                STB     A, off(0029eh)         ; 0BC6 0 208 180 D49E
                L       A, ADCR6               ; 0BC8 1 208 180 E574
                ST      A, 0a4h                ; 0BCA 1 208 180 D5A4
                LB      A, ACCH                ; 0BCC 0 208 180 F507
                MOV     DP, #003a3h            ; 0BCE 0 208 180 62A303
                STB     A, [DP]                ; 0BD1 0 208 180 D2
                LB      A, #0a0h               ; 0BD2 0 208 180 77A0
                STB     A, off(00288h)         ; 0BD4 0 208 180 D488
                STB     A, (00178h-00180h)[USP] ; 0BD6 0 208 180 D3F8
                STB     A, 0e1h                ; 0BD8 0 208 180 D5E1
                MOV     DP, #003a1h            ; 0BDA 0 208 180 62A103
                STB     A, [DP]                ; 0BDD 0 208 180 D2
                INC     DP                     ; 0BDE 0 208 180 72
                STB     A, [DP]                ; 0BDF 0 208 180 D2
                L       A, #04d00h             ; 0BE0 1 208 180 67004D
                ST      A, 0aah                ; 0BE3 1 208 180 D5AA
                ST      A, er0                 ; 0BE5 1 208 180 88
                SLL     A                      ; 0BE6 1 208 180 53
                JLT     int_break_load_imm_2             ; 0BE7 1 208 180 CA05
                SLL     A                      ; 0BE9 1 208 180 53
                LB      A, ACCH                ; 0BEA 0 208 180 F507
                JGE     clamp_result_store             ; 0BEC 0 208 180 CD02
int_break_load_imm_2:     LB      A, #0ffh               ; 0BEE 0 208 180 77FF
clamp_result_store:     STB     A, 0e8h                ; 0BF0 0 208 180 D5E8
                LB      A, r1                  ; 0BF2 0 208 180 79
                STB     A, 0e7h                ; 0BF3 0 208 180 D5E7
                LB      A, 0d4h                ; 0BF5 0 208 180 F5D4
                JNE     clamp_result_store_load_ram2e2             ; 0BF7 0 208 180 CE09
                LB      A, #014h               ; 0BF9 0 208 180 7714
                STB     A, off(002efh)         ; 0BFB 0 208 180 D4EF
                STB     A, off(002e1h)         ; 0BFD 0 208 180 D4E1
                NOP                            ; 0BFF 0 208 180 00
                NOP                            ; 0C00 0 208 180 00
                NOP                            ; 0C01 0 208 180 00
;  [flow] init defaults (runs from the int_break boot path). Note the rev-limit defaults:
;    0C1E: resume-word 016Ch = 00FAh   (p13info: 'High Cam Rev Limit Reset' patched as immediate @0C21)
;    0C23: cut-word   016Ah = 00F4h     (p13info: 'High Cam Rev Limit Set'   patched as immediate @0C26)
;    0C2B: RPM word 0ACh = FFFFh = 'no speed sensor yet'. The same FA/F4 pair lives @540B/540F.
clamp_result_store_load_ram2e2:     MOVB    off(002e2h), #032h     ; 0C02 0 208 180 C4E29832
                MOVB    off(0028ch), #078h     ; 0C06 0 208 180 C48C9878
                MOVB    off(0028bh), #053h     ; 0C0A 0 208 180 C48B9853
                MOVB    off(002d0h), #01eh     ; 0C0E 0 208 180 C4D0981E
                MOVB    off(00292h), ADCR3H    ; 0C12 0 208 180 C56F7C92
                MOVB    off(00293h), #03dh     ; 0C16 0 208 180 C493983D
                MOVB    off(002ebh), #01eh     ; 0C1A 0 208 180 C4EB981E
                MOV     (0016ch-00180h)[USP], #000fah ; 0C1E 0 208 180 B3EC98FA00
                MOV     (0016ah-00180h)[USP], #000f4h ; 0C23 0 208 180 B3EA98F400
                CAL     clamp_result_store_sub_load_dp             ; 0C28 0 208 180 32104D
                MOV     0ach, #0ffffh          ; 0C2B 0 208 180 B5AC98FFFF
                SB      off(00235h).1          ; 0C30 0 208 180 C43519
                SB      off(0022ch).1          ; 0C33 0 208 180 C42C19
                SB      off(00235h).7          ; 0C36 0 208 180 C4351F
                RB      off(00215h).0          ; 0C39 0 208 180 C41508
                LB      A, #0ffh               ; 0C3C 0 208 180 77FF
                STB     A, off(002edh)         ; 0C3E 0 208 180 D4ED
                MOVB    off(002cfh), #005h     ; 0C40 0 208 180 C4CF9805
                NOP                            ; 0C44 0 208 180 00
                NOP                            ; 0C45 0 208 180 00
                NOP                            ; 0C46 0 208 180 00
                MOV     off(0027ch), #00086h   ; 0C47 0 208 180 B47C988600
                CAL     vss_clamp_common_sub_load_dp             ; 0C4C 0 208 180 32C849
                MOVB    PWMPRE, #093h            ; 0C4F 0 208 180 C52D9893
                MOVB    PWM0CON, #003h            ; 0C53 0 208 180 C52A9803
                MOVB    PWMIE, #000h            ; 0C57 0 208 180 C52B9800
                MOV     PWM1CMP, #09ff6h          ; 0C5B 0 208 180 B53E98F69F
                MOVB    PWM1CON, #06fh              ; 0C60 0 208 180 C52C986F
                MOV     PWM0CMP, #00001h          ; 0C64 0 208 180 B52E980100
                MOVB    0d4h, #063h            ; 0C69 0 208 180 C5D49863
                L       A, OS0                 ; 0C6D 1 208 180 E544
                XOR     A, #0ffffh             ; 0C6F 1 208 180 F6FFFF
                MOV     DP, #0032ch            ; 0C72 1 208 180 622C03
                ST      A, [DP]                ; 0C75 1 208 180 D2
                MOV     OS0, #0ffffh           ; 0C76 1 208 180 B54498FFFF
                J       clamp_result_store_nop_acc             ; 0C7B 1 208 180 033E0E
calchecksum_loop_nop_acc:     NOP                            ; 0C7E 1 208 180 00
                NOP                            ; 0C7F 1 208 180 00
                NOP                            ; 0C80 1 208 180 00
                NOP                            ; 0C81 1 208 180 00
                NOP                            ; 0C82 1 208 180 00
                NOP                            ; 0C83 1 208 180 00
                CMP     off(0027ch), #0047eh   ; 0C84 1 208 180 B47CC07E04
                JLE     calchecksum_loop_load_dp             ; 0C89 1 208 180 CF13
                L       A, #05555h             ; 0C8B 1 208 180 675555
                CAL     calchecksum_loop_sub_load_x1             ; 0C8E 1 208 180 326F43
                JNE     calchecksum_loop_load_ram0d4             ; 0C91 1 208 180 CE3C
                SLL     A                      ; 0C93 1 208 180 53
                CAL     calchecksum_loop_sub_load_x1             ; 0C94 1 208 180 326F43
                JNE     calchecksum_loop_load_ram0d4             ; 0C97 1 208 180 CE36
                MOV     off(0027ch), #00086h   ; 0C99 1 208 180 B47C988600
calchecksum_loop_load_dp:     MOV     DP, off(0027ch)        ; 0C9E 1 208 180 B47C7A
                RB      PSWH.0                 ; 0CA1 1 208 180 A208
                MOV     er0, TIMER             ; 0CA3 1 208 180 B55648
                L       A, [DP]                ; 0CA6 1 208 180 E2
                SB      09fh.7                 ; 0CA7 1 208 180 C59F1F
                MOV     [DP], #05555h          ; 0CAA 1 208 180 B2985555
                MOV     X1, [DP]               ; 0CAE 1 208 180 B278
                MOV     [DP], #0aaaah          ; 0CB0 1 208 180 B298AAAA
                MOV     X2, [DP]               ; 0CB4 1 208 180 B279
                ST      A, [DP]                ; 0CB6 1 208 180 D2
                RB      09fh.7                 ; 0CB7 1 208 180 C59F0F
                L       A, TIMER               ; 0CBA 1 208 180 E556
                MB      C, IRQ.4               ; 0CBC 1 208 180 C5182C
                SB      PSWH.0                 ; 0CBF 1 208 180 A218
                MB      PSWL.4, C              ; 0CC1 1 208 180 A33C
                CMP     X1, #05555h            ; 0CC3 1 208 180 90C05555
                JNE     calchecksum_loop_load_ram0d4             ; 0CC7 1 208 180 CE06
                CMP     X2, #0aaaah            ; 0CC9 1 208 180 91C0AAAA
                JEQ     calchecksum_loop_add_ram27c             ; 0CCD 1 208 180 C907
calchecksum_loop_load_ram0d4:     MOVB    0d4h, #04ah            ; 0CCF 1 208 180 C5D4984A
                J       fault_retry_check_nop_acc             ; 0CD3 1 208 180 035807
calchecksum_loop_add_ram27c:     ADD     off(0027ch), #00002h   ; 0CD6 1 208 180 B47C800200
                SUB     A, er0                 ; 0CDB 1 208 180 28
                JEQ     calchecksum_loop_load_ram0d4_2             ; 0CDC 1 208 180 C90B
                JGE     calchecksum_loop_cmp_acc             ; 0CDE 1 208 180 CD04
                MB      C, PSWL.4              ; 0CE0 1 208 180 A32C
                JGE     calchecksum_loop_load_ram0d4_2             ; 0CE2 1 208 180 CD05
calchecksum_loop_cmp_acc:     CMP     A, #00006h             ; 0CE4 1 208 180 C60600
                JLT     calchecksum_loop_vcal_4             ; 0CE7 1 208 180 CA07
calchecksum_loop_load_ram0d4_2:     MOVB    0d4h, #053h            ; 0CE9 1 208 180 C5D49853
                J       fault_retry_check_nop_acc             ; 0CED 1 208 180 035807
calchecksum_loop_vcal_4:     VCAL    4                      ; 0CF0 1 208 180 14
                MOV     DP, #003a6h            ; 0CF1 1 208 180 62A603
                MOV     er0, [DP]              ; 0CF4 1 208 180 B248
                CLR     A                      ; 0CF6 1 208 180 F9
                LB      A, #040h               ; 0CF7 0 208 180 7740
                MUL                            ; 0CF9 0 208 180 9035
                MOV     X1, A                  ; 0CFB 0 208 180 50
                MOV     DP, #00020h            ; 0CFC 0 208 180 622000
                MOV     X2, #003a8h            ; 0CFF 0 208 180 61A803
                MOVB    r0, 00000h[X2]         ; 0D02 0 208 180 C1000048
calchecksum_loop_rom_load_tbl_x1:     LC      A, [X1]                ; 0D06 0 208 180 90A8
                ADDB    A, ACCH                ; 0D08 0 208 180 C50782
                ADDB    r0, A                  ; 0D0B 0 208 180 2081
                INC     X1                     ; 0D0D 0 208 180 70
                INC     X1                     ; 0D0E 0 208 180 70
                JRNZ    DP, calchecksum_loop_rom_load_tbl_x1         ; 0D0F 0 208 180 30F5
                LB      A, r0                  ; 0D11 0 208 180 78
                STB     A, 00000h[X2]          ; 0D12 0 208 180 D10000
                MOV     DP, #003a6h            ; 0D15 0 208 180 62A603
                INC     [DP]                   ; 0D18 0 208 180 B216
                CMP     [DP], #00200h          ; 0D1A 0 208 180 B2C00002
                JNE     calchecksum_loop_vcal_4_2             ; 0D1E 0 208 180 CE16
                CLR     [DP]                   ; 0D20 0 208 180 B215
                LCB     A, 07ff1h              ; 0D22 0 208 180 909DF17F
                JEQ     calchecksum_loop_vcal_4_2             ; 0D26 0 208 180 C90E
                LB      A, r0                  ; 0D28 0 208 180 78
                JEQ     calchecksum_loop_vcal_4_2             ; 0D29 0 208 180 C90B
                CLRB    00000h[X2]             ; 0D2B 0 208 180 C1000015
                MOVB    0d4h, #04bh            ; 0D2F 0 208 180 C5D4984B
                J       fault_retry_check_nop_acc             ; 0D33 0 208 180 035807
calchecksum_loop_vcal_4_2:     VCAL    4                      ; 0D36 0 208 180 14
                RB      PSWH.0                 ; 0D37 0 208 180 A208
                MB      C, P4SF.4              ; 0D39 0 208 180 C51F2C
                JGE     calchecksum_loop_set_pswh_bit0             ; 0D3C 0 208 180 CD58
                L       A, PWM1CNT               ; 0D3E 1 208 180 E540
                MB      C, P4.4                ; 0D40 1 208 180 C5212C
                MOV     er3, PWM1CNT             ; 0D43 1 208 180 B5404B
                SB      PSWH.0                 ; 0D46 1 208 180 A218
                MB      PSWL.4, C              ; 0D48 1 208 180 A33C
                CMP     A, er3                 ; 0D4A 1 208 180 4B
                JEQ     calchecksum_loop_load_r0             ; 0D4B 1 208 180 C93F
                CMP     A, #05ff6h                         ; 0D4D 1 208 180 C6F65F
                JGT     calchecksum_loop_cmp_er3             ; 0D50 1 208 180 C80E
                CMP     A, #0000ah             ; 0D52 1 208 180 C60A00
                JLT     calchecksum_loop_clear_pswh_bit0             ; 0D55 1 208 180 CA42
                SB      off(00233h).2          ; 0D57 1 208 180 C4331A
                MB      C, PSWL.4              ; 0D5A 1 208 180 A32C
                JGE     calchecksum_loop_clear_pswh_bit0             ; 0D5C 1 208 180 CD3B
                SJ      calchecksum_loop_load_r0             ; 0D5E 1 208 180 CB2C
calchecksum_loop_cmp_er3:     CMP     er3, #0a00ah           ; 0D60 1 208 180 47C00AA0
                JLT     calchecksum_loop_clear_pswh_bit0             ; 0D64 1 208 180 CA33
                CMP     er3, #0fff6h           ; 0D66 1 208 180 47C0F6FF
                JGT     calchecksum_loop_clear_pswh_bit0             ; 0D6A 1 208 180 C82D
                RB      off(00233h).2          ; 0D6C 1 208 180 C4330A
                JEQ     calchecksum_loop_load_carry_pswl_bit4             ; 0D6F 1 208 180 C917
                MB      C, IRQH.1              ; 0D71 1 208 180 C51929
                JBR     off(0022eh).2, calchecksum_loop_if_lt_goto_0d88 ; 0D74 1 208 180 DA2E03
                RB      IRQH.1                 ; 0D77 1 208 180 C51909
calchecksum_loop_if_lt_goto_0d88:     JLT     calchecksum_loop_load_carry_pswl_bit4             ; 0D7A 1 208 180 CA0C
                MOVB    r0, #059h              ; 0D7C 1 208 180 9859
calchecksum_loop_load_dp_2:     MOV     DP, #0035eh            ; 0D7E 1 208 180 625E03
                ST      A, [DP]                ; 0D81 1 208 180 D2
                INC     DP                     ; 0D82 1 208 180 72
                INC     DP                     ; 0D83 1 208 180 72
                L       A, er3                 ; 0D84 1 208 180 37
                ST      A, [DP]                ; 0D85 1 208 180 D2
                SJ      calchecksum_loop_load_r0_2             ; 0D86 1 208 180 CB08
calchecksum_loop_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 0D88 1 208 180 A32C
                JLT     calchecksum_loop_clear_pswh_bit0             ; 0D8A 1 208 180 CA0D
calchecksum_loop_load_r0:     MOVB    r0, #058h              ; 0D8C 1 208 180 9858
                SJ      calchecksum_loop_load_dp_2             ; 0D8E 1 208 180 CBEE
calchecksum_loop_load_r0_2:     LB      A, r0                  ; 0D90 0 208 180 78
                CAL     idle_init_start_sub_cmp_ram0d7             ; 0D91 0 208 180 32F849
                SJ      calchecksum_loop_clear_pswh_bit0             ; 0D94 0 208 180 CB03
calchecksum_loop_set_pswh_bit0:     SB      PSWH.0                 ; 0D96 0 208 180 A218
                NOP                            ; 0D98 0 208 180 00
calchecksum_loop_clear_pswh_bit0:     RB      PSWH.0                 ; 0D99 0 208 180 A208
                L       A, PWM0CNT                 ; 0D9B 1 208 180 E530
                MB      C, P4.0                ; 0D9D 1 208 180 C52128
                MOV     er3, PWM0CNT               ; 0DA0 1 208 180 B5304B
                SB      PSWH.0                 ; 0DA3 1 208 180 A218
                MB      PSWL.4, C              ; 0DA5 1 208 180 A33C
                CMP     A, er3                 ; 0DA7 1 208 180 4B
                JEQ     calchecksum_loop_load_dp_3             ; 0DA8 1 208 180 C920
                CMP     A, #007f6h             ; 0DAA 1 208 180 C6F607
                JGT     calchecksum_loop_cmp_er3_2             ; 0DAD 1 208 180 C80B
                CMP     A, #0000ah             ; 0DAF 1 208 180 C60A00
                JLT     calchecksum_loop_load_ie             ; 0DB2 1 208 180 CA23
                MB      C, PSWL.4              ; 0DB4 1 208 180 A32C
                JGE     calchecksum_loop_load_ie             ; 0DB6 1 208 180 CD1F
                SJ      calchecksum_loop_load_dp_3             ; 0DB8 1 208 180 CB10
calchecksum_loop_cmp_er3_2:     CMP     er3, #0f80ah           ; 0DBA 1 208 180 47C00AF8
                JLT     calchecksum_loop_load_ie             ; 0DBE 1 208 180 CA17
                CMP     er3, #0fff6h           ; 0DC0 1 208 180 47C0F6FF
                JGT     calchecksum_loop_load_ie             ; 0DC4 1 208 180 C811
                MB      C, PSWL.4              ; 0DC6 1 208 180 A32C
                JLT     calchecksum_loop_load_ie             ; 0DC8 1 208 180 CA0D
calchecksum_loop_load_dp_3:     MOV     DP, #0035eh            ; 0DCA 1 208 180 625E03
                ST      A, [DP]                ; 0DCD 1 208 180 D2
                INC     DP                     ; 0DCE 1 208 180 72
                INC     DP                     ; 0DCF 1 208 180 72
                L       A, er3                 ; 0DD0 1 208 180 37
                ST      A, [DP]                ; 0DD1 1 208 180 D2
                LB      A, #05ah               ; 0DD2 0 208 180 775A
                CAL     idle_init_start_sub_cmp_ram0d7             ; 0DD4 0 208 180 32F849
calchecksum_loop_load_ie:     L       A, IE                  ; 0DD7 1 208 180 E51A
                CMP     A, #0141bh             ; 0DD9 1 208 180 C61B14
                JNE     calchecksum_loop_load_ram0d4_3             ; 0DDC 1 208 180 CE22
                RB      PSWH.0                 ; 0DDE 1 208 180 A208
                MOV     IE, #05555h            ; 0DE0 1 208 180 B51A985555
                MOV     X1, IE                 ; 0DE5 1 208 180 B51A78
                MOV     IE, #0aaaah            ; 0DE8 1 208 180 B51A98AAAA
                MOV     X2, IE                 ; 0DED 1 208 180 B51A79
                ST      A, IE                  ; 0DF0 1 208 180 D51A
                SB      PSWH.0                 ; 0DF2 1 208 180 A218
                CMP     X1, #05555h            ; 0DF4 1 208 180 90C05555
                JNE     calchecksum_loop_load_ram0d4_3             ; 0DF8 1 208 180 CE06
                CMP     X2, #0aaaah            ; 0DFA 1 208 180 91C0AAAA
                JEQ     calchecksum_loop_set_carry             ; 0DFE 1 208 180 C907
calchecksum_loop_load_ram0d4_3:     MOVB    0d4h, #050h            ; 0E00 1 208 180 C5D49850
                J       fault_retry_check             ; 0E04 1 208 180 034C07
calchecksum_loop_set_carry:     SC                             ; 0E07 1 208 180 85
                RB      PSWH.0                 ; 0E08 1 208 180 A208
                JBS     off(00210h).3, calchecksum_loop_if_ge_goto_0e30 ; 0E0A 1 208 180 EB1016
                JBS     off(00214h).7, calchecksum_loop_set_pswh_bit0_2 ; 0E0D 1 208 180 EF140B
                RB      TRNSIT.7                 ; 0E10 1 208 180 C5290F
                JEQ     calchecksum_loop_set_pswh_bit0_2             ; 0E13 1 208 180 C906
                SB      09fh.2                 ; 0E15 1 208 180 C59F1A
dtc04_ckp_latch_2: SB      09ch.0                 ; 0E18 1 208 180 C59C18
calchecksum_loop_set_pswh_bit0_2:     SB      PSWH.0                 ; 0E1B 1 208 180 A218
                CMPB    (001a0h-00180h)[USP], #029h ; 0E1D 1 208 180 C320C029
                RB      PSWH.0                 ; 0E21 1 208 180 A208
calchecksum_loop_if_ge_goto_0e30:     JGE     calchecksum_loop_if_ram214_bit7_clr             ; 0E23 1 208 180 CD0B
                JBS     off(00214h).7, calchecksum_loop_store_carry_ram214_bit7 ; 0E25 1 208 180 EF140E
                RB      (0011ah-00180h)[USP].7 ; 0E28 1 208 180 C39A0F
                RB      off(0021ah).7          ; 0E2B 1 208 180 C41A0F
                SJ      calchecksum_loop_store_carry_ram214_bit7             ; 0E2E 1 208 180 CB06
calchecksum_loop_if_ram214_bit7_clr:     JBR     off(00214h).7, calchecksum_loop_store_carry_ram214_bit7 ; 0E30 1 208 180 DF1403
                CAL     crank_tooth_count_store_sub_clear_ram0a0_bit6             ; 0E33 1 208 180 325046
calchecksum_loop_store_carry_ram214_bit7:     MB      off(00214h).7, C       ; 0E36 1 208 180 C4143F
                MB      TCON.4, C              ; 0E39 1 208 180 C5543C
                SB      PSWH.0                 ; 0E3C 1 208 180 A218
clamp_result_store_nop_acc:     NOP                            ; 0E3E 1 208 180 00
                NOP                            ; 0E3F 1 208 180 00
                NOP                            ; 0E40 1 208 180 00
                L       A, #05555h             ; 0E41 1 208 180 675555
                MB      C, PSWH.4              ; 0E44 1 208 180 A22C
                JGE     clamp_result_store_load_ram0d4             ; 0E46 1 208 180 CD6A
                MOV     X1, #0aaaah            ; 0E48 1 208 180 60AAAA
                CMP     SSP, #0047fh           ; 0E4B 1 208 180 A0C07F04
                JNE     clamp_result_store_load_ram0d4             ; 0E4F 1 208 180 CE61
                RB      PSWH.0                 ; 0E51 1 208 180 A208
                JEQ     clamp_result_store_load_ram0d4             ; 0E53 1 208 180 C95D
                MOV     SSP, A                 ; 0E55 1 208 180 A08A
                MOV     A, SSP                 ; 0E57 1 208 180 A099
                MOV     SSP, X1                ; 0E59 1 208 180 907E
                MOV     X1, SSP                ; 0E5B 1 208 180 A078
                MOV     SSP, #0047fh           ; 0E5D 1 208 180 A0987F04
                SB      PSWH.0                 ; 0E61 1 208 180 A218
                JNE     clamp_result_store_load_ram0d4             ; 0E63 1 208 180 CE4D
                CMP     A, #05555h             ; 0E65 1 208 180 C65555
                JNE     clamp_result_store_load_ram0d4             ; 0E68 1 208 180 CE48
                XCHG    A, X1                  ; 0E6A 1 208 180 9010
                CMP     A, #0aaaah             ; 0E6C 1 208 180 C6AAAA
                JNE     clamp_result_store_load_ram0d4             ; 0E6F 1 208 180 CE41
                CMP     LRB, #00041h           ; 0E71 1 208 180 A4C04100
                JNE     clamp_result_store_load_ram0d4             ; 0E75 1 208 180 CE3B
                RB      PSWH.0                 ; 0E77 1 208 180 A208
                MOV     LRB, A                 ; 0E79 1 208 180 A48A
                MOV     A, LRB                 ; 0E7B 1 208 180 A499
                MOV     LRB, X1                ; 0E7D 1 208 180 907F
                MOV     X1, LRB                ; 0E7F 1 208 180 A478
                MOV     LRB, #00041h           ; 0E81 1 208 180 574100
                SB      PSWH.0                 ; 0E84 1 208 180 A218
                CMP     A, #0aaaah             ; 0E86 1 208 180 C6AAAA
                JNE     clamp_result_store_load_ram0d4             ; 0E89 1 208 180 CE27
                SRL     A                      ; 0E8B 1 208 180 63
                CMP     A, X1                  ; 0E8C 1 208 180 90C2
                JNE     clamp_result_store_load_ram0d4             ; 0E8E 1 208 180 CE22
                MOVB    A, PSWL                ; 0E90 0 208 180 A399
                MB      C, PSWH.4              ; 0E92 0 208 180 A22C
                JLT     clamp_result_store_load_ram0d4             ; 0E94 0 208 180 CA1C
                ANDB    A, #007h               ; 0E96 0 208 180 D607
                CMPB    A, #000h               ; 0E98 0 208 180 C600
                JNE     clamp_result_store_load_ram0d4             ; 0E9A 0 208 180 CE16
                MOVB    PSWL, #055h            ; 0E9C 0 208 180 A39855
                LB      A, PSW                 ; 0E9F 0 208 180 F504
                ANDB    A, #037h               ; 0EA1 0 208 180 D637
                CMPB    A, #015h               ; 0EA3 0 208 180 C615
                JNE     clamp_result_store_load_ram0d4             ; 0EA5 0 208 180 CE0B
                MOVB    PSWL, #0aah            ; 0EA7 0 208 180 A398AA
                LB      A, PSW                 ; 0EAA 0 208 180 F504
                ANDB    A, #037h               ; 0EAC 0 208 180 D637
                CMPB    A, #022h               ; 0EAE 0 208 180 C622
                JEQ     clamp_result_store_load_pswl             ; 0EB0 0 208 180 C907
clamp_result_store_load_ram0d4:     MOVB    0d4h, #046h            ; 0EB2 0 208 180 C5D49846
                J       fault_retry_check_nop_acc             ; 0EB6 0 208 180 035807
clamp_result_store_load_pswl:     MOVB    PSWL, #000h            ; 0EB9 0 208 180 A39800
                CMPB    PCLK, #0a4h            ; 0EBC 0 208 180 C50FC0A4
                JNE     clamp_result_store_load_ram0d4_2             ; 0EC0 0 208 180 CE66
                LB      A, P4SF                ; 0EC2 0 208 180 F51F
                ANDB    A, #0efh               ; 0EC4 0 208 180 D6EF
                CMPB    A, #001h               ; 0EC6 0 208 180 C601
                JNE     clamp_result_store_load_ram0d4_2             ; 0EC8 0 208 180 CE5E
                CMPB    P4IO, #011h              ; 0ECA 0 208 180 C520C011
                JNE     clamp_result_store_load_ram0d4_2             ; 0ECE 0 208 180 CE58
                CMPB    P3SF, #0f0h              ; 0ED0 0 208 180 C522C0F0
                JNE     clamp_result_store_load_ram0d4_2             ; 0ED4 0 208 180 CE52
                CMPB    P3IO, #0ffh            ; 0ED6 0 208 180 C523C0FF
                JNE     clamp_result_store_load_ram0d4_2             ; 0EDA 0 208 180 CE4C
                LB      A, P2A                 ; 0EDC 0 208 180 F525
                ANDB    A, #060h               ; 0EDE 0 208 180 D660
                CMPB    A, #060h               ; 0EE0 0 208 180 C660
                JNE     clamp_result_store_load_ram0d4_2             ; 0EE2 0 208 180 CE44
                LB      A, P2SF                ; 0EE4 0 208 180 F526
                ANDB    A, #00eh               ; 0EE6 0 208 180 D60E
                CMPB    A, #006h               ; 0EE8 0 208 180 C606
                JNE     clamp_result_store_load_ram0d4_2             ; 0EEA 0 208 180 CE3C
                CMPB    PWM0CON, #003h            ; 0EEC 0 208 180 C52AC003
                JNE     clamp_result_store_load_ram0d4_2             ; 0EF0 0 208 180 CE36
                LB      A, PWM1CON                  ; 0EF2 0 208 180 F52C
                ANDB    A, #0efh               ; 0EF4 0 208 180 D6EF
                CMPB    A, #06fh               ; 0EF6 0 208 180 C66F
                JNE     clamp_result_store_load_ram0d4_2             ; 0EF8 0 208 180 CE2E
                LB      A, PWMPRE                ; 0EFA 0 208 180 F52D
                CMPB    A, #093h               ; 0EFC 0 208 180 C693
                JNE     clamp_result_store_load_ram0d4_2             ; 0EFE 0 208 180 CE28
                LB      A, TCON                ; 0F00 0 208 180 F554
                ANDB    A, #0efh               ; 0F02 0 208 180 D6EF
                CMPB    A, #089h               ; 0F04 0 208 180 C689
                JNE     clamp_result_store_load_ram0d4_2             ; 0F06 0 208 180 CE20
                LB      A, TCON2               ; 0F08 0 208 180 F555
                ANDB    A, #077h               ; 0F0A 0 208 180 D677
                CMPB    A, #000h               ; 0F0C 0 208 180 C600
                JNE     clamp_result_store_load_ram0d4_2             ; 0F0E 0 208 180 CE18
                LB      A, IGNCON              ; 0F10 0 208 180 F561
                ANDB    A, #0b0h               ; 0F12 0 208 180 D6B0
                CMPB    A, #010h               ; 0F14 0 208 180 C610
                JNE     clamp_result_store_load_ram0d4_2             ; 0F16 0 208 180 CE10
                LB      A, ADSCAN               ; 0F18 0 208 180 F566
                ANDB    A, #057h               ; 0F1A 0 208 180 D657
                CMPB    A, #010h               ; 0F1C 0 208 180 C610
                JNE     clamp_result_store_load_ram0d4_2             ; 0F1E 0 208 180 CE08
                LB      A, ADSEL               ; 0F20 0 208 180 F567
                ANDB    A, #04fh               ; 0F22 0 208 180 D64F
                CMPB    A, #000h               ; 0F24 0 208 180 C600
                JEQ     clamp_result_store_load_r0             ; 0F26 0 208 180 C907
clamp_result_store_load_ram0d4_2:     MOVB    0d4h, #04eh            ; 0F28 0 208 180 C5D4984E
                J       fault_retry_check_nop_acc             ; 0F2C 0 208 180 035807
clamp_result_store_load_r0:     MOVB    r0, #020h              ; 0F2F 0 208 180 9820
                MOVB    r1, #080h              ; 0F31 0 208 180 9980
                MOVB    r2, #080h              ; 0F33 0 208 180 9A80
                MOVB    r3, #020h              ; 0F35 0 208 180 9B20
                MB      C, 0a0h.7              ; 0F37 0 208 180 C5A02F
                JLT     clamp_result_store_load_sttmr             ; 0F3A 0 208 180 CA08
                MOVB    r0, #004h              ; 0F3C 0 208 180 9804
                CAL     clamp_result_store_sub_load_r1             ; 0F3E 0 208 180 32384E
                NOP                            ; 0F41 0 208 180 00
                MOVB    r3, #020h              ; 0F42 0 208 180 9B20
clamp_result_store_load_sttmr:     LB      A, STTMR               ; 0F44 0 208 180 F578
                CMPB    A, r0                  ; 0F46 0 208 180 48
                JNE     clamp_result_store_load_ram0d4_2             ; 0F47 0 208 180 CEDF
                LB      A, SCONA               ; 0F49 0 208 180 F57A
                ANDB    A, #0f5h               ; 0F4B 0 208 180 D6F5
                CMPB    A, r1                  ; 0F4D 0 208 180 49
                JNE     clamp_result_store_load_ram0d4_2             ; 0F4E 0 208 180 CED8
                LB      A, SCONB                ; 0F50 0 208 180 F57B
                ANDB    A, #0e5h               ; 0F52 0 208 180 D6E5
                CMPB    A, r2                  ; 0F54 0 208 180 4A
                JNE     clamp_result_store_load_ram0d4_2             ; 0F55 0 208 180 CED1
                LB      A, SRSTAT                ; 0F57 0 208 180 F57E
                ANDB    A, #030h               ; 0F59 0 208 180 D630
                CMPB    A, r3                  ; 0F5B 0 208 180 4B
                JNE     clamp_result_store_load_ram0d4_2             ; 0F5C 0 208 180 CECA
                SB      P4.4                   ; 0F5E 0 208 180 C5211C
                RB      P3.4                   ; 0F61 0 208 180 C5240C
                RB      P3.5                   ; 0F64 0 208 180 C5240D
                RB      P3.6                   ; 0F67 0 208 180 C5240E
                RB      P3.7                   ; 0F6A 0 208 180 C5240F
                CLR     A                      ; 0F6D 1 208 180 F9
                CLRB    A                      ; 0F6E 0 208 180 FA
                LCB     A, 07ff1h              ; 0F6F 0 208 180 909DF17F
                STB     A, r1                  ; 0F73 0 208 180 89
                JNE     clamp_result_store_load_dp             ; 0F74 0 208 180 CE06
                LCB     A, 07ff2h              ; 0F76 0 208 180 909DF27F
                SJ      clamp_result_store_andb_acc             ; 0F7A 0 208 180 CB38
clamp_result_store_load_dp:     MOV     DP, #003d1h            ; 0F7C 0 208 180 62D103
                LB      A, [DP]                ; 0F7F 0 208 180 F2
                ADDB    A, #020h               ; 0F80 0 208 180 8620
                JGE     clamp_result_store_srlb_acc             ; 0F82 0 208 180 CD04
                LB      A, #004h               ; 0F84 0 208 180 7704
                SJ      clamp_result_store_load_r0_2             ; 0F86 0 208 180 CB05
clamp_result_store_srlb_acc:     SRLB    A                      ; 0F88 0 208 180 63
                SRLB    A                      ; 0F89 0 208 180 63
                ANDB    A, #0f0h               ; 0F8A 0 208 180 D6F0
                SWAPB                          ; 0F8C 0 208 180 83
clamp_result_store_load_r0_2:     MOVB    r0, #005h              ; 0F8D 0 208 180 9805
                MULB                           ; 0F8F 0 208 180 A234
                STB     A, r0                  ; 0F91 0 208 180 88
                MOV     DP, #003d9h            ; 0F92 0 208 180 62D903
                LB      A, [DP]                ; 0F95 0 208 180 F2
                ADDB    A, #020h               ; 0F96 0 208 180 8620
                JGE     clamp_result_store_srlb_acc_2             ; 0F98 0 208 180 CD04
                LB      A, #004h               ; 0F9A 0 208 180 7704
                SJ      clamp_result_store_addb_acc             ; 0F9C 0 208 180 CB05
clamp_result_store_srlb_acc_2:     SRLB    A                      ; 0F9E 0 208 180 63
                SRLB    A                      ; 0F9F 0 208 180 63
                ANDB    A, #0f0h               ; 0FA0 0 208 180 D6F0
                SWAPB                          ; 0FA2 0 208 180 83
clamp_result_store_addb_acc:     ADDB    A, r0                  ; 0FA3 0 208 180 08
                LCB     A, clamp_result_store_tbl_3[ACC]       ; 0FA4 0 208 180 B506AB566D
                CMPB    A, #0ffh               ; 0FA9 0 208 180 C6FF
                JNE     clamp_result_store_andb_acc             ; 0FAB 0 208 180 CE07
                MOVB    0d4h, #056h            ; 0FAD 0 208 180 C5D49856
                J       fault_retry_check_nop_acc             ; 0FB1 0 208 180 035807
clamp_result_store_andb_acc:     ANDB    A, #03fh               ; 0FB4 0 208 180 D63F
                MOV     DP, #003a9h            ; 0FB6 0 208 180 62A903
                STB     A, [DP]                ; 0FB9 0 208 180 D2
                SLLB    A                      ; 0FBA 0 208 180 53
                SLLB    A                      ; 0FBB 0 208 180 53
                MOV     X1, A                  ; 0FBC 0 208 180 50
                ADD     X1, #clamp_result_store_tbl_2          ; 0FBD 0 208 180 9080FF6C
                LB      A, r1                  ; 0FC1 0 208 180 79
                JEQ     clamp_result_store_rom_load_ram7ff3             ; 0FC2 0 208 180 C910
                MOV     DP, #003d5h            ; 0FC4 0 208 180 62D503
                LB      A, [DP]                ; 0FC7 0 208 180 F2
                ADDB    A, #020h               ; 0FC8 0 208 180 8620
                JGE     clamp_result_store_sllb_acc             ; 0FCA 0 208 180 CD02
                LB      A, #080h               ; 0FCC 0 208 180 7780
clamp_result_store_sllb_acc:     SLLB    A                      ; 0FCE 0 208 180 53
                MB      PSWL.4, C              ; 0FCF 0 208 180 A33C
                SLLB    A                      ; 0FD1 0 208 180 53
                SJ      clamp_result_store_rom_load_tbl_x1             ; 0FD2 0 208 180 CB18
clamp_result_store_rom_load_ram7ff3:     LCB     A, 07ff3h              ; 0FD4 0 208 180 909DF37F
                SRLB    A                      ; 0FD8 0 208 180 63
                MB      PSWL.4, C              ; 0FD9 0 208 180 A33C
                SRLB    A                      ; 0FDB 0 208 180 63
                JLT     clamp_result_store_srlb_acc_3             ; 0FDC 0 208 180 CA0D
                SC                             ; 0FDE 0 208 180 85
                JBS     off(00224h).5, clamp_result_store_store_carry_pswl_bit4 ; 0FDF 0 208 180 ED2407
                RC                             ; 0FE2 0 208 180 95
                JBS     off(00214h).0, clamp_result_store_store_carry_pswl_bit4 ; 0FE3 0 208 180 E81403
                MB      C, off(00220h).0       ; 0FE6 0 208 180 C42028
clamp_result_store_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 0FE9 0 208 180 A33C
clamp_result_store_srlb_acc_3:     SRLB    A                      ; 0FEB 0 208 180 63
clamp_result_store_rom_load_tbl_x1:     LCB     A, 00002h[X1]          ; 0FEC 0 208 180 90AB0200
                ANDB    A, #05dh               ; 0FF0 0 208 180 D65D
                MB      ACC.6, C               ; 0FF2 0 208 180 C5063E
                SRLB    A                      ; 0FF5 0 208 180 63
                MB      C, PSWL.4              ; 0FF6 0 208 180 A32C
                ROLB    A                      ; 0FF8 0 208 180 33
                STB     A, r0                  ; 0FF9 0 208 180 88
                MOVB    r1, #0a2h              ; 0FFA 0 208 180 99A2
                RB      PSWH.0                 ; 0FFC 0 208 180 A208
                LB      A, off(00220h)         ; 0FFE 0 208 180 F420
                ANDB    A, r1                  ; 1000 0 208 180 59
                ORB     A, r0                  ; 1001 0 208 180 68
                STB     A, off(00220h)         ; 1002 0 208 180 D420
                LB      A, (00120h-00180h)[USP] ; 1004 0 208 180 F3A0
                ANDB    A, r1                  ; 1006 0 208 180 59
                ORB     A, r0                  ; 1007 0 208 180 68
                STB     A, (00120h-00180h)[USP] ; 1008 0 208 180 D3A0
                SB      PSWH.0                 ; 100A 0 208 180 A218
                LCB     A, 00001h[X1]          ; 100C 0 208 180 90AB0100
                ANDB    A, #02fh               ; 1010 0 208 180 D62F
                STB     A, r0                  ; 1012 0 208 180 88
                MOVB    r1, #0d0h              ; 1013 0 208 180 99D0
                RB      PSWH.0                 ; 1015 0 208 180 A208
                LB      A, off(0021fh)         ; 1017 0 208 180 F41F
                ANDB    A, r1                  ; 1019 0 208 180 59
                ORB     A, r0                  ; 101A 0 208 180 68
                STB     A, off(0021fh)         ; 101B 0 208 180 D41F
                LB      A, (0011fh-00180h)[USP] ; 101D 0 208 180 F39F
                ANDB    A, r1                  ; 101F 0 208 180 59
                ORB     A, r0                  ; 1020 0 208 180 68
                STB     A, (0011fh-00180h)[USP] ; 1021 0 208 180 D39F
                SB      PSWH.0                 ; 1023 0 208 180 A218
                LCB     A, 00003h[X1]          ; 1025 0 208 180 90AB0300
                ANDB    A, #007h               ; 1029 0 208 180 D607
                STB     A, r0                  ; 102B 0 208 180 88
                MOVB    r1, #0f8h              ; 102C 0 208 180 99F8
                NOP                            ; 102E 0 208 180 00
                RB      PSWH.0                 ; 102F 0 208 180 A208
                LB      A, off(00221h)         ; 1031 0 208 180 F421
                ANDB    A, r1                  ; 1033 0 208 180 59
                ORB     A, r0                  ; 1034 0 208 180 68
                STB     A, off(00221h)         ; 1035 0 208 180 D421
                LB      A, (00121h-00180h)[USP] ; 1037 0 208 180 F3A1
                ANDB    A, r1                  ; 1039 0 208 180 59
                ORB     A, r0                  ; 103A 0 208 180 68
                STB     A, (00121h-00180h)[USP] ; 103B 0 208 180 D3A1
                SB      PSWH.0                 ; 103D 0 208 180 A218
                LCB     A, 07ff1h              ; 103F 0 208 180 909DF17F
                JNE     clamp_result_store_load_dp_2             ; 1043 0 208 180 CE06
                LCB     A, 07ff3h              ; 1045 0 208 180 909DF37F
                SJ      clamp_result_store_sllb_acc_2             ; 1049 0 208 180 CB04
clamp_result_store_load_dp_2:     MOV     DP, #003dfh            ; 104B 0 208 180 62DF03
                LB      A, [DP]                ; 104E 0 208 180 F2
clamp_result_store_sllb_acc_2:     SLLB    A                      ; 104F 0 208 180 53
                MB      0a0h.7, C              ; 1050 0 208 180 C5A03F
                VCAL    4                      ; 1053 0 208 180 14
                MOVB    r0, #001h              ; 1054 0 208 180 9801
                JBR     off(00214h).7, clamp_result_store_clear_pswh_bit0 ; 1056 0 208 180 DF1402
                MOVB    r0, #006h              ; 1059 0 208 180 9806
clamp_result_store_clear_pswh_bit0:     RB      PSWH.0                 ; 105B 0 208 180 A208
                RB      off(00235h).7          ; 105D 0 208 180 C4350F
                JBR     off(00216h).0, warmcold_tm2_check ; 1060 0 208 180 D81603
                J       warmcold_tm2_check_nop_acc             ; 1063 0 208 180 031311
warmcold_tm2_check:     JNE     warmcold_tm2_check_set_ram216_bit0             ; 1066 0 208 180 CE12
                LB      A, r0                  ; 1068 0 208 180 78
                CMPB    A, 0f7h                ; 1069 0 208 180 C5F7C2
                JLT     warmcold_tm2_check_set_ram216_bit0             ; 106C 0 208 180 CA0C
                JNE     warmcold_tm2_check_goto_1116             ; 106E 0 208 180 CE07
                L       A, TIMER               ; 1070 1 208 180 E556
                CMP     A, (00138h-00180h)[USP] ; 1072 1 208 180 B3B8C2
                JGE     warmcold_tm2_check_set_ram216_bit0             ; 1075 1 208 180 CD03
warmcold_tm2_check_goto_1116:     J       warmcold_tm2_check_set_pswh_bit0             ; 1077 1 208 180 031611
warmcold_tm2_check_set_ram216_bit0:     SB      off(00216h).0          ; 107A 0 208 180 C41618
                CLRB    A                      ; 107D 0 208 180 FA
                MOVB    0bch, #000h            ; 107E 0 208 180 C5BC9800
                STB     A, 0bdh                ; 1082 0 208 180 D5BD
                MOVB    (0013ch-00180h)[USP], #003h ; 1084 0 208 180 C3BC9803
                STB     A, (0013dh-00180h)[USP] ; 1088 0 208 180 D3BD
                MOVB    (0019dh-00180h)[USP], #004h ; 108A 0 208 180 C31D9804
                MOV     USP, #00380h           ; 108E 0 208 380 A1988003
                L       A, #0ffffh             ; 1092 1 208 380 67FFFF
                ST      A, (0037ch-00380h)[USP] ; 1095 1 208 380 D3FC
                ST      A, (0037eh-00380h)[USP] ; 1097 1 208 380 D3FE
                ST      A, (00380h-00380h)[USP] ; 1099 1 208 380 D300
                ST      A, 0aeh                ; 109B 1 208 380 D5AE
                CLR     A                      ; 109D 1 208 380 F9
                ST      A, (00370h-00380h)[USP] ; 109E 1 208 380 D3F0
                ST      A, (00372h-00380h)[USP] ; 10A0 1 208 380 D3F2
                ST      A, (00374h-00380h)[USP] ; 10A2 1 208 380 D3F4
                ST      A, (00376h-00380h)[USP] ; 10A4 1 208 380 D3F6
                ST      A, (00378h-00380h)[USP] ; 10A6 1 208 380 D3F8
                ST      A, (0037ah-00380h)[USP] ; 10A8 1 208 380 D3FA
                MOV     USP, #00180h           ; 10AA 1 208 180 A1988001
                ST      A, (00174h-00180h)[USP] ; 10AE 1 208 180 D3F4
                ST      A, 0ceh                ; 10B0 1 208 180 D5CE
                ST      A, (00176h-00180h)[USP] ; 10B2 1 208 180 D3F6
                ST      A, 0d0h                ; 10B4 1 208 180 D5D0
                CLRB    A                      ; 10B6 0 208 180 FA
                STB     A, off(00289h)         ; 10B7 0 208 180 D489
                STB     A, (00179h-00180h)[USP] ; 10B9 0 208 180 D3F9
                STB     A, 0eah                ; 10BB 0 208 180 D5EA
                STB     A, 0ech                ; 10BD 0 208 180 D5EC
                STB     A, 0edh                ; 10BF 0 208 180 D5ED
                STB     A, 0eeh                ; 10C1 0 208 180 D5EE
                STB     A, 0efh                ; 10C3 0 208 180 D5EF
                RB      P3.3                   ; 10C5 0 208 180 C5240B
                CAL     crank_tooth_count_store_sub_clear_ram0a0_bit6             ; 10C8 0 208 180 325046
                MOVB    0c4h, #005h            ; 10CB 0 208 180 C5C49805
                CLRB    0c5h                   ; 10CF 0 208 180 C5C515
                SB      (00132h-00180h)[USP].1 ; 10D2 0 208 180 C3B219
                MOVB    0e2h, #0a0h            ; 10D5 0 208 180 C5E298A0
                CLRB    off(00298h)            ; 10D9 0 208 180 C49815
                RB      off(00232h).3          ; 10DC 0 208 180 C4320B
                RB      off(00230h).5          ; 10DF 0 208 180 C4300D
                MOVB    off(0029ch), #003h     ; 10E2 0 208 180 C49C9803
                CLRB    off(00238h)            ; 10E6 0 208 180 C43815
                CLR     A                      ; 10E9 1 208 180 F9
                ST      A, (0011ah-00180h)[USP] ; 10EA 1 208 180 D39A
                ST      A, off(0021ah)         ; 10EC 1 208 180 D41A
                CLRB    A                      ; 10EE 0 208 180 FA
                STB     A, (00127h-00180h)[USP] ; 10EF 0 208 180 D3A7
                STB     A, (00128h-00180h)[USP] ; 10F1 0 208 180 D3A8
                STB     A, (00129h-00180h)[USP] ; 10F3 0 208 180 D3A9
                SB      09fh.5                 ; 10F5 0 208 180 C59F1D
                SB      ADSCAN.5                ; 10F8 0 208 180 C5661D
                J       warmcold_tm2_check_set_ram09f_bit4             ; 10FB 0 208 180 032070
warmcold_tm2_check_store_ram294:     STB     A, off(00294h)         ; 10FE 0 208 180 D494
                RB      P4SF.4                 ; 1100 0 208 180 C51F0C
                MOV     off(0026eh), #00000h   ; 1103 0 208 180 B46E980000
                RB      0a0h.2                 ; 1108 0 208 180 C5A00A
                MOVB    P4, #011h              ; 110B 0 208 180 C5219811
                ANDB    off(00226h), #03fh     ; 110F 0 208 180 C426D03F
warmcold_tm2_check_nop_acc:     NOP                            ; 1113 0 208 180 00
                NOP                            ; 1114 0 208 180 00
                NOP                            ; 1115 0 208 180 00
warmcold_tm2_check_set_pswh_bit0:     SB      PSWH.0                 ; 1116 0 208 180 A218
                SC                             ; 1118 0 208 180 85
                JBS     off(00216h).0, warmcold_tm2_check_store_carry_ram216_bit1 ; 1119 0 208 180 E81612
                JBS     off(00214h).0, warmcold_tm2_check_load_imm ; 111C 0 208 180 E81403
                JBR     off(00216h).1, warmcold_tm2_check_load_ram2df ; 111F 0 208 180 D91635
warmcold_tm2_check_load_imm:     L       A, #0124fh             ; 1122 1 208 180 674F12
                JBS     off(00216h).1, warmcold_tm2_check_cmp_acc ; 1125 1 208 180 E91603
                L       A, #01d4ch             ; 1128 1 208 180 674C1D
warmcold_tm2_check_cmp_acc:     CMP     A, 0aeh                ; 112B 1 208 180 B5AEC2
warmcold_tm2_check_store_carry_ram216_bit1:     MB      off(00216h).1, C       ; 112E 1 208 180 C41639
                JGE     warmcold_tm2_check_load_ram2df             ; 1131 1 208 180 CD24
                JBR     off(00214h).0, warmcold_msec_reset ; 1133 1 208 180 D81403
                SB      off(00233h).4          ; 1136 1 208 180 C4331C
warmcold_msec_reset:     ANDB    098h, #062h            ; 1139 1 208 180 C598D062
                ANDB    099h, #085h            ; 113D 1 208 180 C599D085
                ANDB    09ah, #00bh            ; 1141 1 208 180 C59AD00B
                ANDB    09bh, #004h            ; 1145 1 208 180 C59BD004
                CLRB    A                      ; 1149 0 208 180 FA
                STB     A, 0ffh                ; 114A 0 208 180 D5FF
                STB     A, 0feh                ; 114C 0 208 180 D5FE
                NOP                            ; 114E 0 208 180 00
                NOP                            ; 114F 0 208 180 00
                NOP                            ; 1150 0 208 180 00
                NOP                            ; 1151 0 208 180 00
                NOP                            ; 1152 0 208 180 00
                NOP                            ; 1153 0 208 180 00
                JBR     off(00216h).0, warmcold_tm2_check_if_ram220_bit0_clr ; 1154 0 208 180 D81604
warmcold_tm2_check_load_ram2df:     MOVB    off(002dfh), #063h     ; 1157 0 208 180 C4DF9863
warmcold_tm2_check_if_ram220_bit0_clr:     JBR     off(00220h).0, warmcold_tm2_check_load_adcr5h ; 115B 0 208 180 D8200E
                RB      off(0022ah).7          ; 115E 0 208 180 C42A0F
                JEQ     warmcold_tm2_check_load_adcr5h             ; 1161 0 208 180 C909
                CLR     A                      ; 1163 1 208 180 F9
                LC      A, 05558h              ; 1164 1 208 180 909C5855
                MOV     DP, #0030eh            ; 1168 1 208 180 620E03
                ST      A, [DP]                ; 116B 1 208 180 D2
warmcold_tm2_check_load_adcr5h:     LB      A, ADCR5H              ; 116C 0 208 180 F573
                STB     A, r0                  ; 116E 0 208 180 88
                CMPB    A, #004h               ; 116F 0 208 180 C604
                JLT     warmcold_tm2_check_store_carry_ram22f_bit3             ; 1171 0 208 180 CA03
                LB      A, #0ffh               ; 1173 0 208 180 77FF
                CMPB    A, r0                  ; 1175 0 208 180 48
warmcold_tm2_check_store_carry_ram22f_bit3:     MB      off(0022fh).3, C       ; 1176 0 208 180 C42F3B
                CMPB    r0, #004h              ; 1179 0 208 180 20C004
                JLT     warmcold_tm2_check_store_carry_ram22f_bit4             ; 117C 0 208 180 CA03
                LB      A, #0f6h               ; 117E 0 208 180 77F6
                CMPB    A, r0                  ; 1180 0 208 180 48
warmcold_tm2_check_store_carry_ram22f_bit4:     MB      off(0022fh).4, C       ; 1181 0 208 180 C42F3C
                JBS     off(00215h).0, warmcold_tm2_check_if_ram221_bit0_clr ; 1184 0 208 180 E8151C
                L       A, 0aeh                ; 1187 1 208 180 E5AE
                CMPC    A, 01123h              ; 1189 1 208 180 909E2311
                NOP                            ; 118D 1 208 180 00
                JGE     warmcold_tm2_check_load_imm_2             ; 118E 1 208 180 CD06
                JBS     off(0022fh).3, warmcold_tm2_check_load_imm_2 ; 1190 1 208 180 EB2F03
                JBR     off(00224h).3, warmcold_tm2_check_load_ram2fe ; 1193 1 208 180 DB2406
warmcold_tm2_check_load_imm_2:     LB      A, #0ffh               ; 1196 0 208 180 77FF
                STB     A, off(002feh)         ; 1198 0 208 180 D4FE
                SJ      warmcold_tm2_check_if_ram221_bit0_clr             ; 119A 0 208 180 CB07
warmcold_tm2_check_load_ram2fe:     LB      A, off(002feh)         ; 119C 0 208 180 F4FE
                JNE     warmcold_tm2_check_if_ram221_bit0_clr             ; 119E 0 208 180 CE03
                SB      off(00215h).0          ; 11A0 0 208 180 C41518
warmcold_tm2_check_if_ram221_bit0_clr:     JBR     off(00221h).0, warmcold_tm2_check_clear_carry ; 11A3 0 208 180 D8210E
                MB      C, off(00227h).5       ; 11A6 0 208 180 C4272D
                JBS     off(0021ah).1, warmcold_tm2_check_load_ram2dd ; 11A9 0 208 180 E91A0B
                MOVB    off(002dch), #014h     ; 11AC 0 208 180 C4DC9814
                LB      A, off(002ddh)         ; 11B0 0 208 180 F4DD
                JLT     warmcold_tm2_check_if_ram212_bit4_set             ; 11B2 0 208 180 CA0B
warmcold_tm2_check_clear_carry:     RC                             ; 11B4 0 208 180 95
                SJ      dtc21_vtec_solenoid_latch             ; 11B5 0 208 180 CB0C
warmcold_tm2_check_load_ram2dd:     MOVB    off(002ddh), #014h     ; 11B7 0 208 180 C4DD9814
                LB      A, off(002dch)         ; 11BB 0 208 180 F4DC
                JLT     warmcold_tm2_check_clear_carry             ; 11BD 0 208 180 CAF5
warmcold_tm2_check_if_ram212_bit4_set:     JBS     off(00212h).4, warmcold_tm2_check_clear_carry ; 11BF 0 208 180 EC12F2
                SC                             ; 11C2 0 208 180 85
dtc21_vtec_solenoid_latch:     MB      09ah.0, C              ; 11C3 0 208 180 C59A38
                JBR     off(00221h).0, altvtec_vtps_result ; 11C6 0 208 180 D82115
                JNE     altvtec_vtps_result             ; 11C9 0 208 180 CE13
                JBS     off(00212h).4, altvtec_vtps_result ; 11CB 0 208 180 EC1210
                JLT     altvtec_vtps_result             ; 11CE 0 208 180 CA0E
                JBS     off(00212h).5, altvtec_vtps_result ; 11D0 0 208 180 ED120B
                MB      C, off(00227h).4       ; 11D3 0 208 180 C4272C
                JBR     off(0021ah).1, dtc22_vtec_pressure_latch ; 11D6 0 208 180 D91A06
                JLT     altvtec_vtps_result             ; 11D9 0 208 180 CA03
                SC                             ; 11DB 0 208 180 85
                SJ      dtc22_vtec_pressure_latch             ; 11DC 0 208 180 CB01
altvtec_vtps_result:     RC                             ; 11DE 0 208 180 95
dtc22_vtec_pressure_latch:     MB      09ah.1, C              ; 11DF 0 208 180 C59A39
                CMPB    off(00289h), #0c8h     ; 11E2 0 208 180 C489C0C8
                JGE     autotrans_gate_start_load_ram2eb             ; 11E6 0 208 180 CD04
                LB      A, off(00294h)         ; 11E8 0 208 180 F494
                JEQ     autotrans_gate_start_load_ram2eb_2             ; 11EA 0 208 180 C904
autotrans_gate_start_load_ram2eb:     MOVB    off(002ebh), #01eh     ; 11EC 0 208 180 C4EB981E
autotrans_gate_start_load_ram2eb_2:     LB      A, off(002ebh)         ; 11F0 0 208 180 F4EB
                JNE     ect_step_store_if_ram210_bit2_set             ; 11F2 0 208 180 CE0F
                LB      A, off(00292h)         ; 11F4 0 208 180 F492
                MOVB    r0, #05ch              ; 11F6 0 208 180 985C
                CMPB    A, r0                  ; 11F8 0 208 180 48
                JGE     dwell_scale_default             ; 11F9 0 208 180 CD05
                MOVB    r0, #031h              ; 11FB 0 208 180 9831
                CMPB    A, r0                  ; 11FD 0 208 180 48
                JGE     ect_step_store             ; 11FE 0 208 180 CD01
dwell_scale_default:     LB      A, r0                  ; 1200 0 208 180 78
ect_step_store:     STB     A, off(00293h)         ; 1201 0 208 180 D493
ect_step_store_if_ram210_bit2_set:     JBS     off(00210h).2, sensor_check_clear ; 1203 0 208 180 EA1027
                JBS     off(00210h).4, sensor_check_clear ; 1206 0 208 180 EC1024
                MB      C, 09eh.5              ; 1209 0 208 180 C59E2D
                JLT     sensor_check_clear             ; 120C 0 208 180 CA1F
                CMPB    off(00289h), #002h     ; 120E 0 208 180 C489C002
                JGE     ect_step_store_if_ram233_bit4_clr             ; 1212 0 208 180 CD04
                MOVB    off(002dbh), #032h     ; 1214 0 208 180 C4DB9832
ect_step_store_if_ram233_bit4_clr:     JBR     off(00233h).4, sensor_check_clear ; 1218 0 208 180 DC3312
                MOV     DP, #003a3h            ; 121B 0 208 180 62A303
                LB      A, [DP]                ; 121E 0 208 180 F2
                SUBB    A, ADCR6H              ; 121F 0 208 180 C575A2
                JGE     sensor_check_result             ; 1222 0 208 180 CD01
                VCAL    7                      ; 1224 0 208 180 17
sensor_check_result:     CMPB    A, #002h               ; 1225 0 208 180 C602
                JGE     sensor_check_result_set_ram09e_bit5             ; 1227 0 208 180 CD07
                LB      A, off(002dbh)         ; 1229 0 208 180 F4DB
                JEQ     dtc05_map_range_latch             ; 122B 0 208 180 C906
sensor_check_clear:     RC                             ; 122D 0 208 180 95
                SJ      dtc05_map_range_latch             ; 122E 0 208 180 CB03
sensor_check_result_set_ram09e_bit5:     SB      09eh.5                 ; 1230 0 208 180 C59E1D
dtc05_map_range_latch:     MB      098h.3, C              ; 1233 0 208 180 C5983B
                RC                             ; 1236 0 208 180 95
                JBS     off(00210h).7, dtc08_tdc_latch ; 1237 0 208 180 EF100E
                JBR     off(00216h).0, dtc08_tdc_latch ; 123A 0 208 180 D8160B
                MB      C, off(00214h).0       ; 123D 0 208 180 C41428
                JBR     off(00220h).0, dtc08_tdc_latch ; 1240 0 208 180 D82005
                JGE     dtc08_tdc_latch             ; 1243 0 208 180 CD03
                MB      C, off(00224h).5       ; 1245 0 208 180 C4242D
dtc08_tdc_latch:     MB      098h.5, C              ; 1248 0 208 180 C5983D
                VCAL    4                      ; 124B 0 208 180 14
                MOV     DP, #003dah            ; 124C 0 208 180 62DA03
                LB      A, [DP]                ; 124F 0 208 180 F2
                STB     A, r1                  ; 1250 0 208 180 89
                RC                             ; 1251 0 208 180 95
                JBS     off(00210h).5, dtc06_ect_latch ; 1252 0 208 180 ED1008
                LB      A, #0fch               ; 1255 0 208 180 77FC
                CMPB    A, r1                  ; 1257 0 208 180 49
                JLT     dtc06_ect_latch             ; 1258 0 208 180 CA03
                LB      A, r1                  ; 125A 0 208 180 79
                CMPB    A, #004h               ; 125B 0 208 180 C604
dtc06_ect_latch:     MB      098h.1, C              ; 125D 0 208 180 C59839
                JBS     off(00210h).5, ect_simulate_ramp ; 1260 0 208 180 ED1022
                JLT     ect_simulate_ramp_load_ram0d9             ; 1263 0 208 180 CA35
                JBS     off(00224h).2, ect_fault_range_check_load_dp ; 1265 0 208 180 EA2438
                MOV     DP, #003a4h            ; 1268 0 208 180 62A403
                SUBB    A, [DP]                ; 126B 0 208 180 C2A2
                JGE     ect_fault_delta_check             ; 126D 0 208 180 CD01
                VCAL    7                      ; 126F 0 208 180 17
ect_fault_delta_check:     CMPB    A, #002h               ; 1270 0 208 180 C602
                JGT     ect_fault_delta_check_load_r1             ; 1272 0 208 180 C838
                LB      A, off(002deh)         ; 1274 0 208 180 F4DE
                JNE     ect_simulate_ramp_load_ram0d9_2             ; 1276 0 208 180 CE3A
                LB      A, r1                  ; 1278 0 208 180 79
                JBS     off(00216h).0, ect_fault_range_check_load_dp ; 1279 0 208 180 E81624
                MOV     DP, #003a5h            ; 127C 0 208 180 62A503
                CMPB    A, [DP]                ; 127F 0 208 180 C2C2
                JGT     ect_simulate_ramp_load_ram2de             ; 1281 0 208 180 C82B
                SJ      ect_fault_range_check_load_dp             ; 1283 0 208 180 CB1B
ect_simulate_ramp:     JBR     off(00216h).1, ect_simulate_ramp_load_ram0d9 ; 1285 0 208 180 D91612
                CLR     A                      ; 1288 1 208 180 F9
                LB      A, off(002dfh)         ; 1289 0 208 180 F4DF
                MOVB    r0, #014h              ; 128B 0 208 180 9814
                DIVB                           ; 128D 0 208 180 A236
                MOV     DP, #tbl_ect_simulate_ramp          ; 128F 0 208 180 623A57
                ADD     DP, A                  ; 1292 0 208 180 9281
                LCB     A, [DP]                ; 1294 0 208 180 92AA
                STB     A, 0d9h                ; 1296 0 208 180 D5D9
                SJ      ect_simulate_ramp_load_ram2de             ; 1298 0 208 180 CB14
ect_simulate_ramp_load_ram0d9:     MOVB    0d9h, #062h            ; 129A 0 208 180 C5D99862
                SJ      ect_simulate_ramp_load_ram2de             ; 129E 0 208 180 CB0E
ect_fault_range_check_load_dp:     MOV     DP, #000d9h            ; 12A0 0 208 180 62D900
                CAL     ect_smooth_helper             ; 12A3 0 208 180 32E944
                CAL     ect_fault_range_check_sub_load_dp             ; 12A6 0 208 180 32464A
                MOV     DP, #003a4h            ; 12A9 0 208 180 62A403
ect_fault_delta_check_load_r1:     LB      A, r1                  ; 12AC 0 208 180 79
                STB     A, [DP]                ; 12AD 0 208 180 D2
ect_simulate_ramp_load_ram2de:     MOVB    off(002deh), #005h     ; 12AE 0 208 180 C4DE9805
ect_simulate_ramp_load_ram0d9_2:     LB      A, 0d9h                ; 12B2 0 208 180 F5D9
                MOV     X1, #05086h            ; 12B4 0 208 180 608650
                MOV     X2, #05094h            ; 12B7 0 208 180 619450
                CMPB    A, #028h               ; 12BA 0 208 180 C628
                JLT     ect_simulate_ramp_store_carry_ram230_bit6             ; 12BC 0 208 180 CA06
                MOV     X1, #050a2h            ; 12BE 0 208 180 60A250
                MOV     X2, #050b0h            ; 12C1 0 208 180 61B050
ect_simulate_ramp_store_carry_ram230_bit6:     MB      off(00230h).6, C       ; 12C4 0 208 180 C4303E
                VCAL    0                      ; 12C7 0 208 180 10
                STB     A, r3                  ; 12C8 0 208 180 8B
                MOV     X1, X2                 ; 12C9 0 208 180 9178
                LB      A, 0d9h                ; 12CB 0 208 180 F5D9
                VCAL    0                      ; 12CD 0 208 180 10
                STB     A, r2                  ; 12CE 0 208 180 8A
                MOV     off(00278h), er1       ; 12CF 0 208 180 457C78
                LB      A, 0d9h                ; 12D2 0 208 180 F5D9
                MOV     X1, #05072h            ; 12D4 0 208 180 607250
                VCAL    0                      ; 12D7 0 208 180 10
                STB     A, off(002b1h)         ; 12D8 0 208 180 D4B1
                JBR     off(0021fh).0, overrev_hardcap_compare_load_ram2ce ; 12DA 0 208 180 D81F37
                LB      A, #07dh               ; 12DD 0 208 180 777D
                JBS     off(00220h).0, overrev_hardcap_compare ; 12DF 0 208 180 E82002
                LB      A, #073h               ; 12E2 0 208 180 7773
overrev_hardcap_compare:     CMPB    A, off(00289h)         ; 12E4 0 208 180 C789
                JLT     overrev_hardcap_compare_load_ram2ce             ; 12E6 0 208 180 CA2C
                LB      A, 0dfh                ; 12E8 0 208 180 F5DF
                CMPB    A, #032h               ; 12EA 0 208 180 C632
                JGE     overrev_hardcap_compare_load_ram2ce             ; 12EC 0 208 180 CD26
                CMPB    A, #01eh               ; 12EE 0 208 180 C61E
                JLT     overrev_hardcap_compare_load_ram2ce             ; 12F0 0 208 180 CA22
                CMPB    0d9h, #000h            ; 12F2 0 208 180 C5D9C000
                JGE     overrev_hardcap_compare_load_ram2ce             ; 12F6 0 208 180 CD1C
                CMPB    off(00288h), #064h     ; 12F8 0 208 180 C488C064
                JGE     overrev_hardcap_compare_load_ram2ce             ; 12FC 0 208 180 CD16
                J       overrev_hardcap_compare_if_ram216_bit6_set             ; 12FE 0 208 180 03306E
overrev_hardcap_compare_cmp_ram2ce:     CMPB    off(002ceh), #0b4h     ; 1301 0 208 180 C4CEC0B4
                JGE     overrev_hardcap_compare_vcal_4             ; 1305 0 208 180 CD21
                MOVB    r0, #000h              ; 1307 0 208 180 9800
                LB      A, off(002ceh)         ; 1309 0 208 180 F4CE
                JEQ     overrev_hardcap_compare_load_ram29a             ; 130B 0 208 180 C90F
                MOV     off(0029ah), #00100h   ; 130D 0 208 180 B49A980001
                SJ      overrev_hardcap_compare_load_r0             ; 1312 0 208 180 CB10
overrev_hardcap_compare_load_ram2ce:     MOVB    off(002ceh), #0f0h     ; 1314 0 208 180 C4CE98F0
                CLRB    r0                     ; 1318 0 208 180 2015
                SJ      overrev_hardcap_compare_clear_carry             ; 131A 0 208 180 CB04
overrev_hardcap_compare_load_ram29a:     L       A, off(0029ah)         ; 131C 1 208 180 E49A
                JNE     overrev_hardcap_compare_store_carry_ram230_bit3             ; 131E 1 208 180 CE01
overrev_hardcap_compare_clear_carry:     RC                             ; 1320 0 208 180 95
overrev_hardcap_compare_store_carry_ram230_bit3:     MB      off(00230h).3, C       ; 1321 0 208 180 C4303B
overrev_hardcap_compare_load_r0:     LB      A, r0                  ; 1324 0 208 180 78
                VCAL    7                      ; 1325 0 208 180 17
                STB     A, off(002afh)         ; 1326 0 208 180 D4AF
overrev_hardcap_compare_vcal_4:     VCAL    4                      ; 1328 0 208 180 14
                LB      A, 0d9h                ; 1329 0 208 180 F5D9
                STB     A, r2                  ; 132B 0 208 180 8A
                MOV     X1, #051c1h            ; 132C 0 208 180 60C151
                VCAL    0                      ; 132F 0 208 180 10
                STB     A, (0017ah-00180h)[USP] ; 1330 0 208 180 D3FA
                LB      A, r2                  ; 1332 0 208 180 7A
                MOV     X1, #051cfh            ; 1333 0 208 180 60CF51
                VCAL    0                      ; 1336 0 208 180 10
                STB     A, (0017bh-00180h)[USP] ; 1337 0 208 180 D3FB
                LB      A, r2                  ; 1339 0 208 180 7A
                MOV     X1, #051ddh            ; 133A 0 208 180 60DD51
                VCAL    0                      ; 133D 0 208 180 10
                STB     A, (0017ch-00180h)[USP] ; 133E 0 208 180 D3FC
                LB      A, r2                  ; 1340 0 208 180 7A
                MOV     X1, #051ebh            ; 1341 0 208 180 60EB51
                VCAL    0                      ; 1344 0 208 180 10
                STB     A, (0017dh-00180h)[USP] ; 1345 0 208 180 D3FD
                LB      A, r2                  ; 1347 0 208 180 7A
                MOV     X1, #051f9h            ; 1348 0 208 180 60F951
                VCAL    0                      ; 134B 0 208 180 10
                STB     A, (0017eh-00180h)[USP] ; 134C 0 208 180 D3FE
                VCAL    4                      ; 134E 0 208 180 14
                LB      A, 0d9h                ; 134F 0 208 180 F5D9
                STB     A, r2                  ; 1351 0 208 180 8A
                MOV     X1, #05207h            ; 1352 0 208 180 600752
                VCAL    0                      ; 1355 0 208 180 10
                STB     A, (0017fh-00180h)[USP] ; 1356 0 208 180 D3FF
                LB      A, r2                  ; 1358 0 208 180 7A
                MOV     X1, #0534ah            ; 1359 0 208 180 604A53
                VCAL    0                      ; 135C 0 208 180 10
                STB     A, (00185h-00180h)[USP] ; 135D 0 208 180 D305
                LB      A, r2                  ; 135F 0 208 180 7A
                MOV     X1, #05356h            ; 1360 0 208 180 605653
                VCAL    0                      ; 1363 0 208 180 10
                STB     A, (00187h-00180h)[USP] ; 1364 0 208 180 D307
                LB      A, r2                  ; 1366 0 208 180 7A
                MOV     X1, #05364h            ; 1367 0 208 180 606453
                VCAL    0                      ; 136A 0 208 180 10
                STB     A, (00188h-00180h)[USP] ; 136B 0 208 180 D308
                LB      A, r2                  ; 136D 0 208 180 7A
                MOV     X1, #overrev_hardcap_compare_tbl_4          ; 136E 0 208 180 60E669
                VCAL    0                      ; 1371 0 208 180 10
                STB     A, (00194h-00180h)[USP] ; 1372 0 208 180 D314
                VCAL    4                      ; 1374 0 208 180 14
                L       A, off(00210h)         ; 1375 1 208 180 E410
                AND     A, #0c3bch             ; 1377 1 208 180 D6BCC3
                SC                             ; 137A 1 208 180 85
                JNE     overrev_hardcap_compare_store_carry_ram232_bit4             ; 137B 1 208 180 CE03
                MB      C, off(00212h).5       ; 137D 1 208 180 C4122D
overrev_hardcap_compare_store_carry_ram232_bit4:     MB      off(00232h).4, C       ; 1380 1 208 180 C4323C
                MOVB    r0, #004h              ; 1383 1 208 180 9804
                MOV     DP, #tbl_map_sign          ; 1385 1 208 180 62B357
                LB      A, 0d9h                ; 1388 0 208 180 F5D9
overrev_hardcap_compare_dec_dp:     DEC     DP                     ; 138A 0 208 180 82
                DECB    r0                     ; 138B 0 208 180 B8
                JEQ     overrev_hardcap_compare_clear_pswh_bit0             ; 138C 0 208 180 C904
                CMPCB   A, [DP]                ; 138E 0 208 180 92AE
                JGE     overrev_hardcap_compare_dec_dp             ; 1390 0 208 180 CDF8
overrev_hardcap_compare_clear_pswh_bit0:     RB      PSWH.0                 ; 1392 0 208 180 A208
                LB      A, off(00223h)         ; 1394 0 208 180 F423
                ANDB    A, #0fch               ; 1396 0 208 180 D6FC
                ORB     A, r0                  ; 1398 0 208 180 68
                STB     A, off(00223h)         ; 1399 0 208 180 D423
                SB      PSWH.0                 ; 139B 0 208 180 A218
                RC                             ; 139D 0 208 180 95
                JBS     off(00212h).6, dtc23_knock_latch ; 139E 0 208 180 EE1217
                JBS     off(00238h).0, dtc23_knock_latch ; 13A1 0 208 180 E83814
                L       A, off(00210h)         ; 13A4 1 208 180 E410
                AND     A, #0c3bch             ; 13A6 1 208 180 D6BCC3
                JNE     dtc23_knock_latch             ; 13A9 1 208 180 CE0D
                JBS     off(00212h).5, dtc23_knock_latch ; 13AB 1 208 180 ED120A
                LB      A, off(002fdh)         ; 13AE 0 208 180 F4FD
                JEQ     dtc23_knock_latch             ; 13B0 0 208 180 C906
                JBS     off(00238h).1, dtc23_knock_latch ; 13B2 0 208 180 E93803
                MB      C, off(00238h).2       ; 13B5 0 208 180 C4382A
dtc23_knock_latch:     MB      09ah.2, C              ; 13B8 0 208 180 C59A3A
                LB      A, 0d9h                ; 13BB 0 208 180 F5D9
                MOV     X1, #0528bh            ; 13BD 0 208 180 608B52
                CMPCB   A, 00002h[X1]          ; 13C0 0 208 180 90AF0200
                MB      off(00218h).7, C       ; 13C4 0 208 180 C4183F
                VCAL    0                      ; 13C7 0 208 180 10
                STB     A, (00199h-00180h)[USP] ; 13C8 0 208 180 D319
                CMPB    off(00289h), #0ech     ; 13CA 0 208 180 C489C0EC
                JGE     overrev_hardcap_compare_load_x1             ; 13CE 0 208 180 CD04
                MOVB    (001dch-00180h)[USP], #096h ; 13D0 0 208 180 C35C9896
overrev_hardcap_compare_load_x1:     MOV     X1, #overrev_hardcap_compare_tbl_3          ; 13D4 0 208 180 60E456
                LB      A, 0d9h                ; 13D7 0 208 180 F5D9
                VCAL    1                      ; 13D9 0 208 180 11
                STB     A, (001b0h-00180h)[USP] ; 13DA 0 208 180 D330
                MOV     X1, #0545fh            ; 13DC 0 208 180 605F54
                JBR     off(00220h).0, overrev_hardcap_compare_load_ram0d9 ; 13DF 0 208 180 D82003
                MOV     X1, #0547ah            ; 13E2 0 208 180 607A54
overrev_hardcap_compare_load_ram0d9:     LB      A, 0d9h                ; 13E5 0 208 180 F5D9
                VCAL    1                      ; 13E7 0 208 180 11
                STB     A, off(00260h)         ; 13E8 0 208 180 D460
                VCAL    4                      ; 13EA 0 208 180 14
                MOV     X1, #054cbh            ; 13EB 0 208 180 60CB54
                JBR     off(00220h).0, overrev_hardcap_compare_load_ram0d9_2 ; 13EE 0 208 180 D82003
                MOV     X1, #054e6h            ; 13F1 0 208 180 60E654
overrev_hardcap_compare_load_ram0d9_2:     LB      A, 0d9h                ; 13F4 0 208 180 F5D9
                VCAL    1                      ; 13F6 0 208 180 11
                STB     A, off(00262h)         ; 13F7 0 208 180 D462
                MOV     X1, #overrev_hardcap_compare_tbl          ; 13F9 0 208 180 605856
                JBR     off(00220h).0, overrev_hardcap_compare_load_ram0d9_3 ; 13FC 0 208 180 D82003
                MOV     X1, #overrev_hardcap_compare_tbl_2          ; 13FF 0 208 180 607356
overrev_hardcap_compare_load_ram0d9_3:     LB      A, 0d9h                ; 1402 0 208 180 F5D9
                VCAL    1                      ; 1404 0 208 180 11
                STB     A, off(00264h)         ; 1405 0 208 180 D464
                MOV     X1, #055dah            ; 1407 0 208 180 60DA55
                LB      A, 0d9h                ; 140A 0 208 180 F5D9
                VCAL    1                      ; 140C 0 208 180 11
                STB     A, off(0023eh)         ; 140D 0 208 180 D43E
                VCAL    4                      ; 140F 0 208 180 14
                L       A, off(00210h)         ; 1410 1 208 180 E410
                AND     A, #02074h             ; 1412 1 208 180 D67420
                JNE     overrev_hardcap_compare_set_ram216_bit2             ; 1415 1 208 180 CE35
                J       overrev_hardcap_compare_if_ram212_bit0_set             ; 1417 1 208 180 037070
overrev_hardcap_compare_if_ram216_bit1_set:     JBS     off(00216h).1, overrev_hardcap_compare_cmp_ram0d8 ; 141A 1 208 180 E91623
                JBR     off(00220h).0, overrev_hardcap_compare_if_ram216_bit5_set ; 141D 1 208 180 D82003
                JBR     off(00224h).5, overrev_hardcap_compare_set_ram216_bit2 ; 1420 1 208 180 DD2429
overrev_hardcap_compare_if_ram216_bit5_set:     JBS     off(00216h).5, overrev_hardcap_compare_set_ram216_bit2 ; 1423 1 208 180 ED1626
                CMPB    off(00289h), #090h     ; 1426 1 208 180 C489C090
                JGE     overrev_hardcap_compare_set_ram216_bit2             ; 142A 1 208 180 CD20
                LB      A, #032h               ; 142C 0 208 180 7732
                JBR     off(00239h).6, overrev_hardcap_compare_cmp_acc ; 142E 0 208 180 DE3902
                LB      A, #064h               ; 1431 0 208 180 7764
overrev_hardcap_compare_cmp_acc:     CMPB    A, 0ffh                ; 1433 0 208 180 C5FFC2
                JGE     overrev_hardcap_compare_load_x1_2             ; 1436 0 208 180 CD17
                CMPB    0d9h, #03ch            ; 1438 0 208 180 C5D9C03C
                JLT     overrev_hardcap_compare_set_ram216_bit2             ; 143C 0 208 180 CA0E
                SJ      overrev_hardcap_compare_load_x1_2             ; 143E 0 208 180 CB0F
overrev_hardcap_compare_cmp_ram0d8:     CMPB    0d8h, #030h            ; 1440 1 208 180 C5D8C030
                MB      off(00239h).6, C       ; 1444 1 208 180 C4393E
                RB      off(00216h).2          ; 1447 1 208 180 C4160A
                SJ      overrev_hardcap_compare_load_x1_2             ; 144A 1 208 180 CB03
overrev_hardcap_compare_set_ram216_bit2:     SB      off(00216h).2          ; 144C 1 208 180 C4161A
overrev_hardcap_compare_load_x1_2:     MOV     X1, #05532h            ; 144F 1 208 180 603255
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram0d9_4 ; 1452 1 208 180 DA162A
                JBR     off(00220h).2, overrev_hardcap_compare_cmp_ram0d9 ; 1455 1 208 180 DA2015
                CMPB    0d9h, #036h            ; 1458 1 208 180 C5D9C036
                JGE     overrev_hardcap_compare_cmp_ram0d9             ; 145C 1 208 180 CD0F
                LB      A, #070h               ; 145E 0 208 180 7770
                JBS     off(00239h).4, overrev_hardcap_compare_cmp_ram0dd ; 1460 0 208 180 EC3902
                LB      A, #030h               ; 1463 0 208 180 7730
overrev_hardcap_compare_cmp_ram0dd:     CMPB    0ddh, A                ; 1465 0 208 180 C5DDC1
                MB      off(00239h).4, C       ; 1468 0 208 180 C4393C
                JLT     overrev_hardcap_compare_load_imm             ; 146B 0 208 180 CA19
overrev_hardcap_compare_cmp_ram0d9:     CMPB    0d9h, #02eh            ; 146D 0 208 180 C5D9C02E
                JGE     overrev_hardcap_compare_load_x1_3             ; 1471 0 208 180 CD09
                L       A, #00a77h             ; 1473 1 208 180 67770A
                JBR     off(00220h).0, overrev_hardcap_compare_clear_er3 ; 1476 1 208 180 D82009
                JBS     off(00224h).5, overrev_hardcap_compare_clear_er3 ; 1479 1 208 180 ED2406
overrev_hardcap_compare_load_x1_3:     MOV     X1, #0551dh            ; 147C 1 208 180 601D55
overrev_hardcap_compare_load_ram0d9_4:     LB      A, 0d9h                ; 147F 0 208 180 F5D9
                VCAL    1                      ; 1481 0 208 180 11
overrev_hardcap_compare_clear_er3:     CLR     er3                    ; 1482 0 208 180 4715
                SJ      overrev_hardcap_compare_store_ram286             ; 1484 0 208 180 CB07
overrev_hardcap_compare_load_imm:     L       A, #00945h             ; 1486 1 208 180 674509
                MOV     er3, #00200h           ; 1489 1 208 180 47980002
overrev_hardcap_compare_store_ram286:     ST      A, off(00286h)         ; 148D 1 208 180 D486
                MOV     off(0026ah), er3       ; 148F 1 208 180 477C6A
                MOV     X1, #0550fh            ; 1492 1 208 180 600F55
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram0d9_5 ; 1495 1 208 180 DA1603
                MOV     X1, #05501h            ; 1498 1 208 180 600155
overrev_hardcap_compare_load_ram0d9_5:     LB      A, 0d9h                ; 149B 0 208 180 F5D9
                VCAL    0                      ; 149D 0 208 180 10
                STB     A, off(00295h)         ; 149E 0 208 180 D495
                L       A, off(00264h)         ; 14A0 1 208 180 E464
                MOV     DP, #0030eh            ; 14A2 1 208 180 620E03
                SUB     A, [DP]                ; 14A5 1 208 180 B2A2
                JLT     overrev_hardcap_compare_clear_acc             ; 14A7 1 208 180 CA11
                MOVB    r1, off(00299h)        ; 14A9 1 208 180 C49949
                SUBB    r1, #080h              ; 14AC 1 208 180 21A080
                JLT     overrev_hardcap_compare_clear_acc             ; 14AF 1 208 180 CA09
                CLRB    r0                     ; 14B1 1 208 180 2015
                MUL                            ; 14B3 1 208 180 9035
                SLL     A                      ; 14B5 1 208 180 53
                L       A, er1                 ; 14B6 1 208 180 35
                ROL     A                      ; 14B7 1 208 180 33
                SJ      overrev_hardcap_compare_store_ram266             ; 14B8 1 208 180 CB01
overrev_hardcap_compare_clear_acc:     CLR     A                      ; 14BA 1 208 180 F9
overrev_hardcap_compare_store_ram266:     ST      A, off(00266h)         ; 14BB 1 208 180 D466
                MOV     X1, #05495h            ; 14BD 1 208 180 609554
                JBR     off(00220h).0, vemapscalar_gate ; 14C0 1 208 180 D82003
                MOV     X1, #054b0h            ; 14C3 1 208 180 60B054
vemapscalar_gate:     LB      A, 0d9h                ; 14C6 0 208 180 F5D9
                VCAL    1                      ; 14C8 0 208 180 11
                STB     A, off(00268h)         ; 14C9 0 208 180 D468
                VCAL    4                      ; 14CB 0 208 180 14
                MOV     DP, #0030eh            ; 14CC 0 208 180 620E03
                L       A, [DP]                ; 14CF 1 208 180 E2
                CMPC    A, 05554h              ; 14D0 1 208 180 909E5455
                JLT     vemapscalar_gate_rom_load_ram555a             ; 14D4 1 208 180 CA06
                CMPC    A, 05556h              ; 14D6 1 208 180 909E5655
                JLE     vemapscalar_gate_store_dp_ind             ; 14DA 1 208 180 CF0B
vemapscalar_gate_rom_load_ram555a:     LC      A, 0555ah              ; 14DC 1 208 180 909C5A55
                JBR     off(00220h).0, vemapscalar_gate_store_dp_ind ; 14E0 1 208 180 D82004
                LC      A, 05558h              ; 14E3 1 208 180 909C5855
vemapscalar_gate_store_dp_ind:     ST      A, [DP]                ; 14E7 1 208 180 D2
                MOV     X1, #05397h            ; 14E8 1 208 180 609753
                JBR     off(00220h).0, vemapscalar_gate_load_ram0d9 ; 14EB 1 208 180 D82003
                MOV     X1, #053a5h            ; 14EE 1 208 180 60A553
vemapscalar_gate_load_ram0d9:     LB      A, 0d9h                ; 14F1 0 208 180 F5D9
                VCAL    0                      ; 14F3 0 208 180 10
                STB     A, r2                  ; 14F4 0 208 180 8A
                MOV     X1, #053b3h            ; 14F5 0 208 180 60B353
                JBR     off(00220h).0, vemapscalar_gate_load_ram0d9_2 ; 14F8 0 208 180 D82003
                MOV     X1, #053c1h            ; 14FB 0 208 180 60C153
vemapscalar_gate_load_ram0d9_2:     LB      A, 0d9h                ; 14FE 0 208 180 F5D9
                VCAL    0                      ; 1500 0 208 180 10
                STB     A, ACCH                ; 1501 0 208 180 D507
                LB      A, r2                  ; 1503 0 208 180 7A
                MOV     (0016eh-00180h)[USP], A ; 1504 0 208 180 B3EE8A
                JBS     off(00212h).0, vemapscalar_gate_clear_acc ; 1507 0 208 180 E81247
                LB      A, (001f4h-00180h)[USP] ; 150A 0 208 180 F374
                JNE     vemapscalar_gate_vcal_4             ; 150C 0 208 180 CE78
                MOVB    (001f4h-00180h)[USP], #00ah ; 150E 0 208 180 C374980A
                LB      A, #0a3h               ; 1512 0 208 180 77A3
                JBS     off(0022ah).1, vemapscalar_gate_cmp_acc ; 1514 0 208 180 E92A02
                LB      A, #0e0h               ; 1517 0 208 180 77E0
vemapscalar_gate_cmp_acc:     CMPB    A, off(00289h)         ; 1519 0 208 180 C789
                MB      off(0022ah).1, C       ; 151B 0 208 180 C42A39
                JGE     vemapscalar_gate_load_ram2d0             ; 151E 0 208 180 CD3D
                LB      A, #065h               ; 1520 0 208 180 7765
                JBS     off(00218h).5, vemapscalar_gate_cmp_ram0d9 ; 1522 0 208 180 ED1802
                LB      A, #061h               ; 1525 0 208 180 7761
vemapscalar_gate_cmp_ram0d9:     CMPB    0d9h, A                ; 1527 0 208 180 C5D9C1
                MB      off(00218h).5, C       ; 152A 0 208 180 C4183D
                JGE     vemapscalar_gate_load_ram2d0             ; 152D 0 208 180 CD2E
                LB      A, off(002d0h)         ; 152F 0 208 180 F4D0
                JNE     vemapscalar_gate_load_stk             ; 1531 0 208 180 CE2E
                L       A, (0016ch-00180h)[USP] ; 1533 1 208 180 E3EC
                MOV     X1, #0540bh            ; 1535 1 208 180 600B54
                MOV     X2, #0540fh            ; 1538 1 208 180 610F54
                J       vemapscalar_gate_if_ram212_bit5_set             ; 153B 1 208 180 03A06F
vemapscalar_gate_load_x1:     MOV     X1, #05403h            ; 153E 1 208 180 600354
                MOV     X2, #05407h            ; 1541 1 208 180 610754
vemapscalar_gate_call_add24_clamp_neg1:     CAL     add24_clamp_neg1             ; 1544 1 208 180 328349
                MOV     DP, A                  ; 1547 1 208 180 52
                L       A, (0016ah-00180h)[USP] ; 1548 1 208 180 E3EA
                MOV     X1, X2                 ; 154A 1 208 180 9178
                CAL     add24_clamp_neg1             ; 154C 1 208 180 328349
                SJ      vemapscalar_gate_clear_pswh_bit0             ; 154F 1 208 180 CB2C
vemapscalar_gate_clear_acc:     CLR     A                      ; 1551 1 208 180 F9
                LC      A, 05403h              ; 1552 1 208 180 909C0354
                MOV     DP, A                  ; 1556 1 208 180 52
                LC      A, 05407h              ; 1557 1 208 180 909C0754
                SJ      vemapscalar_gate_clear_pswh_bit0             ; 155B 1 208 180 CB20
vemapscalar_gate_load_ram2d0:     MOVB    off(002d0h), #01eh     ; 155D 0 208 180 C4D0981E
vemapscalar_gate_load_stk:     L       A, (0016ch-00180h)[USP] ; 1561 1 208 180 E3EC
                MOV     X1, #0540bh            ; 1563 1 208 180 600B54
                MOV     X2, #0540fh            ; 1566 1 208 180 610F54
                J       vemapscalar_gate_if_ram212_bit5_set_2             ; 1569 1 208 180 03AC6F
vemapscalar_gate_load_x1_2:     MOV     X1, #05403h            ; 156C 1 208 180 600354
                MOV     X2, #05407h            ; 156F 1 208 180 610754
vemapscalar_gate_call_4977:     CAL     vemapscalar_gate_sub_sub_acc             ; 1572 1 208 180 327749
                MOV     DP, A                  ; 1575 1 208 180 52
                L       A, (0016ah-00180h)[USP] ; 1576 1 208 180 E3EA
                MOV     X1, X2                 ; 1578 1 208 180 9178
                CAL     vemapscalar_gate_sub_sub_acc             ; 157A 1 208 180 327749
vemapscalar_gate_clear_pswh_bit0:     RB      PSWH.0                 ; 157D 1 208 180 A208
                ST      A, (0016ah-00180h)[USP] ; 157F 1 208 180 D3EA
                L       A, DP                  ; 1581 1 208 180 42
                ST      A, (0016ch-00180h)[USP] ; 1582 1 208 180 D3EC
                SB      PSWH.0                 ; 1584 1 208 180 A218
vemapscalar_gate_vcal_4:     VCAL    4                      ; 1586 0 208 180 14
                JBR     off(00220h).3, sensor_bank_stamp_bc ; 1587 0 208 180 DB2003
                JBR     off(00211h).4, sensor_bank_bc_alt ; 158A 0 208 180 DC1106
sensor_bank_stamp_bc:     MOVB    0e0h, #0f9h            ; 158D 0 208 180 C5E098F9
                SJ      dcode14_return             ; 1591 0 208 180 CB18
sensor_bank_bc_alt:     CLR     A                      ; 1593 1 208 180 F9
                LB      A, #0e6h               ; 1594 0 208 180 77E6
                MOV     DP, #003d3h            ; 1596 0 208 180 62D303
                CMPB    A, [DP]                ; 1599 0 208 180 C2C2
                JLT     dtc13_baro_latch             ; 159B 0 208 180 CA0F
                LB      A, [DP]                ; 159D 0 208 180 F2
                CMPB    A, #050h               ; 159E 0 208 180 C650
                JLT     dtc13_baro_latch             ; 15A0 0 208 180 CA0A
                CAL     subtract24_clamp_byte             ; 15A2 0 208 180 327F44
                MOV     DP, #000e0h            ; 15A5 0 208 180 62E000
                CAL     ect_smooth_helper             ; 15A8 0 208 180 32E944
dcode14_return:     RC                             ; 15AB 0 208 180 95
dtc13_baro_latch:     MB      099h.2, C              ; 15AC 0 208 180 C5993A
                LB      A, 0e0h                ; 15AF 0 208 180 F5E0
                MOV     X1, #052e3h            ; 15B1 0 208 180 60E352
                VCAL    0                      ; 15B4 0 208 180 10
                STB     A, (00189h-00180h)[USP] ; 15B5 0 208 180 D309
                LB      A, 0e0h                ; 15B7 0 208 180 F5E0
                MOV     X1, #05346h            ; 15B9 0 208 180 604653
                VCAL    2                      ; 15BC 0 208 180 12
                STB     A, (00186h-00180h)[USP] ; 15BD 0 208 180 D306
                LB      A, 0e0h                ; 15BF 0 208 180 F5E0
                MOV     X1, #05287h            ; 15C1 0 208 180 608752
                VCAL    2                      ; 15C4 0 208 180 12
                STB     A, (0019ah-00180h)[USP] ; 15C5 0 208 180 D31A
                MOV     X1, #dcode14_check_tbl          ; 15C7 0 208 180 605456
                LB      A, 0e0h                ; 15CA 0 208 180 F5E0
                VCAL    2                      ; 15CC 0 208 180 12
                STB     A, off(00299h)         ; 15CD 0 208 180 D499
                MOV     X1, #053ffh            ; 15CF 0 208 180 60FF53
                LB      A, 0e0h                ; 15D2 0 208 180 F5E0
                VCAL    2                      ; 15D4 0 208 180 12
                STB     A, (00197h-00180h)[USP] ; 15D5 0 208 180 D317
                VCAL    4                      ; 15D7 0 208 180 14
                JBR     off(00211h).1, iat_range_check ; 15D8 0 208 180 D91106
                MOVB    0d8h, #086h            ; 15DB 0 208 180 C5D89886
                SJ      iat_check_return             ; 15DF 0 208 180 CB14
iat_range_check:     LB      A, #0fch               ; 15E1 0 208 180 77FC
                MOV     DP, #003d2h            ; 15E3 0 208 180 62D203
                CMPB    A, [DP]                ; 15E6 0 208 180 C2C2
                JLT     dtc10_iat_latch             ; 15E8 0 208 180 CA0C
                LB      A, [DP]                ; 15EA 0 208 180 F2
                CMPB    A, #004h               ; 15EB 0 208 180 C604
                JLT     dtc10_iat_latch             ; 15ED 0 208 180 CA07
                MOV     DP, #000d8h            ; 15EF 0 208 180 62D800
                CAL     ect_smooth_helper             ; 15F2 0 208 180 32E944
iat_check_return:     RC                             ; 15F5 0 208 180 95
dtc10_iat_latch:     MB      098h.6, C              ; 15F6 0 208 180 C5983E
                LB      A, 0d8h                ; 15F9 0 208 180 F5D8
                CMPB    A, #028h               ; 15FB 0 208 180 C628
                MB      off(00223h).2, C       ; 15FD 0 208 180 C4233A
                LB      A, 0d8h                ; 1600 0 208 180 F5D8
                MOV     X1, #05215h            ; 1602 0 208 180 601552
                VCAL    1                      ; 1605 0 208 180 11
                STB     A, (00152h-00180h)[USP] ; 1606 0 208 180 D3D2
                LB      A, #000h               ; 1608 0 208 180 7700
                JBS     off(00230h).4, sensor_bank_gate3_cmp_acc ; 160A 0 208 180 EC3002
                LB      A, #001h               ; 160D 0 208 180 7701
sensor_bank_gate3_cmp_acc:     CMPB    A, off(00289h)         ; 160F 0 208 180 C789
                MB      off(00230h).4, C       ; 1611 0 208 180 C4303C
                J       sensor_bank_gate3_clear_acc             ; 1614 0 208 180 03506E
sensor_bank_gate3_if_ram211_bit1_set:     JBS     off(00211h).1, sensor_bank_gate3_store_ram280 ; 1617 1 208 180 E91111
                CMPB    off(00288h), #000h     ; 161A 1 208 180 C488C000
                JLE     sensor_bank_gate3_store_ram280             ; 161E 1 208 180 CF0B
                LB      A, 0d8h                ; 1620 0 208 180 F5D8
                MOV     X1, #sensor_bank_gate3_tbl          ; 1622 0 208 180 600358
                CAL     sensor_bank_gate3_sub_vcal_0             ; 1625 0 208 180 32304F
                VCAL    0                      ; 1628 0 208 180 10
                STB     A, r2                  ; 1629 0 208 180 8A
                L       A, er1                 ; 162A 1 208 180 35
sensor_bank_gate3_store_ram280:     ST      A, off(00280h)         ; 162B 1 208 180 D480
                LB      A, 0d8h                ; 162D 0 208 180 F5D8
                MOV     X1, #sensor_bank_gate3_tbl_4          ; 162F 0 208 180 604B6A
                VCAL    2                      ; 1632 0 208 180 12
                STB     A, off(002cbh)         ; 1633 0 208 180 D4CB
                MOV     X1, #055c1h            ; 1635 0 208 180 60C155
                LB      A, 0d8h                ; 1638 0 208 180 F5D8
                VCAL    1                      ; 163A 0 208 180 11
                STB     A, off(00242h)         ; 163B 0 208 180 D442
                VCAL    4                      ; 163D 0 208 180 14
                LB      A, #044h               ; 163E 0 208 180 7744
                CMPB    A, 0dbh                ; 1640 0 208 180 C5DBC2
                JGE     dtc17_vss_latch             ; 1643 0 208 180 CD10
                CMPB    off(00289h), #0c0h     ; 1645 0 208 180 C489C0C0
                JGE     dtc17_vss_latch             ; 1649 0 208 180 CD0A
                RC                             ; 164B 0 208 180 95
                JBS     off(00212h).0, dtc17_vss_latch ; 164C 0 208 180 E81206
                JBR     off(00235h).5, dtc17_vss_latch ; 164F 0 208 180 DD3503
                MB      C, off(0021ah).2       ; 1652 0 208 180 C41A2A
dtc17_vss_latch:     MB      099h.4, C              ; 1655 0 208 180 C5993C
                CLRB    A                      ; 1658 0 208 180 FA
                JBS     off(00220h).0, sensor_bank_gate3_store_ram2a4 ; 1659 0 208 180 E82026
                JBS     off(00216h).1, sensor_bank_gate3_store_ram2a4 ; 165C 0 208 180 E91623
                JBS     off(00212h).0, sensor_bank_gate3_store_ram2a4 ; 165F 0 208 180 E81220
                MOVB    r1, 0dfh               ; 1662 0 208 180 C5DF49
                CLRB    r0                     ; 1665 0 208 180 2015
                L       A, 0aeh                ; 1667 1 208 180 E5AE
                MUL                            ; 1669 1 208 180 9035
                LB      A, r3                  ; 166B 0 208 180 7B
                JEQ     sensor_bank_gate3_load_r2             ; 166C 0 208 180 C902
                MOVB    r2, #0ffh              ; 166E 0 208 180 9AFF
sensor_bank_gate3_load_r2:     LB      A, r2                  ; 1670 0 208 180 7A
                CLR     X1                     ; 1671 0 208 180 9015
                MOV     DP, #00004h            ; 1673 0 208 180 620400
sensor_bank_gate3_cmp_acc_2:     CMPCB   A, 0545bh[X1]          ; 1676 0 208 180 90AF5B54
                JLT     sensor_bank_gate3_load_dp             ; 167A 0 208 180 CA03
                INC     X1                     ; 167C 0 208 180 70
                JRNZ    DP, sensor_bank_gate3_cmp_acc_2         ; 167D 0 208 180 30F7
sensor_bank_gate3_load_dp:     L       A, DP                  ; 167F 1 208 180 42
                LB      A, ACC                 ; 1680 0 208 180 F506
sensor_bank_gate3_store_ram2a4:     STB     A, off(002a4h)         ; 1682 0 208 180 D4A4
                LCB     A, 05176h[ACC]         ; 1684 0 208 180 B506AB7651
                STB     A, off(002a5h)         ; 1689 0 208 180 D4A5
                JBS     off(0021bh).7, sensor_bank_gate3_clear_carry ; 168B 0 208 180 EF1B29
                JBS     off(00210h).3, sensor_bank_gate3_clear_carry ; 168E 0 208 180 EB1026
                JBS     off(0021eh).1, sensor_bank_gate3_clear_carry ; 1691 0 208 180 E91E23
                JBS     off(00225h).6, sensor_bank_gate3_clear_carry ; 1694 0 208 180 EE2520
                MB      C, 099h.3              ; 1697 0 208 180 C5992B
                JLT     sensor_bank_gate3_if_ram21a_bit4_set             ; 169A 0 208 180 CA03
                JBR     off(00211h).5, sensor_bank_gate3_if_ram217_bit0_set ; 169C 0 208 180 DD1103
sensor_bank_gate3_if_ram21a_bit4_set:     JBS     off(0021ah).4, sensor_bank_gate3_clear_carry ; 169F 0 208 180 EC1A15
sensor_bank_gate3_if_ram217_bit0_set:     JBS     off(00217h).0, sensor_bank_gate3_clear_carry ; 16A2 0 208 180 E81712
                J       sensor_bank_gate3_if_ram216_bit1_set             ; 16A5 0 208 180 03D06D
sensor_bank_gate3_load_imm:     L       A, #0bc30h             ; 16A8 1 208 180 6730BC
                CMP     A, (00160h-00180h)[USP] ; 16AB 1 208 180 B3E0C2
                JLT     sensor_bank_gate3_store_carry_ram09d_bit7             ; 16AE 1 208 180 CA08
                CMP     (00160h-00180h)[USP], #05d80h                  ; 16B0 1 208 180 B3E0C0805D
                JLT     sensor_bank_gate3_store_carry_ram09d_bit7             ; 16B5 1 208 180 CA01
sensor_bank_gate3_clear_carry:     RC                             ; 16B7 0 208 180 95
sensor_bank_gate3_store_carry_ram09d_bit7:     MB      09dh.7, C              ; 16B8 0 208 180 C59D3F
                MOV     DP, #00304h            ; 16BB 0 208 180 620403
fueltbl_sanitize_check:     JBR     off(0021fh).0, fueltbl_range_check ; 16BE 0 208 180 D81F05
                MB      C, 0a0h.0              ; 16C1 0 208 180 C5A028
                JLT     fueltbl_default_value             ; 16C4 0 208 180 CA0C
fueltbl_range_check:     CMP     [DP], #09a99h          ; 16C6 0 208 180 B2C0999A
                JGT     fueltbl_default_value             ; 16CA 0 208 180 C806
                CMP     [DP], #06566h                         ; 16CC 0 208 180 B2C06665
                JGE     fueltbl_sanitize_advance             ; 16D0 0 208 180 CD04
fueltbl_default_value:     MOV     [DP], #08000h          ; 16D2 0 208 180 B2980080
fueltbl_sanitize_advance:     ADD     DP, #00004h            ; 16D6 0 208 180 92800400
                CMP     DP, #00310h            ; 16DA 0 208 180 92C01003
                JLT     fueltbl_sanitize_check             ; 16DE 0 208 180 CADE
                VCAL    4                      ; 16E0 0 208 180 14
                MOV     X1, #0523fh            ; 16E1 0 208 180 603F52
                LB      A, 0dfh                ; 16E4 0 208 180 F5DF
                CMPB    A, #00fh               ; 16E6 0 208 180 C60F
                JLT     fueltbl_sanitize_advance_load_ram0d8             ; 16E8 0 208 180 CA03
                MOV     X1, #05243h            ; 16EA 0 208 180 604352
fueltbl_sanitize_advance_load_ram0d8:     LB      A, 0d8h                ; 16ED 0 208 180 F5D8
                VCAL    2                      ; 16EF 0 208 180 12
                CMPB    0d9h, A                ; 16F0 0 208 180 C5D9C1
                MB      off(00218h).2, C       ; 16F3 0 208 180 C4183A
                JBR     off(0021eh).1, fueltbl_sanitize_advance_if_ram22f_bit5_set ; 16F6 0 208 180 D91E09
                SB      off(00218h).0          ; 16F9 0 208 180 C41818
                RB      off(00218h).1          ; 16FC 0 208 180 C41809
                J       injidx_flag_clear_set_ram22e_bit3             ; 16FF 0 208 180 038117
fueltbl_sanitize_advance_if_ram22f_bit5_set:     JBS     off(0022fh).5, injidx_flag_clear ; 1702 0 208 180 ED2F76
                JBS     off(00218h).3, injidx_flag_clear ; 1705 0 208 180 EB1873
                JBS     off(0021dh).0, injidx_flag_clear ; 1708 0 208 180 E81D70
                LB      A, off(002e2h)         ; 170B 0 208 180 F4E2
                JEQ     fueltbl_sanitize_advance_if_ram216_bit1_set             ; 170D 0 208 180 C90F
                RB      off(00218h).0          ; 170F 0 208 180 C41808
                RB      off(00218h).1          ; 1712 0 208 180 C41809
fueltbl_sanitize_advance_clear_ram22e_bit3:     RB      off(0022eh).3          ; 1715 0 208 180 C42E0B
                MOVB    off(002d8h), #064h     ; 1718 0 208 180 C4D89864
                SJ      vss_ect_gate_load_ram2d4             ; 171C 0 208 180 CB66
fueltbl_sanitize_advance_if_ram216_bit1_set:     JBS     off(00216h).1, fueltbl_sanitize_advance_clear_ram22e_bit3 ; 171E 0 208 180 E916F4
                JBS     off(00218h).0, vss_ect_gate ; 1721 0 208 180 E81836
                JBR     off(00218h).1, fueltbl_sanitize_advance_if_ram218_bit0_set ; 1724 0 208 180 D91809
                JBR     off(0021bh).2, vss_ect_gate ; 1727 0 208 180 DA1B30
                RB      off(00218h).1          ; 172A 0 208 180 C41809
                SB      off(0022eh).3          ; 172D 0 208 180 C42E1B
fueltbl_sanitize_advance_if_ram218_bit0_set:     JBS     off(00218h).0, closeloopnarrow_check ; 1730 0 208 180 E8181D
                JBS     off(00218h).1, closeloopnarrow_check ; 1733 0 208 180 E9181A
                JBS     off(0022eh).3, closeloopnarrow_check ; 1736 0 208 180 EB2E17
                JBR     off(0022ah).0, injidx_stamp_c2 ; 1739 0 208 180 D82A06
                JBR     off(00218h).2, injidx_stamp_c2 ; 173C 0 208 180 DA1803
                JBS     off(0021bh).2, injidx_c2_check ; 173F 0 208 180 EA1B06
injidx_stamp_c2:     MOVB    off(002d8h), #064h     ; 1742 0 208 180 C4D89864
                SJ      closeloopnarrow_check             ; 1746 0 208 180 CB08
injidx_c2_check:     LB      A, off(002d8h)         ; 1748 0 208 180 F4D8
                JNE     closeloopnarrow_check             ; 174A 0 208 180 CE04
                LB      A, #02eh               ; 174C 0 208 180 772E
                SJ      closeloopnarrow_result             ; 174E 0 208 180 CB02
closeloopnarrow_check:     LB      A, #019h               ; 1750 0 208 180 7719
closeloopnarrow_result:     CMPB    A, 0dah                ; 1752 0 208 180 C5DAC2
                JLT     vss_ect_gate             ; 1755 0 208 180 CA03
                SB      off(00218h).0          ; 1757 0 208 180 C41818
vss_ect_gate:     CMPB    0d9h, #028h            ; 175A 0 208 180 C5D9C028
                JGE     vss_ect_gate_load_ram2d4             ; 175E 0 208 180 CD24
                CMPB    0dfh, #005h            ; 1760 0 208 180 C5DFC005
                JGE     vss_ect_gate_load_ram2d4             ; 1764 0 208 180 CD1E
                CMPB    off(00289h), #080h     ; 1766 0 208 180 C489C080
                JLT     vss_ect_gate_load_ram2d4             ; 176A 0 208 180 CA18
                JBR     off(0021bh).2, vss_ect_gate_load_ram2d4 ; 176C 0 208 180 DA1B15
                LB      A, off(002d4h)         ; 176F 0 208 180 F4D4
                JNE     vss_ect_gate_load_carry_ram21e_bit1             ; 1771 0 208 180 CE15
                SB      off(00218h).0          ; 1773 0 208 180 C41818
                RB      off(00218h).1          ; 1776 0 208 180 C41809
                SJ      vss_ect_gate_load_carry_ram21e_bit1             ; 1779 0 208 180 CB0D
injidx_flag_clear:     RB      off(00218h).0          ; 177B 0 208 180 C41808
                SB      off(00218h).1          ; 177E 0 208 180 C41819
injidx_flag_clear_set_ram22e_bit3:     SB      off(0022eh).3          ; 1781 0 208 180 C42E1B
vss_ect_gate_load_ram2d4:     MOVB    off(002d4h), #005h     ; 1784 0 208 180 C4D49805
vss_ect_gate_load_carry_ram21e_bit1:     MB      C, off(0021eh).1       ; 1788 0 208 180 C41E29
                MB      off(0022fh).5, C       ; 178B 0 208 180 C42F3D
                MOVB    r0, #014h              ; 178E 0 208 180 9814
                MOVB    r1, #019h              ; 1790 0 208 180 9919
                MOVB    r2, #032h              ; 1792 0 208 180 9A32
                MOVB    r3, #01ah              ; 1794 0 208 180 9B1A
                J       vss_ect_gate_load_r4             ; 1796 0 208 180 030071
                DB  0D8h,017h,024h ; 1799
vss_ect_gate_load_ram2d6:     MOVB    off(002d6h), r1        ; 179C 0 208 180 217CD6
                MOVB    off(002d7h), r2        ; 179F 0 208 180 227CD7
                J       vss_ect_gate_if_ram218_bit0_clr             ; 17A2 0 208 180 031171
vss_ect_gate_goto_711d:     J       vss_ect_gate_load_stk             ; 17A5 0 208 180 031D71
                DB  044h,0BCh,0CDh,03Fh,0C6h,070h,05Dh,0CFh ; 17A8
                DB  03Ah ; 17B0
vss_ect_gate_load_r3:     LB      A, r3                  ; 17B1 0 208 180 7B
                CMPB    A, 0dah                ; 17B2 0 208 180 C5DAC2
                JLT     vss_ect_gate_load_ram2d3_2             ; 17B5 0 208 180 CA03
vss_ect_gate_load_ram2d3:     MOVB    off(002d3h), r0        ; 17B7 0 208 180 207CD3
vss_ect_gate_load_ram2d3_2:     LB      A, off(002d3h)         ; 17BA 0 208 180 F4D3
                JEQ     idle_stage_c0_load_clear_ram218_bit0             ; 17BC 0 208 180 C92D
                SJ      idle_stage_c0_load_nop_acc             ; 17BE 0 208 180 CB31
idle_stage_alt_start:     MOVB    off(002d3h), r0        ; 17C0 0 208 180 207CD3
                JBR     off(0021ah).0, idle_stage_c0_start ; 17C3 0 208 180 D81A15
                MOVB    off(002d7h), r2        ; 17C6 0 208 180 227CD7
                JBR     off(00218h).0, idle_stage_bf_store ; 17C9 0 208 180 D81806
                LB      A, r3                  ; 17CC 0 208 180 7B
                CMPB    A, 0dah                ; 17CD 0 208 180 C5DAC2
                JLT     idle_stage_bf_load             ; 17D0 0 208 180 CA03
idle_stage_bf_store:     MOVB    off(002d6h), r1        ; 17D2 0 208 180 217CD6
idle_stage_bf_load:     LB      A, off(002d6h)         ; 17D5 0 208 180 F4D6
                JEQ     idle_stage_c0_load_clear_ram218_bit0             ; 17D7 0 208 180 C912
                SJ      idle_stage_c0_load_nop_acc             ; 17D9 0 208 180 CB16
idle_stage_c0_start:     MOVB    off(002d6h), r1        ; 17DB 0 208 180 217CD6
                JBR     off(00218h).0, idle_stage_c0_store ; 17DE 0 208 180 D81803
                JBR     off(0021bh).6, idle_stage_c0_load ; 17E1 0 208 180 DE1B03
idle_stage_c0_store:     MOVB    off(002d7h), r2        ; 17E4 0 208 180 227CD7
idle_stage_c0_load:     LB      A, off(002d7h)         ; 17E7 0 208 180 F4D7
                JNE     idle_stage_c0_load_nop_acc             ; 17E9 0 208 180 CE06
idle_stage_c0_load_clear_ram218_bit0:     RB      off(00218h).0          ; 17EB 0 208 180 C41808
                SB      off(00218h).1          ; 17EE 0 208 180 C41819
idle_stage_c0_load_nop_acc:     NOP                            ; 17F1 0 208 180 00
                NOP                            ; 17F2 0 208 180 00
                NOP                            ; 17F3 0 208 180 00
                JBS     off(00216h).1, dcode14_clear ; 17F4 0 208 180 E9161B
                JBS     off(00211h).5, dcode14_clear ; 17F7 0 208 180 ED1118
                LB      A, 0dbh                ; 17FA 0 208 180 F5DB
                MOV     X1, #tbl_dcode14_lo          ; 17FC 0 208 180 603F57
                VCAL    3                      ; 17FF 0 208 180 13
                CMPB    A, off(0026eh)         ; 1800 0 208 180 C76E
                JLT     dcode14_clear             ; 1802 0 208 180 CA0E
                LB      A, 0dbh                ; 1804 0 208 180 F5DB
                MOV     X1, #tbl_dcode14_hi          ; 1806 0 208 180 604557
                VCAL    3                      ; 1809 0 208 180 13
                CMPB    A, off(0026eh)         ; 180A 0 208 180 C76E
                JGE     dcode14_clear             ; 180C 0 208 180 CD04
                LB      A, off(002e3h)         ; 180E 0 208 180 F4E3
                JEQ     dtc14_iacv_latch             ; 1810 0 208 180 C901
dcode14_clear:     RC                             ; 1812 0 208 180 95
dtc14_iacv_latch:     MB      099h.3, C              ; 1813 0 208 180 C5993B
                LB      A, off(002f5h)         ; 1816 0 208 180 F4F5
                JNE     dcode_threshold_check_clear_carry             ; 1818 0 208 180 CE52
                MOVB    off(002f5h), #006h     ; 181A 0 208 180 C4F59806
                LB      A, #0fah               ; 181E 0 208 180 77FA
                JBS     off(00216h).0, dcode_threshold_check_store_ram28b ; 1820 0 208 180 E81647
                STB     A, r0                  ; 1823 0 208 180 88
                LB      A, #078h               ; 1824 0 208 180 7778
                STB     A, r1                  ; 1826 0 208 180 89
                STB     A, r2                  ; 1827 0 208 180 8A
                JBS     off(00216h).4, tps_learn_table_store_load_r0 ; 1828 0 208 180 EC162E
                JBS     off(00216h).5, tps_learn_table_store_load_r0 ; 182B 0 208 180 ED162B
                LB      A, 0e8h                ; 182E 0 208 180 F5E8
                CMPB    A, r1                  ; 1830 0 208 180 49
                JGE     tps_learn_table_store_load_r0             ; 1831 0 208 180 CD26
                STB     A, r1                  ; 1833 0 208 180 89
                MOVB    r3, off(0028ch)        ; 1834 0 208 180 C48C4B
                SUBB    A, r3                  ; 1837 0 208 180 2B
                JLT     tps_learn_table_store             ; 1838 0 208 180 CA17
                CMPB    A, #004h               ; 183A 0 208 180 C604
                JGE     tps_learn_table_store_load_r0             ; 183C 0 208 180 CD1B
                SUBB    off(0028bh), #001h     ; 183E 0 208 180 C48BA001
                JNE     tps_learn_table_store_load_dp             ; 1842 0 208 180 CE1B
                MOV     DP, #0032fh            ; 1844 0 208 180 622F03
                LB      A, r3                  ; 1847 0 208 180 7B
                STB     A, [DP]                ; 1848 0 208 180 D2
                MOV     DP, #0032eh            ; 1849 0 208 180 622E03
                LB      A, #0ffh               ; 184C 0 208 180 77FF
                STB     A, [DP]                ; 184E 0 208 180 D2
                SJ      tps_learn_table_store_load_dp             ; 184F 0 208 180 CB0E
tps_learn_table_store:     MOV     DP, #0032eh            ; 1851 0 208 180 622E03
                LB      A, [DP]                ; 1854 0 208 180 F2
                JNE     tps_learn_table_store_load_r0             ; 1855 0 208 180 CE02
                MOVB    r0, #053h              ; 1857 0 208 180 9853
tps_learn_table_store_load_r0:     LB      A, r0                  ; 1859 0 208 180 78
                STB     A, off(0028bh)         ; 185A 0 208 180 D48B
                LB      A, r1                  ; 185C 0 208 180 79
                STB     A, off(0028ch)         ; 185D 0 208 180 D48C
tps_learn_table_store_load_dp:     MOV     DP, #0032fh            ; 185F 0 208 180 622F03
                LB      A, [DP]                ; 1862 0 208 180 F2
                CMPB    A, r2                  ; 1863 0 208 180 4A
                JLT     dcode_threshold_check_clear_carry             ; 1864 0 208 180 CA06
                LB      A, r2                  ; 1866 0 208 180 7A
                STB     A, [DP]                ; 1867 0 208 180 D2
                SJ      dcode_threshold_check_clear_carry             ; 1868 0 208 180 CB02
dcode_threshold_check_store_ram28b:     STB     A, off(0028bh)         ; 186A 0 208 180 D48B
dcode_threshold_check_clear_carry:     RC                             ; 186C 0 208 180 95
                LB      A, #025h               ; 186D 0 208 180 7725
                JBR     off(00220h).2, dcode_threshold_check_store_ram0dd ; 186F 0 208 180 DA2018
                JBS     off(00212h).3, dcode_threshold_check_store_ram0dd ; 1872 0 208 180 EB1215
                LB      A, #05eh               ; 1875 0 208 180 775E
                CMPB    A, 0dbh                ; 1877 0 208 180 C5DBC2
                JGE     dtc20_eld_latch             ; 187A 0 208 180 CD10
                LB      A, #0dch               ; 187C 0 208 180 77DC
                MOV     DP, #003d8h            ; 187E 0 208 180 62D803
                CMPB    A, [DP]                ; 1881 0 208 180 C2C2
                JLT     dtc20_eld_latch             ; 1883 0 208 180 CA07
                LB      A, [DP]                ; 1885 0 208 180 F2
                CMPB    A, #00eh               ; 1886 0 208 180 C60E
                JLT     dtc20_eld_latch             ; 1888 0 208 180 CA02
dcode_threshold_check_store_ram0dd:     STB     A, 0ddh                ; 188A 0 208 180 D5DD
dtc20_eld_latch:     MB      099h.7, C              ; 188C 0 208 180 C5993F
                RC                             ; 188F 0 208 180 95
                JBS     off(00220h).2, dcode_threshold_check_store_carry_ram218_bit3 ; 1890 0 208 180 EA2009
                JBR     off(00221h).2, dcode_threshold_check_store_carry_ram218_bit3 ; 1893 0 208 180 DA2106
                MOV     DP, #003d8h            ; 1896 0 208 180 62D803
                LB      A, [DP]                ; 1899 0 208 180 F2
                CMPB    A, #09ah               ; 189A 0 208 180 C69A
dcode_threshold_check_store_carry_ram218_bit3:     MB      off(00218h).3, C       ; 189C 0 208 180 C4183B
                VCAL    4                      ; 189F 0 208 180 14
                MOV     DP, #003d7h            ; 18A0 0 208 180 62D703
                LB      A, [DP]                ; 18A3 0 208 180 F2
                STB     A, 0dbh                ; 18A4 0 208 180 D5DB
                LB      A, 0dbh                ; 18A6 0 208 180 F5DB
                MOV     X1, #0502ch            ; 18A8 0 208 180 602C50
                VCAL    0                      ; 18AB 0 208 180 10
                STB     A, off(002a8h)         ; 18AC 0 208 180 D4A8
                LB      A, 0dbh                ; 18AE 0 208 180 F5DB
                MOV     X1, #052fbh            ; 18B0 0 208 180 60FB52
                VCAL    1                      ; 18B3 0 208 180 11
                STB     A, (00142h-00180h)[USP] ; 18B4 0 208 180 D3C2
                LB      A, #09ah               ; 18B6 0 208 180 779A
                JBS     off(00231h).6, dcode_threshold_check_cmp_acc ; 18B8 0 208 180 EE3102
                LB      A, #0a6h               ; 18BB 0 208 180 77A6
dcode_threshold_check_cmp_acc:     CMPB    A, off(00289h)         ; 18BD 0 208 180 C789
                MB      off(00231h).6, C       ; 18BF 0 208 180 C4313E
                LB      A, #0cdh               ; 18C2 0 208 180 77CD
                JBS     off(00231h).7, dcode_threshold_check_cmp_acc_2 ; 18C4 0 208 180 EF3102
                LB      A, #0d3h               ; 18C7 0 208 180 77D3
dcode_threshold_check_cmp_acc_2:     CMPB    A, off(00289h)         ; 18C9 0 208 180 C789
                MB      off(00231h).7, C       ; 18CB 0 208 180 C4313F
                LB      A, #064h               ; 18CE 0 208 180 7764
                JBS     off(00232h).0, dcode_threshold_check_cmp_acc_3 ; 18D0 0 208 180 E83202
                LB      A, #077h               ; 18D3 0 208 180 7777
dcode_threshold_check_cmp_acc_3:     CMPB    A, off(00288h)         ; 18D5 0 208 180 C788
                CLRB    A                      ; 18D7 0 208 180 FA
                MB      off(00232h).0, C       ; 18D8 0 208 180 C43238
                JGE     div_scale_mul_final_store_ram2ac             ; 18DB 0 208 180 CD2C
                CLR     A                      ; 18DD 1 208 180 F9
                MOV     DP, #003dch            ; 18DE 1 208 180 62DC03
                LB      A, [DP]                ; 18E1 0 208 180 F2
                SUBB    A, #007h               ; 18E2 0 208 180 A607
                JGE     div_scale_calc1             ; 18E4 0 208 180 CD01
                CLRB    A                      ; 18E6 0 208 180 FA
div_scale_calc1:     MOVB    r0, #051h              ; 18E7 0 208 180 9851
                DIVB                           ; 18E9 0 208 180 A236
                JBR     off(00231h).6, div_scale_gate_common ; 18EB 0 208 180 DE310D
                MOVB    r0, #01bh              ; 18EE 0 208 180 981B
                LB      A, r1                  ; 18F0 0 208 180 79
                DIVB                           ; 18F1 0 208 180 A236
                JBR     off(00231h).7, div_scale_gate_common ; 18F3 0 208 180 DF3105
                MOVB    r0, #009h              ; 18F6 0 208 180 9809
                LB      A, r1                  ; 18F8 0 208 180 79
                DIVB                           ; 18F9 0 208 180 A236
div_scale_gate_common:     CMPB    A, #003h               ; 18FB 0 208 180 C603
                JLT     div_scale_mul_final             ; 18FD 0 208 180 CA02
                LB      A, #002h               ; 18FF 0 208 180 7702
div_scale_mul_final:     MOVB    r0, #009h              ; 1901 0 208 180 9809
                MULB                           ; 1903 0 208 180 A234
                JBS     off(00224h).4, div_scale_mul_final_store_ram2ac ; 1905 0 208 180 EC2401
                VCAL    7                      ; 1908 0 208 180 17
div_scale_mul_final_store_ram2ac:     STB     A, off(002ach)         ; 1909 0 208 180 D4AC
                CLR     A                      ; 190B 1 208 180 F9
                LB      A, #0cbh               ; 190C 0 208 180 77CB
                JBS     off(0022ah).2, div_scale_mul_final_cmp_acc ; 190E 0 208 180 EA2A02
                LB      A, #0d0h               ; 1911 0 208 180 77D0
div_scale_mul_final_cmp_acc:     CMPB    A, off(00289h)         ; 1913 0 208 180 C789
                MB      off(0022ah).2, C       ; 1915 0 208 180 C42A3A
                LCB     A, 07ff0h              ; 1918 0 208 180 909DF07F
                SRLB    A                      ; 191C 0 208 180 63
                SRLB    A                      ; 191D 0 208 180 63
                CLRB    r2                     ; 191E 0 208 180 2215
                MOV     DP, #003d4h            ; 1920 0 208 180 62D403
                LB      A, [DP]                ; 1923 0 208 180 F2
                JLT     div_scale_mul_final_call_4a84             ; 1924 0 208 180 CA29
                CMPB    A, #0f0h               ; 1926 0 208 180 C6F0
                JLT     knock_div_calc1             ; 1928 0 208 180 CA02
                LB      A, #076h               ; 192A 0 208 180 7776
knock_div_calc1:     MOVB    r0, #030h              ; 192C 0 208 180 9830
                DIVB                           ; 192E 0 208 180 A236
                JBS     off(0022ah).2, knock_div_calc1_sllb_acc ; 1930 0 208 180 EA2A13
                SRLB    A                      ; 1933 0 208 180 63
                LB      A, r1                  ; 1934 0 208 180 79
                JGE     knock_div_calc2             ; 1935 0 208 180 CD03
                LB      A, #02fh               ; 1937 0 208 180 772F
                SUBB    A, r1                  ; 1939 0 208 180 29
knock_div_calc2:     MOVB    r0, #009h              ; 193A 0 208 180 9809
                DIVB                           ; 193C 0 208 180 A236
                CMPB    A, #004h               ; 193E 0 208 180 C604
                JLE     knock_div_calc2_addb_acc             ; 1940 0 208 180 CF02
                LB      A, #004h               ; 1942 0 208 180 7704
knock_div_calc2_addb_acc:     ADDB    A, #006h               ; 1944 0 208 180 8606
knock_div_calc1_sllb_acc:     SLLB    A                      ; 1946 0 208 180 53
                EXTND                          ; 1947 1 208 180 F8
                LC      A, 05413h[ACC]         ; 1948 1 208 180 B506A91354
                SJ      knock_div_calc1_store_stk             ; 194D 1 208 180 CB09
div_scale_mul_final_call_4a84:     CAL     div_scale_mul_final_sub_subb_acc             ; 194F 0 208 180 32844A
                ADDB    A, #080h               ; 1952 0 208 180 8680
                STB     A, r2                  ; 1954 0 208 180 8A
                L       A, #08000h             ; 1955 1 208 180 670080
knock_div_calc1_store_stk:     ST      A, (00162h-00180h)[USP] ; 1958 1 208 180 D3E2
                MOVB    off(002b3h), r2        ; 195A 1 208 180 227CB3
                VCAL    4                      ; 195D 1 208 180 14
                CLRB    A                      ; 195E 0 208 180 FA
;  [flow] knock module: per-cylinder handler select. Index from knock counter r2 (DIV by 09h etc.)
;    picks a word from handler-pointer tables @0542Bh or @05443h (alternate set when 0220h.0; the
;    same pointer list is mirrored @6AB7h) and a retard value from @6A9Fh (0FFh = channel disabled).
;    Handler words point into the code at 5441+...; results land on the frame at 0166h/0164h[USP].
;    07FF0h/07FF1h debug-flag reads gate the retard application (always 0 = enabled normally).
                MOV     DP, #003ddh            ; 195F 0 208 180 62DD03
                LCB     A, 07ff0h              ; 1962 0 208 180 909DF07F
                SRLB    A                      ; 1966 0 208 180 63
                SRLB    A                      ; 1967 0 208 180 63
                SRLB    A                      ; 1968 0 208 180 63
                JGE     knock_div_calc1_srlb_acc             ; 1969 0 208 180 CD0A
                LB      A, [DP]                ; 196B 0 208 180 F2
                CAL     div_scale_mul_final_sub_subb_acc             ; 196C 0 208 180 32844A
                ADDB    A, #080h               ; 196F 0 208 180 8680
                CLR     er0                    ; 1971 0 208 180 4415
                SJ      knock_div_calc1_store_ram290             ; 1973 0 208 180 CB12
knock_div_calc1_srlb_acc:     SRLB    A                      ; 1975 0 208 180 63
                JGE     knock_div_calc1_clear_acc             ; 1976 0 208 180 CD17
                LB      A, [DP]                ; 1978 0 208 180 F2
                CAL     div_scale_mul_final_sub_subb_acc             ; 1979 0 208 180 32844A
                MOVB    r0, #080h              ; 197C 0 208 180 9880
                MULB                           ; 197E 0 208 180 A234
                L       A, ACC                 ; 1980 1 208 180 E506
                ADD     A, #0c000h             ; 1982 1 208 180 8600C0
                ST      A, er0                 ; 1985 1 208 180 88
                CLRB    A                      ; 1986 0 208 180 FA
knock_div_calc1_store_ram290:     STB     A, off(00290h)         ; 1987 0 208 180 D490
                MOV     off(0026ch), er0       ; 1989 0 208 180 447C6C
                CLR     A                      ; 198C 1 208 180 F9
                SJ      knock_div_calc1_load_imm             ; 198D 1 208 180 CB0B
knock_div_calc1_clear_acc:     CLRB    A                      ; 198F 0 208 180 FA
                STB     A, off(00290h)         ; 1990 0 208 180 D490
                CLR     A                      ; 1992 1 208 180 F9
                ST      A, off(0026ch)         ; 1993 1 208 180 D46C
                LB      A, [DP]                ; 1995 0 208 180 F2
                CMPB    A, #0f0h               ; 1996 0 208 180 C6F0
                JLT     knock_div_calc3             ; 1998 0 208 180 CA02
knock_div_calc1_load_imm:     LB      A, #076h               ; 199A 0 208 180 7776
knock_div_calc3:     MOVB    r0, #030h              ; 199C 0 208 180 9830
                DIVB                           ; 199E 0 208 180 A236
                STB     A, r2                  ; 19A0 0 208 180 8A
                SRLB    A                      ; 19A1 0 208 180 63
                LB      A, r1                  ; 19A2 0 208 180 79
                JGE     knock_div_calc4             ; 19A3 0 208 180 CD03
                LB      A, #02fh               ; 19A5 0 208 180 772F
                SUBB    A, r1                  ; 19A7 0 208 180 29
knock_div_calc4:     MOVB    r0, #009h              ; 19A8 0 208 180 9809
                DIVB                           ; 19AA 0 208 180 A236
                CMPB    A, #004h               ; 19AC 0 208 180 C604
                JLE     knock_div_calc4_addb_acc             ; 19AE 0 208 180 CF02
                LB      A, #004h               ; 19B0 0 208 180 7704
knock_div_calc4_addb_acc:     ADDB    A, #006h               ; 19B2 0 208 180 8606
                SLLB    A                      ; 19B4 0 208 180 53
                EXTND                          ; 19B5 1 208 180 F8
                MOV     X1, #0542bh            ; 19B6 1 208 180 602B54
                MOV     X2, #tbl_knock_retard_6a9f          ; 19B9 1 208 180 619F6A
                JBS     off(00220h).0, knock_div_calc4_if_ram21f_bit3_clr ; 19BC 1 208 180 E82006
                MOV     X1, #05443h            ; 19BF 1 208 180 604354
                MOV     X2, #tbl_knock_ptr_6ab7          ; 19C2 1 208 180 61B76A
knock_div_calc4_if_ram21f_bit3_clr:     JBR     off(0021fh).3, knock_div_calc4_load_x2 ; 19C5 1 208 180 DB1F02
                MOV     X1, X2                 ; 19C8 1 208 180 9178
knock_div_calc4_load_x2:     MOV     X2, X1                 ; 19CA 1 208 180 9079
                ADD     X1, A                  ; 19CC 1 208 180 9081
                LC      A, [X1]                ; 19CE 1 208 180 90A8
                ST      A, (00166h-00180h)[USP] ; 19D0 1 208 180 D3E6
                LB      A, r2                  ; 19D2 0 208 180 7A
                SLLB    A                      ; 19D3 0 208 180 53
                EXTND                          ; 19D4 1 208 180 F8
                ADD     X2, A                  ; 19D5 1 208 180 9181
                LC      A, [X2]                ; 19D7 1 208 180 91A8
                ST      A, (00164h-00180h)[USP] ; 19D9 1 208 180 D3E4
                MOV     DP, #003deh            ; 19DB 1 208 180 62DE03
                LB      A, [DP]                ; 19DE 0 208 180 F2
                SUBB    A, #07eh               ; 19DF 0 208 180 A67E
                CAL     div_scale_mul_final_sub_if_le_goto_4a8d             ; 19E1 0 208 180 32864A
                ADDB    A, #080h               ; 19E4 0 208 180 8680
                STB     A, r0                  ; 19E6 0 208 180 88
                LCB     A, 07ff1h              ; 19E7 0 208 180 909DF17F
                JEQ     knock_div_calc4_store_stk             ; 19EB 0 208 180 C901
                LB      A, r0                  ; 19ED 0 208 180 78
knock_div_calc4_store_stk:     STB     A, (0018bh-00180h)[USP] ; 19EE 0 208 180 D30B
                CLRB    ACC                    ; 19F0 0 208 180 C50615
                JNE     knock_div_calc4_store_stk_2             ; 19F3 0 208 180 CE09
                LCB     A, 07ff0h              ; 19F5 0 208 180 909DF07F
                SRLB    A                      ; 19F9 0 208 180 63
                CLRB    A                      ; 19FA 0 208 180 FA
                JGE     knock_div_calc4_store_stk_2             ; 19FB 0 208 180 CD01
                LB      A, r0                  ; 19FD 0 208 180 78
knock_div_calc4_store_stk_2:     STB     A, (00184h-00180h)[USP] ; 19FE 0 208 180 D304
                CLR     A                      ; 1A00 1 208 180 F9
                MOV     DP, #003d6h            ; 1A01 1 208 180 62D603
                LB      A, [DP]                ; 1A04 0 208 180 F2
                ADDB    A, #020h               ; 1A05 0 208 180 8620
                JGE     knock_div_calc4_srlb_acc             ; 1A07 0 208 180 CD04
                LB      A, #004h               ; 1A09 0 208 180 7704
                SJ      knock_div_calc4_rom_load_tbl_6a46_acc             ; 1A0B 0 208 180 CB05
knock_div_calc4_srlb_acc:     SRLB    A                      ; 1A0D 0 208 180 63
                SRLB    A                      ; 1A0E 0 208 180 63
                ANDB    A, #0f0h               ; 1A0F 0 208 180 D6F0
                SWAPB                          ; 1A11 0 208 180 83
knock_div_calc4_rom_load_tbl_6a46_acc:     LCB     A, tbl_knock_6a46[ACC]       ; 1A12 0 208 180 B506AB466A
                STB     A, (00195h-00180h)[USP] ; 1A17 0 208 180 D315
                VCAL    4                      ; 1A19 0 208 180 14
                SC                             ; 1A1A 0 208 180 85
                LB      A, off(002efh)         ; 1A1B 0 208 180 F4EF
                JNE     knock_div_calc4_store_carry_ram225_bit1             ; 1A1D 0 208 180 CE07
                JBS     off(00214h).0, knock_div_calc4_store_carry_ram225_bit1 ; 1A1F 0 208 180 E81404
                JBR     off(00216h).0, knock_div_calc4_store_carry_ram225_bit1 ; 1A22 0 208 180 D81601
                RC                             ; 1A25 0 208 180 95
knock_div_calc4_store_carry_ram225_bit1:     MB      off(00225h).1, C       ; 1A26 0 208 180 C42539
                JBS     off(00224h).2, knock_div_calc4_clear_carry_2 ; 1A29 0 208 180 EA2422
                JBS     off(00233h).6, knock_div_calc4_set_carry ; 1A2C 0 208 180 EE331B
                JBS     off(00233h).7, knock_div_calc4_set_carry ; 1A2F 0 208 180 EF3318
                LCB     A, 07ff1h              ; 1A32 0 208 180 909DF17F
                JNE     knock_div_calc4_if_ram214_bit0_set             ; 1A36 0 208 180 CE04
                LB      A, 0d5h                ; 1A38 0 208 180 F5D5
                JNE     knock_div_calc4_set_carry             ; 1A3A 0 208 180 CE0E
knock_div_calc4_if_ram214_bit0_set:     JBS     off(00214h).0, knock_div_calc4_clear_ram2e1 ; 1A3C 0 208 180 E81403
                JBS     off(00216h).0, knock_div_calc4_clear_carry ; 1A3F 0 208 180 E81603
knock_div_calc4_clear_ram2e1:     CLRB    off(002e1h)            ; 1A42 0 208 180 C4E115
knock_div_calc4_clear_carry:     RC                             ; 1A45 0 208 180 95
                LB      A, off(002e1h)         ; 1A46 0 208 180 F4E1
                JEQ     knock_div_calc4_store_carry_ram226_bit3             ; 1A48 0 208 180 C901
knock_div_calc4_set_carry:     SC                             ; 1A4A 0 208 180 85
knock_div_calc4_store_carry_ram226_bit3:     MB      off(00226h).3, C       ; 1A4B 0 208 180 C4263B
knock_div_calc4_clear_carry_2:     RC                             ; 1A4E 0 208 180 95
                JBR     off(00220h).4, dtc25_code25_latch ; 1A4F 0 208 180 DC201C
                JBS     off(00216h).1, dtc25_code25_latch ; 1A52 0 208 180 E91619
                JBS     off(00213h).0, dtc25_code25_latch ; 1A55 0 208 180 E81316
                JBS     off(00213h).1, dtc25_code25_latch ; 1A58 0 208 180 E91313
                JBS     off(0022fh).4, dtc25_code25_latch ; 1A5B 0 208 180 EC2F10
                LB      A, #07dh               ; 1A5E 0 208 180 777D
                CMPB    A, 0dbh                ; 1A60 0 208 180 C5DBC2
                JGE     dtc25_code25_latch             ; 1A63 0 208 180 CD09
                MB      C, off(00224h).3       ; 1A65 0 208 180 C4242B
                JBR     off(0022fh).3, dtc25_code25_latch ; 1A68 0 208 180 DB2F03
                XORB    PSWH, #080h            ; 1A6B 0 208 180 A2F080
dtc25_code25_latch:     MB      09bh.0, C              ; 1A6E 0 208 180 C59B38
                RC                             ; 1A71 0 208 180 95
                JBR     off(00220h).4, dtc26_code26_latch ; 1A72 0 208 180 DC2010
                JBS     off(00216h).1, dtc26_code26_latch ; 1A75 0 208 180 E9160D
                JBS     off(00213h).1, dtc26_code26_latch ; 1A78 0 208 180 E9130A
                LB      A, #07dh               ; 1A7B 0 208 180 777D
                CMPB    A, 0dbh                ; 1A7D 0 208 180 C5DBC2
                JGE     dtc26_code26_latch             ; 1A80 0 208 180 CD03
                MB      C, off(0022fh).4       ; 1A82 0 208 180 C42F2C
dtc26_code26_latch:     MB      09bh.1, C              ; 1A85 0 208 180 C59B39
                JBS     off(00215h).1, knock_div_calc4_if_ram215_bit1_set ; 1A88 0 208 180 E9151E
                JBS     off(00216h).1, knock_div_calc4_if_ram211_bit0_set ; 1A8B 0 208 180 E91603
                JBS     off(00215h).0, knock_div_calc4_if_ram22a_bit3_clr ; 1A8E 0 208 180 E81505
knock_div_calc4_if_ram211_bit0_set:     JBS     off(00211h).0, knock_div_calc4_set_ram215_bit1 ; 1A91 0 208 180 E81112
                SJ      knock_div_calc4_load_imm             ; 1A94 0 208 180 CB06
knock_div_calc4_if_ram22a_bit3_clr:     JBR     off(0022ah).3, knock_div_calc4_load_imm ; 1A96 0 208 180 DB2A03
                J       knock_div_calc4_if_ram21d_bit0_set             ; 1A99 0 208 180 03C06E
knock_div_calc4_load_imm:     LB      A, #0ffh               ; 1A9C 0 208 180 77FF
                STB     A, off(002edh)         ; 1A9E 0 208 180 D4ED
                SJ      knock_div_calc4_if_ram215_bit1_set             ; 1AA0 0 208 180 CB07
knock_div_calc4_load_ram2ed:     LB      A, off(002edh)         ; 1AA2 0 208 180 F4ED
                JNE     knock_div_calc4_if_ram215_bit1_set             ; 1AA4 0 208 180 CE03
knock_div_calc4_set_ram215_bit1:     SB      off(00215h).1          ; 1AA6 0 208 180 C41519
knock_div_calc4_if_ram215_bit1_set:     JBS     off(00215h).1, knock_div_calc4_if_ram215_bit1_set_2 ; 1AA9 0 208 180 E9151F
                J       knock_div_calc4_if_ram215_bit0_clr             ; 1AAC 0 208 180 03D04D
knock_div_calc4_if_ram213_bit1_set:     JBS     off(00213h).1, knock_div_calc4_if_ram224_bit3_clr ; 1AAF 0 208 180 E91303
                JBR     off(0022fh).4, knock_div_calc4_load_imm_2 ; 1AB2 0 208 180 DC2F12
knock_div_calc4_if_ram224_bit3_clr:     JBR     off(00224h).3, knock_div_calc4_load_imm_2 ; 1AB5 0 208 180 DB240F
                JBS     off(00217h).0, knock_div_calc4_load_ram2ee ; 1AB8 0 208 180 E81703
                JBS     off(0021dh).3, knock_div_calc4_load_imm_2 ; 1ABB 0 208 180 EB1D09
knock_div_calc4_load_ram2ee:     LB      A, off(002eeh)         ; 1ABE 0 208 180 F4EE
                JNE     knock_div_calc4_if_ram215_bit1_set_2             ; 1AC0 0 208 180 CE09
                SB      off(00215h).1          ; 1AC2 0 208 180 C41519
                SJ      knock_div_calc4_if_ram215_bit1_set_2             ; 1AC5 0 208 180 CB04
knock_div_calc4_load_imm_2:     LB      A, #0ffh               ; 1AC7 0 208 180 77FF
                STB     A, off(002eeh)         ; 1AC9 0 208 180 D4EE
knock_div_calc4_if_ram215_bit1_set_2:     JBS     off(00215h).1, accut_check_c3_vcal_4 ; 1ACB 0 208 180 E9151F
                J       knock_div_calc4_if_ram215_bit0_clr_2             ; 1ACE 0 208 180 03E04D
knock_div_calc4_if_ram22f_bit4_set:     JBS     off(0022fh).4, knock_div_calc4_load_imm_3 ; 1AD1 0 208 180 EC2F0C
                JBR     off(00213h).0, knock_div_calc4_load_imm_3 ; 1AD4 0 208 180 D81309
                JBS     off(00217h).0, knock_div_calc4_if_ram22f_bit3_set ; 1AD7 0 208 180 E81703
                JBS     off(0021dh).3, knock_div_calc4_load_imm_3 ; 1ADA 0 208 180 EB1D03
knock_div_calc4_if_ram22f_bit3_set:     JBS     off(0022fh).3, accut_check_c3 ; 1ADD 0 208 180 EB2F06
knock_div_calc4_load_imm_3:     LB      A, #0ffh               ; 1AE0 0 208 180 77FF
                STB     A, off(002f0h)         ; 1AE2 0 208 180 D4F0
                SJ      accut_check_c3_vcal_4             ; 1AE4 0 208 180 CB07
accut_check_c3:     LB      A, off(002f0h)         ; 1AE6 0 208 180 F4F0
                JNE     accut_check_c3_vcal_4             ; 1AE8 0 208 180 CE03
                SB      off(00215h).1          ; 1AEA 0 208 180 C41519
accut_check_c3_vcal_4:     VCAL    4                      ; 1AED 0 208 180 14
                CMPB    0ffh, #019h            ; 1AEE 0 208 180 C5FFC019
                JLT     accut_check_c3_clear_ram2da             ; 1AF2 0 208 180 CA2E
                CMPB    0d9h, #015h            ; 1AF4 0 208 180 C5D9C015
                JLT     accut_check_c3_load_imm             ; 1AF8 0 208 180 CA2D
accut_check_c3_if_ram215_bit6_set:     JBS     off(00215h).6, accut_check_c3_if_ram224_bit0_clr ; 1AFA 0 208 180 EE1550
                LB      A, #033h               ; 1AFD 0 208 180 7733
                JBS     off(0022fh).0, accut_check_c3_cmp_acc ; 1AFF 0 208 180 E82F02
                LB      A, #09ah               ; 1B02 0 208 180 779A
accut_check_c3_cmp_acc:     CMPB    A, 0abh                ; 1B04 0 208 180 C5ABC2
                MB      off(0022fh).0, C       ; 1B07 0 208 180 C42F38
                JLT     accut_check_c3_load_ram2da             ; 1B0A 0 208 180 CA3D
                LB      A, #010h               ; 1B0C 0 208 180 7710
                JBS     off(0022eh).7, accut_check_c3_cmp_acc_2 ; 1B0E 0 208 180 EF2E02
                LB      A, #020h               ; 1B11 0 208 180 7720
accut_check_c3_cmp_acc_2:     CMPB    A, 0dfh                ; 1B13 0 208 180 C5DFC2
                MB      off(0022eh).7, C       ; 1B16 0 208 180 C42E3F
                CLRB    A                      ; 1B19 0 208 180 FA
                JLT     accut_check_c3_store_ram2da             ; 1B1A 0 208 180 CA02
                LB      A, #028h               ; 1B1C 0 208 180 7728
accut_check_c3_store_ram2da:     STB     A, off(002dah)         ; 1B1E 0 208 180 D4DA
                SJ      accut_check_c3_if_ram224_bit0_clr             ; 1B20 0 208 180 CB2B
accut_check_c3_clear_ram2da:     CLRB    off(002dah)            ; 1B22 0 208 180 C4DA15
                SJ      accut_check_c3_clear_ram2f8             ; 1B25 0 208 180 CB1D
accut_check_c3_load_imm:     LB      A, #07dh               ; 1B27 0 208 180 777D
                JBS     off(0022eh).6, accut_check_c3_cmp_acc_3 ; 1B29 0 208 180 EE2E02
                LB      A, #082h               ; 1B2C 0 208 180 7782
accut_check_c3_cmp_acc_3:     CMPB    A, 0dfh                ; 1B2E 0 208 180 C5DFC2
                MB      off(0022eh).6, C       ; 1B31 0 208 180 C42E3E
                JGE     accut_check_c3_if_ram215_bit6_set             ; 1B34 0 208 180 CDC4
                LB      A, #0cdh               ; 1B36 0 208 180 77CD
                JBS     off(0022eh).4, accut_check_c3_cmp_acc_4 ; 1B38 0 208 180 EC2E02
                LB      A, #0d0h               ; 1B3B 0 208 180 77D0
accut_check_c3_cmp_acc_4:     CMPB    A, off(00289h)         ; 1B3D 0 208 180 C789
                MB      off(0022eh).4, C       ; 1B3F 0 208 180 C42E3C
                JGE     accut_check_c3_if_ram215_bit6_set             ; 1B42 0 208 180 CDB6
accut_check_c3_clear_ram2f8:     CLRB    off(002f8h)            ; 1B44 0 208 180 C4F815
                SJ      accut_check_c3_clear_ram22e_bit5             ; 1B47 0 208 180 CB15
accut_check_c3_load_ram2da:     LB      A, off(002dah)         ; 1B49 0 208 180 F4DA
                JNE     accut_check_c3_clear_ram2f8             ; 1B4B 0 208 180 CEF7
;  [flow] A/C cut decision (p13info 'AC stuff @1B4D'). Reads A/C switch input 0224h.0 (ACS pin B5:
;    grounded -> bit set). While the switch is NOT active it clears the A/C-request flag 022Eh.5;
;    the compressor relay/flag path continues via 022Eh.5 elsewhere (idle-up at 3C25 etc.).
accut_check_c3_if_ram224_bit0_clr:     JBR     off(00224h).0, accut_check_c3_clear_ram22e_bit5 ; 1B4D 0 208 180 D8240E
                SB      off(0022eh).5          ; 1B50 0 208 180 C42E1D
                LB      A, off(002f7h)         ; 1B53 0 208 180 F4F7
                JNE     accut_check_c3_clear_carry             ; 1B55 0 208 180 CE12
                MOVB    off(002f8h), #028h     ; 1B57 0 208 180 C4F89828
accut_check_c3_set_carry:     SC                             ; 1B5B 0 208 180 85
                SJ      accut_check_c3_store_carry_ram225_bit0             ; 1B5C 0 208 180 CB0C
accut_check_c3_clear_ram22e_bit5:     RB      off(0022eh).5          ; 1B5E 0 208 180 C42E0D
                LB      A, off(002f8h)         ; 1B61 0 208 180 F4F8
                JNE     accut_check_c3_set_carry             ; 1B63 0 208 180 CEF6
                MOVB    off(002f7h), #02dh     ; 1B65 0 208 180 C4F7982D
accut_check_c3_clear_carry:     RC                             ; 1B69 0 208 180 95
accut_check_c3_store_carry_ram225_bit0:     MB      off(00225h).0, C       ; 1B6A 0 208 180 C42538
                MB      off(00215h).2, C       ; 1B6D 0 208 180 C4153A
                SC                             ; 1B70 0 208 180 85
                JBS     off(00216h).1, purge_counter_check_store_carry_ram225_bit7 ; 1B71 0 208 180 E9161E
                JBS     off(00210h).5, purge_counter_check ; 1B74 0 208 180 ED1007
                LB      A, #038h               ; 1B77 0 208 180 7738
                CMPB    A, 0d9h                ; 1B79 0 208 180 C5D9C2
                JLT     purge_counter_check_store_carry_ram225_bit7             ; 1B7C 0 208 180 CA14
purge_counter_check:     CMP     (00172h-00180h)[USP], #005d7h ; 1B7E 0 208 180 B3F2C0D705
                JLT     purge_counter_check_store_carry_ram225_bit7             ; 1B83 0 208 180 CA0D
                CMPB    off(002bfh), #005h     ; 1B85 0 208 180 C4BFC005
                JNE     purge_counter_check_clear_carry             ; 1B89 0 208 180 CE06
                CMPB    off(002d9h), #019h     ; 1B8B 0 208 180 C4D9C019
                JLT     purge_counter_check_store_carry_ram225_bit7             ; 1B8F 0 208 180 CA01
purge_counter_check_clear_carry:     RC                             ; 1B91 0 208 180 95
purge_counter_check_store_carry_ram225_bit7:     MB      off(00225h).7, C       ; 1B92 0 208 180 C4253F
                LB      A, #0c7h               ; 1B95 0 208 180 77C7
                JBR     off(00225h).4, purge_counter_check_cmp_ram289 ; 1B97 0 208 180 DC2502
                LB      A, #0cah               ; 1B9A 0 208 180 77CA
purge_counter_check_cmp_ram289:     CMPB    off(00289h), A         ; 1B9C 0 208 180 C489C1
                MB      off(00225h).4, C       ; 1B9F 0 208 180 C4253C
                LB      A, #0bah               ; 1BA2 0 208 180 77BA
                JBR     off(00225h).5, purge_counter_check_cmp_ram289_2 ; 1BA4 0 208 180 DD2502
                LB      A, #0bfh               ; 1BA7 0 208 180 77BF
purge_counter_check_cmp_ram289_2:     CMPB    off(00289h), A         ; 1BA9 0 208 180 C489C1
                MB      off(00225h).5, C       ; 1BAC 0 208 180 C4253D
                CLRB    A                      ; 1BAF 0 208 180 FA
                RC                             ; 1BB0 0 208 180 95
                JBS     off(00215h).6, purge_counter_check_store_ram2d1 ; 1BB1 0 208 180 EE1518
                JBS     off(0021dh).4, purge_counter_check_cmp_ram0d8 ; 1BB4 0 208 180 EC1D07
                LB      A, off(002d1h)         ; 1BB7 0 208 180 F4D1
                JEQ     purge_counter_check_store_ram2d1             ; 1BB9 0 208 180 C911
                SC                             ; 1BBB 0 208 180 85
                SJ      purge_counter_check_store_ram2d1             ; 1BBC 0 208 180 CB0E
purge_counter_check_cmp_ram0d8:     CMPB    0d8h, #000h            ; 1BBE 0 208 180 C5D8C000
                JGE     purge_counter_check_store_ram2d1             ; 1BC2 0 208 180 CD08
                CMPB    0d9h, #000h            ; 1BC4 0 208 180 C5D9C000
                JGE     purge_counter_check_store_ram2d1             ; 1BC8 0 208 180 CD02
                LB      A, #000h               ; 1BCA 0 208 180 7700
purge_counter_check_store_ram2d1:     STB     A, off(002d1h)         ; 1BCC 0 208 180 D4D1
                MB      off(00225h).6, C       ; 1BCE 0 208 180 C4253E
                MB      off(00215h).3, C       ; 1BD1 0 208 180 C4153B
                MOVB    r0, 0dfh               ; 1BD4 0 208 180 C5DF48
                LB      A, #00dh               ; 1BD7 0 208 180 770D
                JBS     off(00234h).2, purge_counter_check_cmp_acc ; 1BD9 0 208 180 EA3402
                LB      A, #00fh               ; 1BDC 0 208 180 770F
purge_counter_check_cmp_acc:     CMPB    A, r0                  ; 1BDE 0 208 180 48
                MB      off(00234h).2, C       ; 1BDF 0 208 180 C4343A
                LB      A, #044h               ; 1BE2 0 208 180 7744
                JBS     off(00234h).3, purge_counter_check_cmp_acc_2 ; 1BE4 0 208 180 EB3402
                LB      A, #046h               ; 1BE7 0 208 180 7746
purge_counter_check_cmp_acc_2:     CMPB    A, r0                  ; 1BE9 0 208 180 48
                MB      off(00234h).3, C       ; 1BEA 0 208 180 C4343B
                LB      A, #044h               ; 1BED 0 208 180 7744
                JBS     off(00234h).4, purge_counter_check_cmp_acc_3 ; 1BEF 0 208 180 EC3402
                LB      A, #046h               ; 1BF2 0 208 180 7746
purge_counter_check_cmp_acc_3:     CMPB    A, r0                  ; 1BF4 0 208 180 48
                MB      off(00234h).4, C       ; 1BF5 0 208 180 C4343C
                MOVB    r0, off(00289h)        ; 1BF8 0 208 180 C48948
                LB      A, #053h               ; 1BFB 0 208 180 7753
                JBS     off(00234h).5, purge_counter_check_cmp_acc_4 ; 1BFD 0 208 180 ED3402
                LB      A, #066h               ; 1C00 0 208 180 7766
purge_counter_check_cmp_acc_4:     CMPB    A, r0                  ; 1C02 0 208 180 48
                MB      off(00234h).5, C       ; 1C03 0 208 180 C4343D
                LB      A, #0a0h               ; 1C06 0 208 180 77A0
                JBS     off(00234h).6, purge_counter_check_cmp_acc_5 ; 1C08 0 208 180 EE3402
                LB      A, #0b0h               ; 1C0B 0 208 180 77B0
purge_counter_check_cmp_acc_5:     CMPB    A, r0                  ; 1C0D 0 208 180 48
                MB      off(00234h).6, C       ; 1C0E 0 208 180 C4343E
                LB      A, #070h               ; 1C11 0 208 180 7770
                JBS     off(00234h).7, purge_counter_check_cmp_ram0dd ; 1C13 0 208 180 EF3402
                LB      A, #060h               ; 1C16 0 208 180 7760
purge_counter_check_cmp_ram0dd:     CMPB    0ddh, A                ; 1C18 0 208 180 C5DDC1
                MB      off(00234h).7, C       ; 1C1B 0 208 180 C4343F
                JBR     off(00220h).2, purge_counter_check_clear_ram225_bit2 ; 1C1E 0 208 180 DA2009
                JBS     off(00215h).6, purge_counter_check_clear_ram225_bit2 ; 1C21 0 208 180 EE1506
                JBS     off(00224h).2, purge_counter_check_clear_ram225_bit2 ; 1C24 0 208 180 EA2403
                JBR     off(00216h).0, state_dispatch2 ; 1C27 0 208 180 D81606
purge_counter_check_clear_ram225_bit2:     RB      off(00225h).2          ; 1C2A 0 208 180 C4250A
                J       state_dispatch4_set_ram225_bit3             ; 1C2D 0 208 180 03D31C
state_dispatch2:     JBR     off(00234h).2, state_dispatch3_load_ram2e6_2 ; 1C30 0 208 180 DA3431
                JBS     off(0021ah).0, state_dispatch3 ; 1C33 0 208 180 E81A06
                JBR     off(00220h).0, state_dispatch3_load_ram2e6_2 ; 1C36 0 208 180 D8202B
                JBR     off(0021ch).1, state_dispatch3_load_ram2e6_2 ; 1C39 0 208 180 D91C28
state_dispatch3:     JBR     off(00234h).5, state_dispatch3_load_ram2e6_2 ; 1C3C 0 208 180 DD3425
                JBS     off(00234h).4, state_dispatch3_load_ram2e6 ; 1C3F 0 208 180 EC3414
                CMPB    0d9h, #028h            ; 1C42 0 208 180 C5D9C028
                JGE     state_dispatch3_load_ram2e6             ; 1C46 0 208 180 CD0E
                JBS     off(00235h).0, state_dispatch3_load_ram2e6 ; 1C48 0 208 180 E8350B
                LB      A, off(002e6h)         ; 1C4B 0 208 180 F4E6
                JNE     state_dispatch3_load_ram2e7             ; 1C4D 0 208 180 CE19
                MOVB    off(002e7h), #003h     ; 1C4F 0 208 180 C4E79803
state_dispatch3_set_carry:     SC                             ; 1C53 0 208 180 85
                SJ      state_dispatch3_store_carry_ram225_bit2             ; 1C54 0 208 180 CB05
state_dispatch3_load_ram2e6:     MOVB    off(002e6h), #003h     ; 1C56 0 208 180 C4E69803
                RC                             ; 1C5A 0 208 180 95
state_dispatch3_store_carry_ram225_bit2:     MB      off(00225h).2, C       ; 1C5B 0 208 180 C4253A
                MOVB    off(002e8h), #00ah     ; 1C5E 0 208 180 C4E8980A
                SJ      state_dispatch3_load_ram2cd             ; 1C62 0 208 180 CB57
state_dispatch3_load_ram2e6_2:     MOVB    off(002e6h), #003h     ; 1C64 0 208 180 C4E69803
state_dispatch3_load_ram2e7:     LB      A, off(002e7h)         ; 1C68 0 208 180 F4E7
                JNE     state_dispatch3_set_carry             ; 1C6A 0 208 180 CEE7
                SC                             ; 1C6C 0 208 180 85
                JBS     off(00230h).3, state_dispatch3_store_carry_ram225_bit2_2 ; 1C6D 0 208 180 EB3001
                RC                             ; 1C70 0 208 180 95
state_dispatch3_store_carry_ram225_bit2_2:     MB      off(00225h).2, C       ; 1C71 0 208 180 C4253A
                LB      A, off(002e8h)         ; 1C74 0 208 180 F4E8
                JEQ     state_dispatch3_if_ram234_bit7_set             ; 1C76 0 208 180 C905
                JBS     off(00235h).0, state_dispatch3_load_ram2cd ; 1C78 0 208 180 E83540
                SJ      state_dispatch4             ; 1C7B 0 208 180 CB16
state_dispatch3_if_ram234_bit7_set:     JBS     off(00234h).7, state_dispatch3_load_ram2e9_2 ; 1C7D 0 208 180 EF3434
                JBR     off(00220h).0, state_dispatch3_load_ram2e9 ; 1C80 0 208 180 D82003
                JBS     off(00224h).5, state_dispatch3_set_ram235_bit0 ; 1C83 0 208 180 ED2432
state_dispatch3_load_ram2e9:     LB      A, off(002e9h)         ; 1C86 0 208 180 F4E9
                JNE     state_dispatch3_load_ram2cd             ; 1C88 0 208 180 CE31
                JBS     off(00234h).2, state_dispatch3_clear_ram235_bit0 ; 1C8A 0 208 180 EA3403
                JBS     off(00235h).0, state_dispatch3_load_ram2cd ; 1C8D 0 208 180 E8352B
state_dispatch3_clear_ram235_bit0:     RB      off(00235h).0          ; 1C90 0 208 180 C43508
state_dispatch4:     JBS     off(00234h).3, state_dispatch4_if_ram235_bit1_set ; 1C93 0 208 180 EB3429
                JBS     off(00234h).6, state_dispatch4_if_ram235_bit1_set ; 1C96 0 208 180 EE3426
                CMPB    0d9h, #02eh            ; 1C99 0 208 180 C5D9C02E
                JGE     state_dispatch4_if_ram235_bit1_set             ; 1C9D 0 208 180 CD20
                CMPB    0d8h, #0a1h            ; 1C9F 0 208 180 C5D8C0A1
                JGE     state_dispatch4_if_ram235_bit1_set             ; 1CA3 0 208 180 CD1A
                JBS     off(00224h).0, state_dispatch4_if_ram235_bit1_set ; 1CA5 0 208 180 E82417
                LB      A, off(002cdh)         ; 1CA8 0 208 180 F4CD
                JEQ     state_dispatch4_if_ram235_bit1_set             ; 1CAA 0 208 180 C913
                RB      off(00235h).1          ; 1CAC 0 208 180 C43509
state_dispatch4_clear_ram225_bit3:     RB      off(00225h).3          ; 1CAF 0 208 180 C4250B
                SJ      state_dispatch4_load_dp             ; 1CB2 0 208 180 CB22
state_dispatch3_load_ram2e9_2:     MOVB    off(002e9h), #028h     ; 1CB4 0 208 180 C4E99828
state_dispatch3_set_ram235_bit0:     SB      off(00235h).0          ; 1CB8 0 208 180 C43518
state_dispatch3_load_ram2cd:     MOVB    off(002cdh), #028h     ; 1CBB 0 208 180 C4CD9828
state_dispatch4_if_ram235_bit1_set:     JBS     off(00235h).1, state_dispatch4_load_ram2ea ; 1CBF 0 208 180 E93507
                SB      off(00235h).1          ; 1CC2 0 208 180 C43519
                MOVB    off(002eah), #003h     ; 1CC5 0 208 180 C4EA9803
state_dispatch4_load_ram2ea:     LB      A, off(002eah)         ; 1CC9 0 208 180 F4EA
                JNE     state_dispatch4_clear_ram225_bit3             ; 1CCB 0 208 180 CEE2
                CMPB    off(00298h), #003h     ; 1CCD 0 208 180 C498C003
                JGT     state_dispatch4_clear_ram225_bit3             ; 1CD1 0 208 180 C8DC
state_dispatch4_set_ram225_bit3:     SB      off(00225h).3          ; 1CD3 0 208 180 C4251B
state_dispatch4_load_dp:     MOV     DP, #0a000h            ; 1CD6 0 208 180 6200A0
                LB      A, off(00225h)         ; 1CD9 0 208 180 F425
                XORB    A, #0ffh               ; 1CDB 0 208 180 F6FF
                STB     A, [DP]                ; 1CDD 0 208 180 D2
                MOV     DP, #00044h            ; 1CDE 0 208 180 624400
                MOV     X1, #00312h            ; 1CE1 0 208 180 601203
                CAL     learn_table2_check_sub_load_dp_ind             ; 1CE4 0 208 180 327D43
                MOV     OS0, #0ffffh           ; 1CE7 0 208 180 B54498FFFF
                VCAL    4                      ; 1CEC 0 208 180 14
                MOV     er1, 098h              ; 1CED 0 208 180 B59849
                MOV     er2, 09ah              ; 1CF0 0 208 180 B59A4A
                MB      C, 09eh.0              ; 1CF3 0 208 180 C59E28
                JGE     dtc_scan_init             ; 1CF6 0 208 180 CD07
                CLR     A                      ; 1CF8 1 208 180 F9
                ST      A, 098h                ; 1CF9 1 208 180 D598
                ST      A, 09ah                ; 1CFB 1 208 180 D59A
                ST      A, er1                 ; 1CFD 1 208 180 89
                ST      A, er2                 ; 1CFE 1 208 180 8A
dtc_scan_init:     MOVB    r7, #001h              ; 1CFF 1 208 180 9F01
                MOV     DP, #002d9h            ; 1D01 1 208 180 62D902
dtc_scan_loop:     SRL     er2                    ; 1D04 1 208 180 46E7
                ROR     er1                    ; 1D06 1 208 180 45C7
                JLT     dtc_scan_found_check             ; 1D08 1 208 180 CA18
                LB      A, r7                  ; 1D0A 0 208 180 7F
                SUBB    A, off(002bfh)         ; 1D0B 0 208 180 A7BF
                JNE     dtc_scan_f4_check             ; 1D0D 0 208 180 CE03
                STB     A, off(002bfh)         ; 1D0F 0 208 180 D4BF
                STB     A, [DP]                ; 1D11 0 208 180 D2
dtc_scan_f4_check:     LB      A, r7                  ; 1D12 0 208 180 7F
                SUBB    A, 0f1h                ; 1D13 0 208 180 C5F1A2
                JNE     dtc_scan_advance             ; 1D16 0 208 180 CE02
                STB     A, 0f1h                ; 1D18 0 208 180 D5F1
dtc_scan_advance:     INCB    r7                     ; 1D1A 0 208 180 AF
                CMPB    r7, #01ch              ; 1D1B 0 208 180 27C01C
                JLT     dtc_scan_loop             ; 1D1E 0 208 180 CAE4
                SJ      dtc_debounce_init             ; 1D20 0 208 180 CB16
dtc_scan_found_check:     LB      A, off(002bfh)         ; 1D22 0 208 180 F4BF
                JEQ     dtc_scan_new_code             ; 1D24 0 208 180 C908
                CMPB    A, r7                  ; 1D26 0 208 180 4F
                JNE     dtc_scan_advance             ; 1D27 0 208 180 CEF1
                LB      A, [DP]                ; 1D29 0 208 180 F2
                JNE     dtc_debounce_init             ; 1D2A 0 208 180 CE0C
                SJ      dtc_debounce2_check_set_ram233_bit5             ; 1D2C 0 208 180 CB67
dtc_scan_new_code:     CLR     A                      ; 1D2E 1 208 180 F9
                LB      A, r7                  ; 1D2F 0 208 180 7F
                STB     A, off(002bfh)         ; 1D30 0 208 180 D4BF
                LCB     A, dtc_scan_new_code_tbl[ACC]       ; 1D32 0 208 180 B506AB4E57
                STB     A, [DP]                ; 1D37 0 208 180 D2
dtc_debounce_init:     VCAL    4                      ; 1D38 0 208 180 14
                MOVB    r7, #021h              ; 1D39 0 208 180 9F21
                CLR     A                      ; 1D3B 1 208 180 F9
                XCHG    A, 09ch                ; 1D3C 1 208 180 B59C10
                JBS     off(0021bh).6, dtc_debounce_mask_apply ; 1D3F 1 208 180 EE1B03
                AND     A, #0f8ffh             ; 1D42 1 208 180 D6FFF8
dtc_debounce_mask_apply:     ST      A, er0                 ; 1D45 1 208 180 88
                MB      C, 09eh.0              ; 1D46 1 208 180 C59E28
                JGE     dtc_debounce_loop_start             ; 1D49 1 208 180 CD02
                CLR     er0                    ; 1D4B 1 208 180 4415
dtc_debounce_loop_start:     MOV     DP, #001a0h            ; 1D4D 1 208 180 62A001
dtc_debounce_loop:     SRL     er0                    ; 1D50 1 208 180 44E7
                JLT     dtc_debounce_loop_load_dp_ind             ; 1D52 1 208 180 CA14
                CLR     A                      ; 1D54 1 208 180 F9
                LB      A, r7                  ; 1D55 0 208 180 7F
                CMPB    A, 0f1h                ; 1D56 0 208 180 C5F1C2
                JNE     dtc_debounce_loop_inc_dp             ; 1D59 0 208 180 CE12
                LCB     A, dtc_scan_new_code_tbl[ACC]       ; 1D5B 0 208 180 B506AB4E57
                SUBB    A, [DP]                ; 1D60 0 208 180 C2A2
                JNE     dtc_debounce_loop_inc_dp             ; 1D62 0 208 180 CE09
                STB     A, 0f1h                ; 1D64 0 208 180 D5F1
                SJ      dtc_debounce_loop_inc_dp             ; 1D66 0 208 180 CB05
dtc_debounce_loop_load_dp_ind:     LB      A, [DP]                ; 1D68 0 208 180 F2
                JEQ     dtc_debounce2_check_set_ram233_bit5             ; 1D69 0 208 180 C92A
                DECB    [DP]                   ; 1D6B 0 208 180 C217
dtc_debounce_loop_inc_dp:     INC     DP                     ; 1D6D 0 208 180 72
                INCB    r7                     ; 1D6E 0 208 180 AF
                CMPB    r7, #02ch              ; 1D6F 0 208 180 27C02C
                JLT     dtc_debounce_loop             ; 1D72 0 208 180 CADC
                MOVB    r7, #030h              ; 1D74 0 208 180 9F30
                MOV     DP, #00172h            ; 1D76 0 208 180 627201
                SRL     er0                    ; 1D79 0 208 180 44E7
                SRL     er0                    ; 1D7B 0 208 180 44E7
                SRL     er0                    ; 1D7D 0 208 180 44E7
                SRL     er0                    ; 1D7F 0 208 180 44E7
                SRL     er0                    ; 1D81 0 208 180 44E7
                JLT     dtc_debounce2_check             ; 1D83 0 208 180 CA0D
                MOV     [DP], #00bb3h          ; 1D85 0 208 180 B298B30B
                LB      A, 0f1h                ; 1D89 0 208 180 F5F1
                SUBB    A, r7                  ; 1D8B 0 208 180 2F
                JNE     dtc_active_confirm_goto_6f00             ; 1D8C 0 208 180 CE76
                STB     A, 0f1h                ; 1D8E 0 208 180 D5F1
                SJ      dtc_active_confirm_goto_6f00             ; 1D90 0 208 180 CB72
dtc_debounce2_check:     L       A, [DP]                ; 1D92 1 208 180 E2
                JNE     dtc_active_confirm_goto_6f00             ; 1D93 1 208 180 CE6F
dtc_debounce2_check_set_ram233_bit5:     SB      off(00233h).5          ; 1D95 0 208 180 C4331D
                L       A, DP                  ; 1D98 1 208 180 42
                PUSHS   A                      ; 1D99 1 208 180 55
                L       A, er3                 ; 1D9A 1 208 180 37
                PUSHS   A                      ; 1D9B 1 208 180 55
                VCAL    4                      ; 1D9C 1 208 180 14
                POPS    A                      ; 1D9D 1 208 180 65
                ST      A, er3                 ; 1D9E 1 208 180 8B
                POPS    A                      ; 1D9F 1 208 180 65
                MOV     DP, A                  ; 1DA0 1 208 180 52
                JBR     off(00233h).5, dtc_active_confirm_goto_6f00 ; 1DA1 1 208 180 DD3360
                LB      A, #005h               ; 1DA4 0 208 180 7705
                STB     A, [DP]                ; 1DA6 0 208 180 D2
                LB      A, 0f1h                ; 1DA7 0 208 180 F5F1
                JNE     dtc_active_confirm             ; 1DA9 0 208 180 CE05
                LB      A, r7                  ; 1DAB 0 208 180 7F
                STB     A, 0f1h                ; 1DAC 0 208 180 D5F1
                SJ      dtc_active_confirm_goto_6f00             ; 1DAE 0 208 180 CB54
dtc_active_confirm:     SUBB    A, r7                  ; 1DB0 0 208 180 2F
                JNE     dtc_active_confirm_goto_6f00             ; 1DB1 0 208 180 CE51
                RB      PSWH.0                 ; 1DB3 0 208 180 A208
                STB     A, 0f1h                ; 1DB5 0 208 180 D5F1
                CLR     A                      ; 1DB7 1 208 180 F9
                LB      A, r7                  ; 1DB8 0 208 180 7F
                CMPB    A, #030h               ; 1DB9 0 208 180 C630
                JNE     dtc_active_confirm_rom_load_tbl_577f_acc             ; 1DBB 0 208 180 CE0D
                MOV     (00172h-00180h)[USP], #00bb3h ; 1DBD 0 208 180 B3F298B30B
                JBR     off(0021fh).0, dtc_active_confirm_rom_load_tbl_577f_acc ; 1DC2 0 208 180 D81F05
                SB      0a0h.0                 ; 1DC5 0 208 180 C5A018
                SJ      dtc_active_confirm_set_pswh_bit0             ; 1DC8 0 208 180 CB38
dtc_active_confirm_rom_load_tbl_577f_acc:     LCB     A, dtc_active_confirm_tbl[ACC]       ; 1DCA 0 208 180 B506AB7F57
                JEQ     dtc_active_confirm_set_pswh_bit0             ; 1DCF 0 208 180 C931
                STB     A, r6                  ; 1DD1 0 208 180 8E
                MOV     DP, #003e0h            ; 1DD2 0 208 180 62E003
                LB      A, ADCR2H              ; 1DD5 0 208 180 F56D
                STB     A, [DP]                ; 1DD7 0 208 180 D2
                INC     DP                     ; 1DD8 0 208 180 72
                LB      A, ADCR3H              ; 1DD9 0 208 180 F56F
                STB     A, [DP]                ; 1DDB 0 208 180 D2
                INC     DP                     ; 1DDC 0 208 180 72
                LB      A, ADCR4H              ; 1DDD 0 208 180 F571
                STB     A, [DP]                ; 1DDF 0 208 180 D2
                INC     DP                     ; 1DE0 0 208 180 72
                LB      A, ADCR5H              ; 1DE1 0 208 180 F573
                STB     A, [DP]                ; 1DE3 0 208 180 D2
                INC     DP                     ; 1DE4 0 208 180 72
                LB      A, ADCR6H              ; 1DE5 0 208 180 F575
                STB     A, [DP]                ; 1DE7 0 208 180 D2
                INC     DP                     ; 1DE8 0 208 180 72
                LB      A, ADCR7H              ; 1DE9 0 208 180 F577
                STB     A, [DP]                ; 1DEB 0 208 180 D2
                SB      off(00233h).0          ; 1DEC 0 208 180 C43318
                SB      off(00233h).1          ; 1DEF 0 208 180 C43319
                CAL     dtc_active_confirm_sub_clear_acc             ; 1DF2 0 208 180 326D45
                CAL     dtc_active_confirm_sub_load_dp             ; 1DF5 0 208 180 32174B
                CAL     cfgvariant_checksum_calc             ; 1DF8 0 208 180 32E84A
                STB     A, [DP]                ; 1DFB 0 208 180 D2
                RB      off(00233h).0          ; 1DFC 0 208 180 C43308
                RB      off(00233h).1          ; 1DFF 0 208 180 C43309
dtc_active_confirm_set_pswh_bit0:     SB      PSWH.0                 ; 1E02 0 208 180 A218
dtc_active_confirm_goto_6f00:     J       dtc_active_confirm_vcal_4             ; 1E04 1 208 180 03006F
dtc_active_confirm_load_x1:     MOV     X1, #00114h            ; 1E07 1 208 180 601401
                CLR     er0                    ; 1E0A 1 208 180 4415
calchecksum_loop:     DEC     DP                     ; 1E0C 1 208 180 82
                DEC     X1                     ; 1E0D 1 208 180 80
                LB      A, r0                  ; 1E0E 0 208 180 78
                ADDB    A, [DP]                ; 1E0F 0 208 180 C282
                STB     A, r0                  ; 1E11 0 208 180 88
                LB      A, r1                  ; 1E12 0 208 180 79
                XORB    A, [DP]                ; 1E13 0 208 180 C2F2
                STB     A, r1                  ; 1E15 0 208 180 89
                LB      A, 00000h[X1]          ; 1E16 0 208 180 F00000
                STB     A, r2                  ; 1E19 0 208 180 8A
                LB      A, [DP]                ; 1E1A 0 208 180 F2
                XORB    A, r2                  ; 1E1B 0 208 180 22F2
                ANDB    A, r2                  ; 1E1D 0 208 180 5A
                JNE     calchecksum_loop_load_ram0d4_4             ; 1E1E 0 208 180 CE22
                CMP     DP, #00330h            ; 1E20 0 208 180 92C03003
                JNE     calchecksum_loop             ; 1E24 0 208 180 CEE6
                LB      A, [DP]                ; 1E26 0 208 180 F2
                ANDB    A, #002h               ; 1E27 0 208 180 D602
                JNE     calchecksum_loop_load_ram0d4_4             ; 1E29 0 208 180 CE17
                INC     DP                     ; 1E2B 0 208 180 72
                LB      A, [DP]                ; 1E2C 0 208 180 F2
                ANDB    A, #004h               ; 1E2D 0 208 180 D604
                JNE     calchecksum_loop_load_ram0d4_4             ; 1E2F 0 208 180 CE11
                INC     DP                     ; 1E31 0 208 180 72
                LB      A, [DP]                ; 1E32 0 208 180 F2
                ANDB    A, #006h               ; 1E33 0 208 180 D606
                JNE     calchecksum_loop_load_ram0d4_4             ; 1E35 0 208 180 CE0B
                INC     DP                     ; 1E37 0 208 180 72
                LB      A, [DP]                ; 1E38 0 208 180 F2
                ANDB    A, #088h               ; 1E39 0 208 180 D688
                JNE     calchecksum_loop_load_ram0d4_4             ; 1E3B 0 208 180 CE05
                INC     DP                     ; 1E3D 0 208 180 72
                L       A, [DP]                ; 1E3E 1 208 180 E2
                CMP     A, er0                 ; 1E3F 1 208 180 48
                JEQ     calchecksum_loop_call_4afe             ; 1E40 1 208 180 C907
calchecksum_loop_load_ram0d4_4:     MOVB    0d4h, #04fh            ; 1E42 1 208 180 C5D4984F
                J       fault_retry_check_nop_acc             ; 1E46 1 208 180 035807
calchecksum_loop_call_4afe:     CAL     cfgvariant_checksum_loop_load_dp             ; 1E49 1 208 180 32FE4A
                CMP     A, [DP]                ; 1E4C 1 208 180 B2C2
                JNE     calchecksum_loop_load_ram0d4_4             ; 1E4E 1 208 180 CEF2
                L       A, off(00210h)         ; 1E50 1 208 180 E410
                AND     A, #08075h             ; 1E52 1 208 180 D67580
                JNE     calchecksum_loop_set_ram218_bit6             ; 1E55 1 208 180 CE06
                LB      A, off(00213h)         ; 1E57 0 208 180 F413
                ANDB    A, #014h               ; 1E59 0 208 180 D614
                JEQ     calchecksum_loop_load_ram210             ; 1E5B 0 208 180 C903
calchecksum_loop_set_ram218_bit6:     SB      off(00218h).6          ; 1E5D 0 208 180 C4181E
calchecksum_loop_load_ram210:     L       A, off(00210h)         ; 1E60 1 208 180 E410
                ORB     A, off(00212h)         ; 1E62 1 208 180 E712
                ADD     A, #0ffffh             ; 1E64 1 208 180 86FFFF
                MB      off(00215h).6, C       ; 1E67 1 208 180 C4153E
                L       A, off(00210h)         ; 1E6A 1 208 180 E410
                AND     A, #0fbfdh             ; 1E6C 1 208 180 D6FDFB
                JNE     calchecksum_loop_set_ram233_bit6             ; 1E6F 1 208 180 CE07
                L       A, off(00212h)         ; 1E71 1 208 180 E412
                AND     A, #014f1h             ; 1E73 1 208 180 D6F114
                JEQ     calchecksum_loop_vcal_4_3             ; 1E76 1 208 180 C903
calchecksum_loop_set_ram233_bit6:     SB      off(00233h).6          ; 1E78 1 208 180 C4331E
calchecksum_loop_vcal_4_3:     VCAL    4                      ; 1E7B 1 208 180 14
                JBS     off(00213h).2, calchecksum_loop_clear_carry ; 1E7C 1 208 180 EA1317
                JBS     off(00210h).5, calchecksum_loop_clear_carry ; 1E7F 1 208 180 ED1014
                MB      C, 098h.1              ; 1E82 1 208 180 C59829
                JLT     calchecksum_loop_clear_carry             ; 1E85 1 208 180 CA0F
                JBS     off(00216h).0, calchecksum_loop_clear_carry ; 1E87 1 208 180 E8160C
                CMPB    0d9h, #0c5h            ; 1E8A 1 208 180 C5D9C0C5
                JGE     calchecksum_loop_clear_carry             ; 1E8E 1 208 180 CD06
                CMPB    0dbh, #0a7h            ; 1E90 1 208 180 C5DBC0A7
                JLT     calchecksum_loop_store_carry_ram22a_bit0             ; 1E94 1 208 180 CA01
calchecksum_loop_clear_carry:     RC                             ; 1E96 1 208 180 95
calchecksum_loop_store_carry_ram22a_bit0:     MB      off(0022ah).0, C       ; 1E97 1 208 180 C42A38
                XORB    PSWH, #080h            ; 1E9A 1 208 180 A2F080
                JGE     calchecksum_loop_nop_acc_2             ; 1E9D 1 208 180 CD03
                MB      P2A.2, C               ; 1E9F 1 208 180 C5253A
calchecksum_loop_nop_acc_2:     NOP                            ; 1EA2 1 208 180 00
                NOP                            ; 1EA3 1 208 180 00
                NOP                            ; 1EA4 1 208 180 00
                NOP                            ; 1EA5 1 208 180 00
                SB      off(00233h).3          ; 1EA6 1 208 180 C4331B
                JNE     calchecksum_loop_goto_0c7e             ; 1EA9 1 208 180 CE27
                CAL     learn_table2_check_sub_load_imm             ; 1EAB 1 208 180 32B749
                MB      C, 09eh.0              ; 1EAE 1 208 180 C59E28
                JLT     calchecksum_loop_load_timer             ; 1EB1 1 208 180 CA09
                MOVB    0d7h, #010h            ; 1EB3 1 208 180 C5D79810
                DIV                            ; 1EB7 1 208 180 9037
                CAL     calchecksum_loop_sub_div_acc             ; 1EB9 1 208 180 32C06F
calchecksum_loop_load_timer:     L       A, TIMER               ; 1EBC 1 208 180 E556
                ST      A, 0d2h                ; 1EBE 1 208 180 D5D2
                AND     IRQ, #00600h           ; 1EC0 1 208 180 B518D00006
                CLRB    TRNSIT                   ; 1EC5 1 208 180 C52915
                MOV     OS1, #0f63bh           ; 1EC8 1 208 180 B546983BF6
                MOV     IE, #0141bh            ; 1ECD 1 208 180 B51A981B14
calchecksum_loop_goto_0c7e:     J       calchecksum_loop_nop_acc             ; 1ED2 1 208 180 037E0C
crank_cycle_er2_store_set_ram132_bit2:     SB      off(00132h).2          ; 1ED5 0 108 280 C4321A
                L       A, off(0011ah)         ; 1ED8 1 108 280 E41A
                ST      A, (0021ah-00280h)[USP] ; 1EDA 1 108 280 D39A
                J       crank_cycle_er2_store_load_imm             ; 1EDC 1 108 280 03F04D
                DW  00000h           ; 1EDF
crank_cycle_er2_store_load_lrb:     MOV     LRB, #00040h           ; 1EE1 1 200 280 574000
                MOVB    PSWL, #001h            ; 1EE4 1 200 280 A39801
                MOV     USP, #00180h           ; 1EE7 1 200 180 A1988001
                MOV     OS2, #0ffffh           ; 1EEB 1 200 180 B54898FFFF
                LB      A, 0abh                ; 1EF0 0 200 180 F5AB
                STB     A, 0e7h                ; 1EF2 0 200 180 D5E7
                MOV     er0, #04d00h           ; 1EF4 0 200 180 4498004D
                JBS     off(00210h).6, crank_cycle_er2_store_load_er0 ; 1EF8 0 200 180 EE100D
                MOV     er0, 0a6h              ; 1EFB 0 200 180 B5A648
                LB      A, #0fah               ; 1EFE 0 200 180 77FA
                CMPB    A, r1                  ; 1F00 0 200 180 49
                JLT     dtc07_tps_latch             ; 1F01 0 200 180 CA17
                CMPB    r1, #005h              ; 1F03 0 200 180 21C005
                JLT     dtc07_tps_latch             ; 1F06 0 200 180 CA12
crank_cycle_er2_store_load_er0:     L       A, er0                 ; 1F08 1 200 180 34
                SLL     A                      ; 1F09 1 200 180 53
                JLT     tps_delta_clamp1             ; 1F0A 1 200 180 CA05
                SLL     A                      ; 1F0C 1 200 180 53
                LB      A, ACCH                ; 1F0D 0 200 180 F507
                JGE     tps_delta_store1             ; 1F0F 0 200 180 CD02
tps_delta_clamp1:     LB      A, #0ffh               ; 1F11 0 200 180 77FF
tps_delta_store1:     STB     A, 0e8h                ; 1F13 0 200 180 D5E8
                L       A, er0                 ; 1F15 1 200 180 34
                XCHG    A, 0aah                ; 1F16 1 200 180 B5AA10
                RC                             ; 1F19 1 200 180 95
dtc07_tps_latch:     MB      098h.2, C              ; 1F1A 1 200 180 C5983A
                JLT     tps_delta_store1_load_er0             ; 1F1D 1 200 180 CA03
                JBR     off(00210h).6, tps_delta_check1 ; 1F1F 1 200 180 DE1001
tps_delta_store1_load_er0:     L       A, er0                 ; 1F22 1 200 180 34
tps_delta_check1:     SUB     A, er0                 ; 1F23 1 200 180 28
                MB      PSWL.4, C              ; 1F24 1 200 180 A33C
                JGE     tps_delta_clamp2             ; 1F26 1 200 180 CD01
                VCAL    7                      ; 1F28 1 200 180 17
tps_delta_clamp2:     SLL     A                      ; 1F29 1 200 180 53
                JLT     tps_delta_clamp2_max             ; 1F2A 1 200 180 CA05
                SLL     A                      ; 1F2C 1 200 180 53
                LB      A, ACCH                ; 1F2D 0 200 180 F507
                JGE     tps_delta_store2             ; 1F2F 0 200 180 CD02
tps_delta_clamp2_max:     LB      A, #0ffh               ; 1F31 0 200 180 77FF
tps_delta_store2:     STB     A, r0                  ; 1F33 0 200 180 88
                MB      C, PSWL.4              ; 1F34 0 200 180 A32C
                RB      off(00219h).0          ; 1F36 0 200 180 C41908
                MB      off(00219h).0, C       ; 1F39 0 200 180 C41938
                XCHGB   A, 0e9h                ; 1F3C 0 200 180 C5E910
                JEQ     tps_delta_store2_if_ge_goto_1f50             ; 1F3F 0 200 180 C903
                XORB    PSWH, #080h            ; 1F41 0 200 180 A2F080
tps_delta_store2_if_ge_goto_1f50:     JGE     tps_delta_store2_subb_acc             ; 1F44 0 200 180 CD0A
                ADDB    A, r0                  ; 1F46 0 200 180 08
                JGE     tps_delta_store2_set_ram219_bit1             ; 1F47 0 200 180 CD02
                LB      A, #0ffh               ; 1F49 0 200 180 77FF
tps_delta_store2_set_ram219_bit1:     SB      off(00219h).1          ; 1F4B 0 200 180 C41919
                SJ      tps_delta_store2_store_ram0f0             ; 1F4E 0 200 180 CB07
tps_delta_store2_subb_acc:     SUBB    A, r0                  ; 1F50 0 200 180 28
                MB      off(00219h).1, C       ; 1F51 0 200 180 C41939
                JGE     tps_delta_store2_store_ram0f0             ; 1F54 0 200 180 CD01
                VCAL    7                      ; 1F56 0 200 180 17
tps_delta_store2_store_ram0f0:     STB     A, 0f0h                ; 1F57 0 200 180 D5F0
                JBS     off(00210h).2, map_sign_flag_clear ; 1F59 0 200 180 EA1017
                L       A, 0a4h                ; 1F5C 1 200 180 E5A4
                SWAP                           ; 1F5E 1 200 180 83
                LB      A, ACC                 ; 1F5F 0 200 180 F506
                CMPB    A, #0a1h               ; 1F61 0 200 180 C6A1
                JGT     dtc03_map_latch             ; 1F63 0 200 180 C804
                CMPB    A, #00bh               ; 1F65 0 200 180 C60B
                JGE     map_neg_helper_call             ; 1F67 0 200 180 CD07
dtc03_map_latch:     SB      098h.0                 ; 1F69 0 200 180 C59818
                LB      A, off(00288h)         ; 1F6C 0 200 180 F488
                SJ      map_sign_gate2             ; 1F6E 0 200 180 CB09
map_neg_helper_call:     CAL     subtract24_clamp_byte             ; 1F70 0 200 180 327F44
map_sign_flag_clear:     RB      098h.0                 ; 1F73 0 200 180 C59808
                JBS     off(00210h).2, map_sign_gate3 ; 1F76 0 200 180 EA1003
map_sign_gate2:     JBR     off(00210h).4, map_sign_gate4 ; 1F79 0 200 180 DC1006
map_sign_gate3:     LB      A, 0abh                ; 1F7C 0 200 180 F5AB
                MOV     X1, #tbl_tps_5736          ; 1F7E 0 200 180 603657
                VCAL    2                      ; 1F81 0 200 180 12
map_sign_gate4:     STB     A, r0                  ; 1F82 0 200 180 88
                STB     A, (00178h-00180h)[USP] ; 1F83 0 200 180 D3F8
                XCHGB   A, off(00288h)         ; 1F85 0 200 180 C48810
                STB     A, r1                  ; 1F88 0 200 180 89
                XCHGB   A, 0e1h                ; 1F89 0 200 180 C5E110
                MOV     DP, #003a1h            ; 1F8C 0 200 180 62A103
                XCHGB   A, [DP]                ; 1F8F 0 200 180 C210
                INC     DP                     ; 1F91 0 200 180 72
                XCHGB   A, [DP]                ; 1F92 0 200 180 C210
                SUBB    A, r0                  ; 1F94 0 200 180 28
                MB      off(00219h).3, C       ; 1F95 0 200 180 C4193B
                JGE     map_sign_gate4_store_ram0e6             ; 1F98 0 200 180 CD01
                VCAL    7                      ; 1F9A 0 200 180 17
map_sign_gate4_store_ram0e6:     STB     A, 0e6h                ; 1F9B 0 200 180 D5E6
                LB      A, r1                  ; 1F9D 0 200 180 79
                SUBB    A, r0                  ; 1F9E 0 200 180 28
                MB      off(00219h).2, C       ; 1F9F 0 200 180 C4193A
                JGE     map_sign_gate4_store_ram0e5             ; 1FA2 0 200 180 CD01
                VCAL    7                      ; 1FA4 0 200 180 17
map_sign_gate4_store_ram0e5:     STB     A, 0e5h                ; 1FA5 0 200 180 D5E5
                MOV     DP, #00370h            ; 1FA7 0 200 180 627003
                CLR     A                      ; 1FAA 1 200 180 F9
                ST      A, er0                 ; 1FAB 1 200 180 88
                ST      A, er1                 ; 1FAC 1 200 180 89
map_sign_gate4_load_dp_ind:     L       A, [DP]                ; 1FAD 1 200 180 E2
                JEQ     map_sign_gate4_set_ram235_bit7             ; 1FAE 1 200 180 C91E
                ADD     er0, A                 ; 1FB0 1 200 180 4481
                ADCB    r2, #000h              ; 1FB2 1 200 180 229000
                INC     DP                     ; 1FB5 1 200 180 72
                INC     DP                     ; 1FB6 1 200 180 72
                CMP     DP, #0037ch            ; 1FB7 1 200 180 92C07C03
                JLT     map_sign_gate4_load_dp_ind             ; 1FBB 1 200 180 CAF0
                RB      off(00216h).0          ; 1FBD 1 200 180 C41608
                RB      off(00235h).7          ; 1FC0 1 200 180 C4350F
                SRLB    r2                     ; 1FC3 1 200 180 22E7
                ROR     er0                    ; 1FC5 1 200 180 44C7
                SRLB    r2                     ; 1FC7 1 200 180 22E7
                ROR     er0                    ; 1FC9 1 200 180 44C7
                LB      A, r2                  ; 1FCB 0 200 180 7A
                JEQ     map_sign_gate4_load_er0             ; 1FCC 0 200 180 C907
map_sign_gate4_set_ram235_bit7:     SB      off(00235h).7          ; 1FCE 0 200 180 C4351F
                L       A, #0ffffh             ; 1FD1 1 200 180 67FFFF
                ST      A, er0                 ; 1FD4 1 200 180 88
map_sign_gate4_load_er0:     L       A, er0                 ; 1FD5 1 200 180 34
                MOV     DP, #0037ch            ; 1FD6 1 200 180 627C03
                XCHG    A, 0aeh                ; 1FD9 1 200 180 B5AE10
                ST      A, er1                 ; 1FDC 1 200 180 89
                XCHG    A, [DP]                ; 1FDD 1 200 180 B210
                INC     DP                     ; 1FDF 1 200 180 72
                INC     DP                     ; 1FE0 1 200 180 72
                XCHG    A, [DP]                ; 1FE1 1 200 180 B210
                INC     DP                     ; 1FE3 1 200 180 72
                INC     DP                     ; 1FE4 1 200 180 72
                XCHG    A, [DP]                ; 1FE5 1 200 180 B210
                ST      A, er2                 ; 1FE7 1 200 180 8A
                L       A, er0                 ; 1FE8 1 200 180 34
                SUB     A, er2                 ; 1FE9 1 200 180 2A
                MB      off(00219h).5, C       ; 1FEA 1 200 180 C4193D
                JGE     map_sign_gate4_store_ram0b2             ; 1FED 1 200 180 CD01
                VCAL    7                      ; 1FEF 1 200 180 17
map_sign_gate4_store_ram0b2:     ST      A, 0b2h                ; 1FF0 1 200 180 D5B2
                L       A, er0                 ; 1FF2 1 200 180 34
                SUB     A, er1                 ; 1FF3 1 200 180 29
                MB      off(00219h).4, C       ; 1FF4 1 200 180 C4193C
                JGE     rpm_decel_limit_check             ; 1FF7 1 200 180 CD01
                VCAL    7                      ; 1FF9 1 200 180 17
rpm_decel_limit_check:     ST      A, 0b0h                ; 1FFA 1 200 180 D5B0
                L       A, 0aeh                ; 1FFC 1 200 180 E5AE
                CMP     A, #000eah             ; 1FFE 1 200 180 C6EA00
                JLT     rpm_decel_limit_check_cmp_acc_2             ; 2001 1 200 180 CA3B
                CMP     A, #00ea6h             ; 2003 1 200 180 C6A60E
                JGE     rpm_decel_limit_check_clear_acc             ; 2006 1 200 180 CD2E
                ST      A, er2                 ; 2008 1 200 180 8A
                MOV     X2, #00080h            ; 2009 1 200 180 618000
                CLR     er0                    ; 200C 1 200 180 4415
                MOV     X1, #0ea60h            ; 200E 1 200 180 6060EA
                MOV     DP, #rpm_decel_limit_check_tbl          ; 2011 1 200 180 62B757
rpm_decel_limit_check_cmp_acc:     CMPC    A, [DP]                ; 2014 1 200 180 92AC
                JLT     rpm_decel_limit_check_load_x1             ; 2016 1 200 180 CA0C
                SLL     X1                     ; 2018 1 200 180 90D7
                ROL     er0                    ; 201A 1 200 180 44B7
                INC     DP                     ; 201C 1 200 180 72
                INC     DP                     ; 201D 1 200 180 72
                SUB     X2, #00040h            ; 201E 1 200 180 91A04000
                JGE     rpm_decel_limit_check_cmp_acc             ; 2022 1 200 180 CDF0
rpm_decel_limit_check_load_x1:     L       A, X1                  ; 2024 1 200 180 40
                DIV                            ; 2025 1 200 180 9037
                SRL     A                      ; 2027 1 200 180 63
                ADD     A, X2                  ; 2028 1 200 180 9182
                ST      A, er3                 ; 202A 1 200 180 8B
                LB      A, r7                  ; 202B 0 200 180 7F
                JNE     rpm_decel_limit_check_load_imm_2             ; 202C 0 200 180 CE17
                LB      A, r6                  ; 202E 0 200 180 7E
                JEQ     rpm_decel_limit_check_load_imm             ; 202F 0 200 180 C909
                INCB    r6                     ; 2031 0 200 180 AE
                JEQ     rpm_decel_limit_check_load_imm_2             ; 2032 0 200 180 C911
                SJ      rpm_decel_limit_check_store_stk             ; 2034 0 200 180 CB11
rpm_decel_limit_check_clear_acc:     CLRB    A                      ; 2036 0 200 180 FA
                JBS     off(00216h).0, rpm_decel_limit_check_store_stk ; 2037 0 200 180 E8160D
rpm_decel_limit_check_load_imm:     LB      A, #001h               ; 203A 0 200 180 7701
                SJ      rpm_decel_limit_check_store_stk             ; 203C 0 200 180 CB09
rpm_decel_limit_check_cmp_acc_2:     CMP     A, #000bbh             ; 203E 1 200 180 C6BB00
                LB      A, #0ffh               ; 2041 0 200 180 77FF
                JLT     rpm_decel_limit_check_store_stk             ; 2043 0 200 180 CA02
rpm_decel_limit_check_load_imm_2:     LB      A, #0feh               ; 2045 0 200 180 77FE
rpm_decel_limit_check_store_stk:     STB     A, (00179h-00180h)[USP] ; 2047 0 200 180 D3F9
                XCHGB   A, off(00289h)         ; 2049 0 200 180 C48910
                STB     A, 0eah                ; 204C 0 200 180 D5EA
                LB      A, off(00289h)         ; 204E 0 200 180 F489
                CMPB    A, #000h               ; 2050 0 200 180 C600
                JGT     rpm_decel_limit_check_load_ram2a6             ; 2052 0 200 180 C82F
                JBS     off(00210h).6, rpm_decel_limit_check_load_ram2a6 ; 2054 0 200 180 EE102C
                JBS     off(00211h).4, rpm_decel_limit_check_load_ram2a6 ; 2057 0 200 180 EC1129
                JBS     off(0021dh).2, rpm_decel_limit_check_load_ram2a6 ; 205A 0 200 180 EA1D26
                MOV     X1, #050f0h            ; 205D 0 200 180 60F050
                VCAL    0                      ; 2060 0 200 180 10
                JBR     off(00231h).5, rpm_decel_limit_check_cmp_acc_3 ; 2061 0 200 180 DD3105
                SUBB    A, #002h               ; 2064 0 200 180 A602
                JGE     rpm_decel_limit_check_cmp_acc_3             ; 2066 0 200 180 CD01
                CLRB    A                      ; 2068 0 200 180 FA
rpm_decel_limit_check_cmp_acc_3:     CMPB    A, 0abh                ; 2069 0 200 180 C5ABC2
                MB      off(00231h).5, C       ; 206C 0 200 180 C4313D
                JGE     rpm_decel_limit_check_load_ram2a6             ; 206F 0 200 180 CD12
                LB      A, off(002a6h)         ; 2071 0 200 180 F4A6
                JEQ     rpm_decel_limit_check_clear_ram231_bit4             ; 2073 0 200 180 C915
                SUBB    A, #001h               ; 2075 0 200 180 A601
                STB     A, off(002a6h)         ; 2077 0 200 180 D4A6
                JEQ     rpm_decel_limit_check_clear_ram231_bit4             ; 2079 0 200 180 C90F
                SB      off(00231h).4          ; 207B 0 200 180 C4311C
                SB      off(00232h).2          ; 207E 0 200 180 C4321A
                SJ      rpm_decel_limit_check_load_ram0e0             ; 2081 0 200 180 CB0A
rpm_decel_limit_check_load_ram2a6:     MOVB    off(002a6h), #005h     ; 2083 0 200 180 C4A69805
                RB      off(00232h).2          ; 2087 0 200 180 C4320A
rpm_decel_limit_check_clear_ram231_bit4:     RB      off(00231h).4          ; 208A 0 200 180 C4310C
rpm_decel_limit_check_load_ram0e0:     LB      A, 0e0h                ; 208D 0 200 180 F5E0
                JBS     off(00210h).2, rpm_decel_limit_check_store_r0 ; 208F 0 200 180 EA1008
                JBS     off(00210h).4, rpm_decel_limit_check_store_r0 ; 2092 0 200 180 EC1005
                JBS     off(00231h).4, rpm_decel_limit_check_store_r0 ; 2095 0 200 180 EC3102
                LB      A, off(00288h)         ; 2098 0 200 180 F488
rpm_decel_limit_check_store_r0:     STB     A, r0                  ; 209A 0 200 180 88
                MB      C, PSWH.6              ; 209B 0 200 180 A22E
                MB      off(0022bh).3, C       ; 209D 0 200 180 C42B3B
                MOVB    r6, 0ech               ; 20A0 0 200 180 C5EC4E
                CAL     tps_interp_exact_match_sub_clear_acc             ; 20A3 0 200 180 32B746
                MB      C, PSWL.4              ; 20A6 0 200 180 A32C
                MB      off(0022bh).2, C       ; 20A8 0 200 180 C42B3A
                STB     A, 0c8h                ; 20AB 0 200 180 D5C8
                LB      A, r6                  ; 20AD 0 200 180 7E
                STB     A, 0ech                ; 20AE 0 200 180 D5EC
                MOVB    r1, #00fh              ; 20B0 0 200 180 990F
                JBS     off(00232h).4, rpm_decel_limit_check_clear_carry ; 20B2 0 200 180 EC320E
                LB      A, 0ech                ; 20B5 0 200 180 F5EC
                ADDB    A, #001h               ; 20B7 0 200 180 8601
                JBR     off(0022bh).3, rpm_decel_limit_check_if_ram22b_bit2_clr ; 20B9 0 200 180 DB2B01
                CLRB    A                      ; 20BC 0 200 180 FA
rpm_decel_limit_check_if_ram22b_bit2_clr:     JBR     off(0022bh).2, rpm_decel_limit_check_store_r1 ; 20BD 0 200 180 DA2B02
                LB      A, #00ah               ; 20C0 0 200 180 770A
rpm_decel_limit_check_store_r1:     STB     A, r1                  ; 20C2 0 200 180 89
rpm_decel_limit_check_clear_carry:     RC                             ; 20C3 0 200 180 95
                JBR     off(00221h).0, rpm_decel_limit_check_store_carry_ram223_bit3 ; 20C4 0 200 180 D82106
                JBS     off(00212h).5, rpm_decel_limit_check_store_carry_ram223_bit3 ; 20C7 0 200 180 ED1203
                MB      C, off(00227h).4       ; 20CA 0 200 180 C4272C
rpm_decel_limit_check_store_carry_ram223_bit3:     MB      off(00223h).3, C       ; 20CD 0 200 180 C4233B
                SC                             ; 20D0 0 200 180 85
                LB      A, (001b4h-00180h)[USP] ; 20D1 0 200 180 F334
                JNE     rpm_decel_limit_check_store_carry_ram223_bit5             ; 20D3 0 200 180 CE07
                J       rpm_decel_limit_check_if_ram230_bit1_set             ; 20D5 0 200 180 03E070
                DB  077h,0F4h,0C7h,0BAh ; 20D8
rpm_decel_limit_check_store_carry_ram223_bit5:     MB      off(00223h).5, C       ; 20DC 0 200 180 C4233D
                MB      C, off(0021ah).0       ; 20DF 0 200 180 C41A28
                MB      off(00223h).4, C       ; 20E2 0 200 180 C4233C
                LB      A, off(00223h)         ; 20E5 0 200 180 F423
                SWAPB                          ; 20E7 0 200 180 83
                STB     A, r5                  ; 20E8 0 200 180 8D
                ANDB    r5, #00fh              ; 20E9 0 200 180 25D00F
                ANDB    A, #0f0h               ; 20EC 0 200 180 D6F0
                ORB     A, r1                  ; 20EE 0 200 180 69
                STB     A, r4                  ; 20EF 0 200 180 8C
                L       A, er2                 ; 20F0 1 200 180 36
                MOV     er0, #00101h           ; 20F1 1 200 180 44980101
                MOVB    r2, #005h              ; 20F5 1 200 180 9A05
scale_div32_loop:     SRL     A                      ; 20F7 1 200 180 63
                ADCB    r0, #000h              ; 20F8 1 200 180 209000
                SRL     A                      ; 20FB 1 200 180 63
                ADCB    r1, #000h              ; 20FC 1 200 180 219000
                DECB    r2                     ; 20FF 1 200 180 BA
                JNE     scale_div32_loop             ; 2100 1 200 180 CEF5
                SRLB    r0                     ; 2102 1 200 180 20E7
                MB      r5.2, C                ; 2104 1 200 180 253A
                SRLB    r1                     ; 2106 1 200 180 21E7
                MB      r5.3, C                ; 2108 1 200 180 253B
                L       A, er2                 ; 210A 1 200 180 36
                ST      A, 0ceh                ; 210B 1 200 180 D5CE
                MOV     X1, #003d0h            ; 210D 1 200 180 60D003
                LB      A, 00000h[X1]          ; 2110 0 200 180 F00000
                JBS     off(00214h).7, scale_div32_loop_store_ram0da ; 2113 0 200 180 EF140A
                LB      A, ADCR1H              ; 2116 0 200 180 F56B
                STB     A, 00008h[X1]          ; 2118 0 200 180 D00800
                LB      A, ADCR0H              ; 211B 0 200 180 F569
                STB     A, 00000h[X1]          ; 211D 0 200 180 D00000
scale_div32_loop_store_ram0da:     STB     A, 0dah                ; 2120 0 200 180 D5DA
                MOVB    r0, 0bbh               ; 2122 0 200 180 C5BB48
                CAL     scale_div32_loop_sub_clear_pswh_bit0             ; 2125 0 200 180 321345
                SC                             ; 2128 0 200 180 85
                JBR     off(0022ah).0, scale_div32_loop_store_carry_p2a_bit2 ; 2129 0 200 180 D82A03
                MB      C, off(00238h).3       ; 212C 0 200 180 C4382B
scale_div32_loop_store_carry_p2a_bit2:     MB      P2A.2, C               ; 212F 0 200 180 C5253A
                LB      A, ADCR5H              ; 2132 0 200 180 F573
                STB     A, 0deh                ; 2134 0 200 180 D5DE
                LB      A, #0a0h               ; 2136 0 200 180 77A0
                JBS     off(00210h).2, tps_custom_clamp_store ; 2138 0 200 180 EA100D
                JBS     off(00210h).4, tps_custom_clamp_store ; 213B 0 200 180 EC100A
                JBS     off(00211h).4, tps_custom_clamp_store ; 213E 0 200 180 EC1107
                LB      A, 0e0h                ; 2141 0 200 180 F5E0
                SUBB    A, off(00288h)         ; 2143 0 200 180 A788
                JGE     tps_custom_clamp_store             ; 2145 0 200 180 CD01
                CLRB    A                      ; 2147 0 200 180 FA
tps_custom_clamp_store:     STB     A, 0e2h                ; 2148 0 200 180 D5E2
                MOVB    r0, off(00295h)        ; 214A 0 200 180 C49548
                LB      A, #00ah               ; 214D 0 200 180 770A
                ADDB    A, r0                  ; 214F 0 200 180 08
                STB     A, r1                  ; 2150 0 200 180 89
                JBR     off(00216h).4, tps_custom_clamp_store_cmp_acc ; 2151 0 200 180 DC1601
                LB      A, r0                  ; 2154 0 200 180 78
tps_custom_clamp_store_cmp_acc:     CMPB    A, off(00289h)         ; 2155 0 200 180 C789
                MB      off(00216h).4, C       ; 2157 0 200 180 C4163C
                MOV     DP, #0032fh            ; 215A 0 200 180 622F03
                MOVB    r4, [DP]               ; 215D 0 200 180 C24C
                LB      A, #003h               ; 215F 0 200 180 7703
                STB     A, r2                  ; 2161 0 200 180 8A
                MOVB    r3, #004h              ; 2162 0 200 180 9B04
                MB      C, off(00217h).2       ; 2164 0 200 180 C4172A
                MB      off(00217h).3, C       ; 2167 0 200 180 C4173B
                JLT     tps_window_calc2             ; 216A 0 200 180 CA01
                LB      A, r3                  ; 216C 0 200 180 7B
tps_window_calc2:     ADDB    A, r4                  ; 216D 0 200 180 0C
                CMPB    A, 0e8h                ; 216E 0 200 180 C5E8C2
                MB      off(00217h).2, C       ; 2171 0 200 180 C4173A
                LB      A, #004h               ; 2174 0 200 180 7704
                JBS     off(00217h).4, tps_window_calc3 ; 2176 0 200 180 EC1702
                LB      A, #005h               ; 2179 0 200 180 7705
tps_window_calc3:     ADDB    A, r4                  ; 217B 0 200 180 0C
                CMPB    A, 0e8h                ; 217C 0 200 180 C5E8C2
                MB      off(00217h).4, C       ; 217F 0 200 180 C4173C
                LB      A, r2                  ; 2182 0 200 180 7A
                MB      C, off(00217h).0       ; 2183 0 200 180 C41728
                MB      off(00217h).1, C       ; 2186 0 200 180 C41739
                JGE     tps_window_calc4             ; 2189 0 200 180 CD03
                MOVB    r0, r1                 ; 218B 0 200 180 2148
                LB      A, r3                  ; 218D 0 200 180 7B
tps_window_calc4:     ADDB    A, r4                  ; 218E 0 200 180 0C
                CMPB    0e8h, A                ; 218F 0 200 180 C5E8C1
                JGE     tps_window_store2             ; 2192 0 200 180 CD03
                LB      A, off(00289h)         ; 2194 0 200 180 F489
                CMPB    A, r0                  ; 2196 0 200 180 48
tps_window_store2:     MB      off(00217h).0, C       ; 2197 0 200 180 C41738
                MOVB    r0, 0e5h               ; 219A 0 200 180 C5E548
                MOVB    r1, off(00288h)        ; 219D 0 200 180 C48849
                JBS     off(0021ah).6, tps_interp_exact_match ; 21A0 0 200 180 EE1A2F
                JBS     off(00224h).2, tps_interp_exact_match ; 21A3 0 200 180 EA242C
                JBS     off(00210h).2, tps_interp_exact_match ; 21A6 0 200 180 EA1029
                JBS     off(00210h).4, tps_interp_exact_match ; 21A9 0 200 180 EC1026
                MOVB    r4, #0ffh              ; 21AC 0 200 180 9CFF
                LB      A, 0e1h                ; 21AE 0 200 180 F5E1
                MOV     DP, #051ach            ; 21B0 0 200 180 62AC51
                MOV     X1, #051b3h            ; 21B3 0 200 180 60B351
                JBS     off(00217h).0, tps_table_lookup ; 21B6 0 200 180 E81714
                INC     DP                     ; 21B9 0 200 180 72
                INC     X1                     ; 21BA 0 200 180 70
                INC     X1                     ; 21BB 0 200 180 70
                CMPB    A, #060h               ; 21BC 0 200 180 C660
                JGE     tps_table_offset_check             ; 21BE 0 200 180 CD08
                INC     DP                     ; 21C0 0 200 180 72
                INC     DP                     ; 21C1 0 200 180 72
                CMPB    A, #040h               ; 21C2 0 200 180 C640
                JGE     tps_table_offset_check             ; 21C4 0 200 180 CD02
                INC     DP                     ; 21C6 0 200 180 72
                INC     DP                     ; 21C7 0 200 180 72
tps_table_offset_check:     JBS     off(00219h).2, tps_table_lookup ; 21C8 0 200 180 EA1902
                INC     X1                     ; 21CB 0 200 180 70
                INC     X1                     ; 21CC 0 200 180 70
tps_table_lookup:     LC      A, [X1]                ; 21CD 0 200 180 90A8
                CMPB    A, r0                  ; 21CF 0 200 180 48
                JLT     tps_interp_clamp_check             ; 21D0 0 200 180 CA03
tps_interp_exact_match:     LB      A, r1                  ; 21D2 0 200 180 79
                SJ      tps_interp_exact_match_store_ram0e3             ; 21D3 0 200 180 CB32
tps_interp_clamp_check:     LB      A, ACCH                ; 21D5 0 200 180 F507
                CMPB    A, r0                  ; 21D7 0 200 180 48
                JGE     tps_interp_clamp_check_clear_acc             ; 21D8 0 200 180 CD01 ; [HTS120] c8)
                STB     A, r0                  ; 21DA 0 200 180 88
tps_interp_clamp_check_clear_acc:     CLR     A                      ; 21DB 1 200 180 F9
                LC      A, [DP]                ; 21DC 1 200 180 92A8
                JBS     off(00217h).0, tps_interp_clamp_check_mulb_acc ; 21DE 1 200 180 E81704
                JBS     off(00219h).2, tps_interp_clamp_check_mulb_acc ; 21E1 1 200 180 EA1901
                SWAP                           ; 21E4 1 200 180 83
tps_interp_clamp_check_mulb_acc:     MULB                           ; 21E5 1 200 180 A234
                SRL     A                      ; 21E7 1 200 180 63
                SRL     A                      ; 21E8 1 200 180 63
                SRL     A                      ; 21E9 1 200 180 63
                SRL     A                      ; 21EA 1 200 180 63
                ST      A, er1                 ; 21EB 1 200 180 89
                LB      A, r3                  ; 21EC 0 200 180 7B
                JNE     tps_interp_clamp_check_clear_acc_2             ; 21ED 0 200 180 CE13
                LB      A, r2                  ; 21EF 0 200 180 7A
                JBS     off(00219h).2, tps_interp_clamp_check_addb_acc ; 21F0 0 200 180 EA1901
                VCAL    7                      ; 21F3 0 200 180 17
tps_interp_clamp_check_addb_acc:     ADDB    A, r1                  ; 21F4 0 200 180 09
                JBS     off(00219h).2, tps_interp_clamp_check_if_lt_goto_2202 ; 21F5 0 200 180 EA1903
                XORB    PSWH, #080h            ; 21F8 0 200 180 A2F080
tps_interp_clamp_check_if_lt_goto_2202:     JLT     tps_interp_clamp_check_clear_acc_2             ; 21FB 0 200 180 CA05
                CMPB    A, r4                  ; 21FD 0 200 180 4C
                JLE     tps_interp_exact_match_store_ram0e3             ; 21FE 0 200 180 CF07
                SJ      tps_interp_clamp_check_load_r4             ; 2200 0 200 180 CB04
tps_interp_clamp_check_clear_acc_2:     CLRB    A                      ; 2202 0 200 180 FA
                JBR     off(00219h).2, tps_interp_exact_match_store_ram0e3 ; 2203 0 200 180 DA1901
tps_interp_clamp_check_load_r4:     LB      A, r4                  ; 2206 0 200 180 7C
;  [flow] map-index prep (top of the main fuel/ign task). Interpolates the 10-entry MAP axis
;    tbl_map_axis_mbar10 (@6050: 00,30,50,70,90,B0,D0,E0,F0,FF raw-ADC mBar scale) against 0A4h
;    -> column index 0EDh + column scalar 0C6h (fraction bits latched into 022Bh).
;    2215: RPM word 0AEh minus 0286h calibration with hysteresis -> 0B4h (open-loop-ish flag word).
tps_interp_exact_match_store_ram0e3:     STB     A, 0e3h                ; 2207 0 200 180 D5E3
                STB     A, r0                  ; 2209 0 200 180 88
                MOVB    r6, 0edh               ; 220A 0 200 180 C5ED4E
                CAL     tps_interp_exact_match_sub_clear_acc             ; 220D 0 200 180 32B746
                STB     A, 0c6h                ; 2210 0 200 180 D5C6
                LB      A, r6                  ; 2212 0 200 180 7E
                STB     A, 0edh                ; 2213 0 200 180 D5ED
                L       A, 0aeh                ; 2215 1 200 180 E5AE
                SUB     A, off(00286h)         ; 2217 1 200 180 A786
                MB      off(00216h).7, C       ; 2219 1 200 180 C4163F
                JGE     tps_interp_exact_match_store_ram0b4             ; 221C 1 200 180 CD01
                VCAL    7                      ; 221E 1 200 180 17
tps_interp_exact_match_store_ram0b4:     ST      A, 0b4h                ; 221F 1 200 180 D5B4
                LB      A, #08dh               ; 2221 0 200 180 778D
                JBS     off(00234h).0, tps_interp_exact_match_cmp_acc ; 2223 0 200 180 E83402
                LB      A, #093h               ; 2226 0 200 180 7793
tps_interp_exact_match_cmp_acc:     CMPB    A, off(00289h)         ; 2228 0 200 180 C789
                MB      off(00234h).0, C       ; 222A 0 200 180 C43438
;  [flow] RPM-row scalars per cam profile: interpolate tbl_rpm_scalar_lo40 (@6000, 40 x 16-bit
;    descending words) with row index 0EEh -> scalar 0CAh; tbl_rpm_scalar_hi40 (@6028) with 0EFh
;    -> 0CCh. Fraction bits go to 022Bh.1/.0 (lo) and 022Bh.5/.4 (hi). 0289h (8-bit RPM) is compared
;    with 8Dh/93h to hold the scalar when RPM sits in the VTEC cross-over band. These scalars are
;    the second lookup axis (X1) of the maps below, i.e. the p13info 'low/high cam rev scalar' 6000/6028
                MOV     DP, #tbl_rpm_scalar_lo40          ; 222D 0 200 180 620060
                MOVB    r6, 0eeh               ; 2230 0 200 180 C5EE4E
                CAL     tps_interp_exact_match_sub_rom_load_00026h_dp             ; 2233 0 200 180 327146
                MB      C, PSWL.4              ; 2236 0 200 180 A32C
                MB      off(0022bh).1, C       ; 2238 0 200 180 C42B39
                MB      C, PSWL.5              ; 223B 0 200 180 A32D
                MB      off(0022bh).0, C       ; 223D 0 200 180 C42B38
                STB     A, 0cah                ; 2240 0 200 180 D5CA
                LB      A, r6                  ; 2242 0 200 180 7E
                STB     A, 0eeh                ; 2243 0 200 180 D5EE
                MOV     DP, #tbl_rpm_scalar_hi40          ; 2245 0 200 180 622860
                MOVB    r6, 0efh               ; 2248 0 200 180 C5EF4E
                CAL     tps_interp_exact_match_sub_rom_load_00026h_dp             ; 224B 0 200 180 327146
                MB      C, PSWL.4              ; 224E 0 200 180 A32C
                MB      off(0022bh).5, C       ; 2250 0 200 180 C42B3D
                MB      C, PSWL.5              ; 2253 0 200 180 A32D
                MB      off(0022bh).4, C       ; 2255 0 200 180 C42B3C
                STB     A, 0cch                ; 2258 0 200 180 D5CC
                LB      A, r6                  ; 225A 0 200 180 7E
                STB     A, 0efh                ; 225B 0 200 180 D5EF
                MB      C, off(00229h).6       ; 225D 0 200 180 C4292E
                MB      off(00229h).7, C       ; 2260 0 200 180 C4293F
                LB      A, #002h               ; 2263 0 200 180 7702
                JGE     tps_interp_exact_match_cmp_acc_2             ; 2265 0 200 180 CD02
                SUBB    A, #001h               ; 2267 0 200 180 A601
tps_interp_exact_match_cmp_acc_2:     CMPB    A, off(00291h)         ; 2269 0 200 180 C791
                MB      off(00229h).6, C       ; 226B 0 200 180 C4293E
                CLR     er1                    ; 226E 0 200 180 4515
                JBS     off(0021dh).2, tps_interp_exact_match_clear_ram218_bit4 ; 2270 0 200 180 EA1D3C
                JBS     off(00211h).3, tps_interp_exact_match_clear_ram218_bit4 ; 2273 0 200 180 EB1139
                JBR     off(0021bh).4, tps_interp_exact_match_load_ram28d ; 2276 0 200 180 DC1B06
                MOVB    off(0028dh), #050h     ; 2279 0 200 180 C48D9850
                SJ      tps_interp_exact_match_load_er1             ; 227D 0 200 180 CB07
tps_interp_exact_match_load_ram28d:     LB      A, off(0028dh)         ; 227F 0 200 180 F48D
                JEQ     tps_interp_exact_match_clear_ram218_bit4             ; 2281 0 200 180 C92C
                DECB    off(0028dh)            ; 2283 0 200 180 C48D17
tps_interp_exact_match_load_er1:     MOV     er1, off(0028eh)       ; 2286 0 200 180 B48E49
                LB      A, off(00288h)         ; 2289 0 200 180 F488
                JBR     off(00229h).6, tps_interp_exact_match_if_ram229_bit7_clr ; 228B 0 200 180 DE2913
                JBS     off(00229h).7, tps_interp_exact_match_load_r2 ; 228E 0 200 180 EF2905
                MOV     X1, #05372h            ; 2291 0 200 180 607253
                VCAL    2                      ; 2294 0 200 180 12
                STB     A, r2                  ; 2295 0 200 180 8A
tps_interp_exact_match_load_r2:     LB      A, r2                  ; 2296 0 200 180 7A
                JEQ     tps_interp_exact_match_set_ram218_bit4             ; 2297 0 200 180 C903
                DECB    r2                     ; 2299 0 200 180 BA
                SJ      tps_interp_exact_match_clear_ram218_bit4             ; 229A 0 200 180 CB13
tps_interp_exact_match_set_ram218_bit4:     SB      off(00218h).4          ; 229C 0 200 180 C4181C
                SJ      tps_interp_exact_match_load_ram28e             ; 229F 0 200 180 CB11
tps_interp_exact_match_if_ram229_bit7_clr:     JBR     off(00229h).7, tps_interp_exact_match_load_r3 ; 22A1 0 200 180 DF2905
                MOV     X1, #05376h            ; 22A4 0 200 180 607653
                VCAL    2                      ; 22A7 0 200 180 12
                STB     A, r3                  ; 22A8 0 200 180 8B
tps_interp_exact_match_load_r3:     LB      A, r3                  ; 22A9 0 200 180 7B
                JEQ     tps_interp_exact_match_clear_ram218_bit4             ; 22AA 0 200 180 C903
                DECB    r3                     ; 22AC 0 200 180 BB
                SJ      tps_interp_exact_match_load_r2             ; 22AD 0 200 180 CBE7
tps_interp_exact_match_clear_ram218_bit4:     RB      off(00218h).4          ; 22AF 0 200 180 C4180C
tps_interp_exact_match_load_ram28e:     MOV     off(0028eh), er1       ; 22B2 0 200 180 457C8E
                MB      C, 0a0h.7              ; 22B5 0 200 180 C5A02F
                JLT     tps_interp_exact_match_load_r0             ; 22B8 0 200 180 CA06
                J       tps_interp_exact_match_load_ie             ; 22BA 0 200 180 03004E
                DB  000h,000h,000h ; 22BD
;  [flow] ignition base advance lookup: profile chosen by VTEC/high-cam flag 021Dh.1
;    (p13info '021D.1 VTEC Active' -- verified: it selects lo-cam vs hi-cam in every map here).
;    lo-cam:  tbl_ign_lo_cam (@63F8, 10x20) ; rows 4..0Dh can switch to alt tables
;             tbl_ign_lo_cam_alt1 (@64C0) / tbl_ign_lo_cam_alt2 (@652E, when 0220h.0 clear)
;    hi-cam:  tbl_ign_hi_cam (@659C) / tbl_ign_hi_cam_alt1 (@6664) / tbl_ign_hi_cam_alt2 (@66D2).
;    Index: A = row 0EEh(lo)/0EFh(hi), X1 = scalar 0CAh/0CCh (from 6000/6028 above) via CAL 4523.
;    tbl_aux_63f2 supplies the row-independent advance used at low RPM (VTEC off branch, 22CD).
;    NOTE p13info lists the 2nd alt lo-cam table at 642E -- the code actually uses 652E.
tps_interp_exact_match_load_r0:     MOVB    r0, off(0022bh)        ; 22C0 0 200 180 C42B48
                LB      A, #03ch               ; 22C3 0 200 180 773C
                JBS     off(0021dh).1, tps_interp_exact_match_andb_acc ; 22C5 0 200 180 E91D02
                LB      A, #00fh               ; 22C8 0 200 180 770F
tps_interp_exact_match_andb_acc:     ANDB    A, r0                  ; 22CA 0 200 180 58
                JEQ     tps_interp_exact_match_if_ram21d_bit1_set             ; 22CB 0 200 180 C92F
                MOV     DP, #tbl_aux_63f2          ; 22CD 0 200 180 62F263
                MOVB    r0, #004h              ; 22D0 0 200 180 9804
                JBR     off(0021dh).1, tps_interp_exact_match_srlb_acc ; 22D2 0 200 180 D91D01
                SWAPB                          ; 22D5 0 200 180 83
tps_interp_exact_match_srlb_acc:     SRLB    A                      ; 22D6 0 200 180 63
                JLT     tps_interp_exact_match_clear_acc             ; 22D7 0 200 180 CA1A
                CLRB    r0                     ; 22D9 0 200 180 2015
                CMPB    off(00288h), #080h     ; 22DB 0 200 180 C488C080
                JLT     tps_interp_exact_match_srlb_acc_2             ; 22DF 0 200 180 CA01
                INCB    r0                     ; 22E1 0 200 180 A8
tps_interp_exact_match_srlb_acc_2:     SRLB    A                      ; 22E2 0 200 180 63
                JLT     tps_interp_exact_match_clear_acc             ; 22E3 0 200 180 CA0E
                MOVB    r0, #005h              ; 22E5 0 200 180 9805
                JBS     off(0022bh).2, tps_interp_exact_match_clear_acc ; 22E7 0 200 180 EA2B09
                MOVB    r0, #002h              ; 22EA 0 200 180 9802
                CMPB    off(00289h), #080h     ; 22EC 0 200 180 C489C080
                JLT     tps_interp_exact_match_clear_acc             ; 22F0 0 200 180 CA01
                INCB    r0                     ; 22F2 0 200 180 A8
tps_interp_exact_match_clear_acc:     CLR     A                      ; 22F3 1 200 180 F9
                LB      A, r0                  ; 22F4 0 200 180 78
                ADD     DP, A                  ; 22F5 0 200 180 9281
                LCB     A, [DP]                ; 22F7 0 200 180 92AA
                J       tps_interp_exact_match_store_r0             ; 22F9 0 200 180 034C23
tps_interp_exact_match_if_ram21d_bit1_set:     JBS     off(0021dh).1, tps_interp_exact_match_load_dp ; 22FC 0 200 180 E91D23
                MOV     DP, #tbl_ign_lo_cam          ; 22FF 0 200 180 62F863
                MOV     X1, 0cah               ; 2302 0 200 180 B5CA78
                LB      A, 0eeh                ; 2305 0 200 180 F5EE
                JBS     off(00211h).3, tps_interp_exact_match_cmp_acc_3 ; 2307 0 200 180 EB1103
                JBR     off(00218h).4, tps_interp_exact_match_load_r1 ; 230A 0 200 180 DC1836
tps_interp_exact_match_cmp_acc_3:     CMPB    A, #00eh               ; 230D 0 200 180 C60E
                JGE     tps_interp_exact_match_load_r1             ; 230F 0 200 180 CD32
                CMPB    A, #004h               ; 2311 0 200 180 C604
                JLT     tps_interp_exact_match_load_r1             ; 2313 0 200 180 CA2E
                SUBB    A, #004h               ; 2315 0 200 180 A604
                MOV     DP, #tbl_ign_lo_cam_alt1          ; 2317 0 200 180 62C064
                JBS     off(00220h).0, tps_interp_exact_match_load_r1 ; 231A 0 200 180 E82026
                MOV     DP, #tbl_ign_lo_cam_alt2          ; 231D 0 200 180 622E65
                SJ      tps_interp_exact_match_load_r1             ; 2320 0 200 180 CB21
tps_interp_exact_match_load_dp:     MOV     DP, #tbl_ign_hi_cam          ; 2322 0 200 180 629C65
                MOV     X1, 0cch               ; 2325 0 200 180 B5CC78
                LB      A, 0efh                ; 2328 0 200 180 F5EF
                JBS     off(00211h).3, tps_interp_exact_match_cmp_acc_4 ; 232A 0 200 180 EB1103
                JBR     off(00218h).4, tps_interp_exact_match_load_r1 ; 232D 0 200 180 DC1813
tps_interp_exact_match_cmp_acc_4:     CMPB    A, #00eh               ; 2330 0 200 180 C60E
                JGE     tps_interp_exact_match_load_r1             ; 2332 0 200 180 CD0F
                CMPB    A, #004h               ; 2334 0 200 180 C604
                JLT     tps_interp_exact_match_load_r1             ; 2336 0 200 180 CA0B
                SUBB    A, #004h               ; 2338 0 200 180 A604
                MOV     DP, #tbl_ign_hi_cam_alt1          ; 233A 0 200 180 626466
                JBS     off(00220h).0, tps_interp_exact_match_load_r1 ; 233D 0 200 180 E82003
                MOV     DP, #tbl_ign_hi_cam_alt2          ; 2340 0 200 180 62D266
tps_interp_exact_match_load_r1:     MOVB    r1, 0ech               ; 2343 0 200 180 C5EC49
                MOV     X2, 0c8h               ; 2346 0 200 180 B5C879
                CAL     tipin_gate_common_sub_load_r0             ; 2349 0 200 180 324545
tps_interp_exact_match_store_r0:     STB     A, r0                  ; 234C 0 200 180 88
                LB      A, off(002bah)         ; 234D 0 200 180 F4BA
                JEQ     tps_interp_exact_match_if_ram231_bit4_set             ; 234F 0 200 180 C905
                MULB                           ; 2351 0 200 180 A234
                MOVB    r0, ACCH               ; 2353 0 200 180 C50748
tps_interp_exact_match_if_ram231_bit4_set:     JBS     off(00231h).4, tps_interp_exact_match_load_ram2c9 ; 2356 0 200 180 EC3116
                JBR     off(00232h).2, tps_interp_exact_match_load_ram2aa ; 2359 0 200 180 DA3216
                LB      A, #002h               ; 235C 0 200 180 7702
                ADDB    A, off(002c9h)         ; 235E 0 200 180 87C9
                JGE     tps_interp_exact_match_store_ram2c9             ; 2360 0 200 180 CD02
                LB      A, #0ffh               ; 2362 0 200 180 77FF
tps_interp_exact_match_store_ram2c9:     STB     A, off(002c9h)         ; 2364 0 200 180 D4C9
                CMPB    A, r0                  ; 2366 0 200 180 48
                MB      off(00232h).2, C       ; 2367 0 200 180 C4323A
                JGE     tps_interp_exact_match_load_ram2aa             ; 236A 0 200 180 CD06
                STB     A, r0                  ; 236C 0 200 180 88
                SJ      tps_interp_exact_match_load_ram2aa             ; 236D 0 200 180 CB03
tps_interp_exact_match_load_ram2c9:     MOVB    off(002c9h), r0        ; 236F 0 200 180 207CC9
tps_interp_exact_match_load_ram2aa:     MOVB    off(002aah), r0        ; 2372 0 200 180 207CAA
                CLRB    A                      ; 2375 0 200 180 FA
                JBR     off(00217h).0, idleign_result_store ; 2376 0 200 180 D81726
                JBS     off(0022ch).6, idleign_result_store ; 2379 0 200 180 EE2C23
                CMPB    0d9h, #044h            ; 237C 0 200 180 C5D9C044
                JGE     idleign_result_store             ; 2380 0 200 180 CD1D
                JBS     off(00224h).2, idleign_result_store ; 2382 0 200 180 EA241A
                L       A, 0b4h                ; 2385 1 200 180 E5B4
                MOV     X1, #050c8h            ; 2387 1 200 180 60C850
                JBS     off(00216h).7, idleign_table_lookup ; 238A 1 200 180 EF1603
                MOV     X1, #050dch            ; 238D 1 200 180 60DC50
idleign_table_lookup:     CAL     idleign_table_lookup_sub_load_acc             ; 2390 1 200 180 324644
                LB      A, ACC                 ; 2393 0 200 180 F506
                MOVB    r0, #015h              ; 2395 0 200 180 9815
                CMPB    A, r0                  ; 2397 0 200 180 48
                JLT     idleign_vcal6_check             ; 2398 0 200 180 CA01
                LB      A, r0                  ; 239A 0 200 180 78
idleign_vcal6_check:     JBR     off(00216h).7, idleign_result_store ; 239B 0 200 180 DF1601
                VCAL    7                      ; 239E 0 200 180 17
idleign_result_store:     STB     A, off(002adh)         ; 239F 0 200 180 D4AD
                LB      A, #01dh               ; 23A1 0 200 180 771D
                JBS     off(00230h).7, idleign_result_store_cmp_ram0af ; 23A3 0 200 180 EF3002
                LB      A, #00ch               ; 23A6 0 200 180 770C
idleign_result_store_cmp_ram0af:     CMPB    0afh, A                ; 23A8 0 200 180 C5AFC1
                MB      off(00230h).7, C       ; 23AB 0 200 180 C4303F
                LB      A, #03ah               ; 23AE 0 200 180 773A
                JBS     off(00231h).0, idleign_result_store_cmp_acc ; 23B0 0 200 180 E83102
                LB      A, #040h               ; 23B3 0 200 180 7740
idleign_result_store_cmp_acc:     CMPB    A, off(00289h)         ; 23B5 0 200 180 C789
                MB      off(00231h).0, C       ; 23B7 0 200 180 C43138
                CLRB    A                      ; 23BA 0 200 180 FA
                MOV     X1, #05082h            ; 23BB 0 200 180 608250
                JBS     off(00230h).6, knockretard_table_gate ; 23BE 0 200 180 EE3004
                INC     X1                     ; 23C1 0 200 180 70
                MB      C, off(00230h).7       ; 23C2 0 200 180 C4302F
knockretard_table_gate:     JGE     knockretard_store             ; 23C5 0 200 180 CD0C
                L       A, off(00278h)         ; 23C7 1 200 180 E478
                ST      A, er3                 ; 23C9 1 200 180 8B
                LB      A, off(00288h)         ; 23CA 0 200 180 F488
                CAL     knockretard_table_gate_sub_load_acc             ; 23CC 0 200 180 32EE43
                JBR     off(00230h).6, knockretard_store ; 23CF 0 200 180 DE3001
                VCAL    7                      ; 23D2 0 200 180 17
knockretard_store:     STB     A, off(002b2h)         ; 23D3 0 200 180 D4B2
                J       knockretard_store_if_ram21d_bit2_clr             ; 23D5 0 200 180 03406E
knockretard_store_load_ram289:     LB      A, off(00289h)         ; 23D8 0 200 180 F489
                MOV     X1, #050beh            ; 23DA 0 200 180 60BE50
                VCAL    0                      ; 23DD 0 200 180 10
                CMPB    A, 0e7h                ; 23DE 0 200 180 C5E7C2
                JLT     knockretard_store_goto_4f3e             ; 23E1 0 200 180 CA15
                CMPB    A, 0abh                ; 23E3 0 200 180 C5ABC2
                JGE     knockretard_store_goto_4f3e             ; 23E6 0 200 180 CD10
                CMPB    0e9h, #010h            ; 23E8 0 200 180 C5E9C010
                JLE     knockretard_store_goto_4f3e             ; 23EC 0 200 180 CF0A
                SB      off(00230h).5          ; 23EE 0 200 180 C4301D
                DECB    off(0029ch)            ; 23F1 0 200 180 C49C17
                J       knockretard_store_load_imm_2             ; 23F4 0 200 180 03384F
                DB  000h ; 23F7
knockretard_store_goto_4f3e:     J       knockretard_store_load_ram280             ; 23F8 0 200 180 033E4F
knockretard_store_load_ram29c:     LB      A, off(0029ch)         ; 23FB 0 200 180 F49C
                JEQ     knockretard_store_load_ram2ae             ; 23FD 0 200 180 C905
                DECB    off(0029ch)            ; 23FF 0 200 180 C49C17
                SJ      knockretard_store_goto_2422             ; 2402 0 200 180 CB17
knockretard_store_load_ram2ae:     LB      A, off(002aeh)         ; 2404 0 200 180 F4AE
                JEQ     knockretard_store_goto_6e90             ; 2406 0 200 180 C908
                ADDB    A, #004h               ; 2408 0 200 180 8604
                JLT     knockretard_store_goto_6e90             ; 240A 0 200 180 CA04
                CMPB    A, r0                  ; 240C 0 200 180 48
                J       knockretard_store_if_lt_goto_6dca             ; 240D 0 200 180 03C06D
knockretard_store_goto_6e90:     J       knockretard_store_clear_ram230_bit5             ; 2410 0 200 180 03906E
                DB  0C4h,09Ch,098h,003h ; 2413
knockretard_store_load_r0:     LB      A, r0                  ; 2417 0 200 180 78
                NOP                            ; 2418 0 200 180 00
knockretard_store_store_ram2ae:     STB     A, off(002aeh)         ; 2419 0 200 180 D4AE
knockretard_store_goto_2422:     J       knockretard_store_load_imm             ; 241B 0 200 180 032224
                DB  000h,0EDh,01Fh,035h ; 241E
knockretard_store_load_imm:     LB      A, #03ah               ; 2422 0 200 180 773A
                JBS     off(00230h).2, knockretard_store_cmp_acc ; 2424 0 200 180 EA3002
                LB      A, #040h               ; 2427 0 200 180 7740
knockretard_store_cmp_acc:     CMPB    A, off(00289h)         ; 2429 0 200 180 C789
                MB      off(00230h).2, C       ; 242B 0 200 180 C4303A
                CLRB    A                      ; 242E 0 200 180 FA
                JGE     knockretard_store_store_ram2b0             ; 242F 0 200 180 CD26
                JBS     off(00211h).1, knockretard_store_store_ram2b0 ; 2431 0 200 180 E91123
                JBS     off(0021ch).3, knockretard_store_store_ram2b0 ; 2434 0 200 180 EB1C20
                JBS     off(00216h).6, knockretard_store_store_ram2b0 ; 2437 0 200 180 EE161D
                J       knockretard_store_if_ram216_bit5_clr             ; 243A 0 200 180 03206E
knockretard_store_clear_acc:     CLR     A                      ; 243D 1 200 180 F9
                LB      A, off(002b1h)         ; 243E 0 200 180 F4B1
                MOV     er3, A                 ; 2440 0 200 180 478A
                LB      A, off(00288h)         ; 2442 0 200 180 F488
                MOV     X1, #0507eh            ; 2444 0 200 180 607E50
                CAL     knockretard_table_gate_sub_load_acc             ; 2447 0 200 180 32EE43
                STB     A, r6                  ; 244A 0 200 180 8E
                LB      A, off(002b0h)         ; 244B 0 200 180 F4B0
                ADDB    A, #001h               ; 244D 0 200 180 8601
                JGE     knockretard_store_cmp_acc_2             ; 244F 0 200 180 CD02
                LB      A, #0ffh               ; 2451 0 200 180 77FF
knockretard_store_cmp_acc_2:     CMPB    A, r6                  ; 2453 0 200 180 4E
                JLT     knockretard_store_store_ram2b0             ; 2454 0 200 180 CA01
                LB      A, r6                  ; 2456 0 200 180 7E
knockretard_store_store_ram2b0:     STB     A, off(002b0h)         ; 2457 0 200 180 D4B0
                MOVB    r0, off(002cbh)        ; 2459 0 200 180 C4CB48
                MULB                           ; 245C 0 200 180 A234
                L       A, ACC                 ; 245E 1 200 180 E506
                SLL     A                      ; 2460 1 200 180 53
                LB      A, ACCH                ; 2461 0 200 180 F507
                JGE     knockretard_store_call_4f90             ; 2463 0 200 180 CD02
                LB      A, #0ffh               ; 2465 0 200 180 77FF
knockretard_store_call_4f90:     CAL     knockretard_store_sub_vcal_7             ; 2467 0 200 180 32904F
                LB      A, (001e5h-00180h)[USP] ; 246A 0 200 180 F365
                JNE     knockretard_store_if_ram21d_bit5_clr             ; 246C 0 200 180 CE03
                JBS     off(0021ch).7, knockretard_store_load_ram2ab ; 246E 0 200 180 EF1C2B
knockretard_store_if_ram21d_bit5_clr:     JBR     off(0021dh).5, knockretard_store_load_ram2ab ; 2471 0 200 180 DD1D28
                MOV     DP, #0517bh            ; 2474 0 200 180 627B51
                MOV     X1, 0cch               ; 2477 0 200 180 B5CC78
                LB      A, 0efh                ; 247A 0 200 180 F5EF
                JBS     off(0021dh).1, knockretard_store_call_4523 ; 247C 0 200 180 E91D08
                MOV     DP, #0518fh            ; 247F 0 200 180 628F51
                MOV     X1, 0cah               ; 2482 0 200 180 B5CA78
                LB      A, 0eeh                ; 2485 0 200 180 F5EE
knockretard_store_call_4523:     CAL     scale_result_common_sub_extnd_acc             ; 2487 0 200 180 322345
                VCAL    7                      ; 248A 0 200 180 17
                JEQ     knockretard_store_load_r6             ; 248B 0 200 180 C90C
                STB     A, r6                  ; 248D 0 200 180 8E
                LB      A, off(002abh)         ; 248E 0 200 180 F4AB
                SUBB    A, #002h               ; 2490 0 200 180 A602
                JGT     knockretard_store_cmp_acc_3             ; 2492 0 200 180 C802
                LB      A, #001h               ; 2494 0 200 180 7701
knockretard_store_cmp_acc_3:     CMPB    A, r6                  ; 2496 0 200 180 4E
                JGE     knockretard_store_store_ram2ab             ; 2497 0 200 180 CD0C
knockretard_store_load_r6:     LB      A, r6                  ; 2499 0 200 180 7E
                SJ      knockretard_store_store_ram2ab             ; 249A 0 200 180 CB09
knockretard_store_load_ram2ab:     LB      A, off(002abh)         ; 249C 0 200 180 F4AB
                JEQ     knockretard_store_store_ram2ab             ; 249E 0 200 180 C905
                ADDB    A, #002h               ; 24A0 0 200 180 8602
                JGE     knockretard_store_store_ram2ab             ; 24A2 0 200 180 CD01
                CLRB    A                      ; 24A4 0 200 180 FA
knockretard_store_store_ram2ab:     STB     A, off(002abh)         ; 24A5 0 200 180 D4AB
                LB      A, off(00289h)         ; 24A7 0 200 180 F489
                CMPB    A, #0f0h               ; 24A9 0 200 180 C6F0
                JGE     knockretard_store_goto_253c             ; 24AB 0 200 180 CD26
                CMPB    A, #02dh               ; 24AD 0 200 180 C62D
                JLT     knockretard_store_goto_253c             ; 24AF 0 200 180 CA22
                LB      A, 0dfh                ; 24B1 0 200 180 F5DF
                CMPB    A, #064h               ; 24B3 0 200 180 C664
                JGE     knockretard_store_goto_253c             ; 24B5 0 200 180 CD1C
                CMPB    A, #00ch               ; 24B7 0 200 180 C60C
                JLT     knockretard_store_goto_253c             ; 24B9 0 200 180 CA18
                L       A, off(00210h)         ; 24BB 1 200 180 E410
                AND     A, #08074h             ; 24BD 1 200 180 D67480
                JNE     knockretard_store_goto_253c             ; 24C0 1 200 180 CE11
                JBS     off(00212h).0, knockretard_store_goto_253c ; 24C2 1 200 180 E8120E
                JBS     off(00220h).0, knockretard_store_goto_253c ; 24C5 1 200 180 E8200B
                JBS     off(0021dh).2, knockretard_store_goto_253c ; 24C8 1 200 180 EA1D08
                CMPB    0d9h, #034h            ; 24CB 1 200 180 C5D9C034
                JGE     knockretard_store_goto_253c             ; 24CF 1 200 180 CD02
                SJ      knockretard_store_if_ram230_bit0_set             ; 24D1 1 200 180 CB03
knockretard_store_goto_253c:     J       knockretard_store_clear_ram230_bit0             ; 24D3 0 200 180 033C25
knockretard_store_if_ram230_bit0_set:     JBS     off(00230h).0, knockretard_store_if_ram219_bit4_set ; 24D6 1 200 180 E8301B
                MOV     X1, #0515ah            ; 24D9 1 200 180 605A51
                LB      A, off(00289h)         ; 24DC 0 200 180 F489
                VCAL    0                      ; 24DE 0 200 180 10
                CMPB    A, 0e7h                ; 24DF 0 200 180 C5E7C2
                LB      A, off(002a2h)         ; 24E2 0 200 180 F4A2
                JLT     knockretard_store_if_eq_goto_253c             ; 24E4 0 200 180 CA36
                JNE     knockretard_store_store_r0             ; 24E6 0 200 180 CE36
                JBR     off(00219h).0, tipin_decay_zero ; 24E8 0 200 180 D81954
                CMPB    0e9h, #010h            ; 24EB 0 200 180 C5E9C010
                JLT     tipin_decay_zero             ; 24EF 0 200 180 CA4E
                SB      off(00230h).0          ; 24F1 0 200 180 C43018
knockretard_store_if_ram219_bit4_set:     JBS     off(00219h).4, knockretard_store_load_x1 ; 24F4 0 200 180 EC1907
                CMP     0b0h, #0ffffh          ; 24F7 0 200 180 B5B0C0FFFF
                JGE     tipin_decay_zero             ; 24FC 0 200 180 CD41
knockretard_store_load_x1:     MOV     X1, #05168h            ; 24FE 0 200 180 606851
                LB      A, off(00289h)         ; 2501 0 200 180 F489
                VCAL    0                      ; 2503 0 200 180 10
                MOVB    r0, off(002a5h)        ; 2504 0 200 180 C4A548
                MULB                           ; 2507 0 200 180 A234
                L       A, ACC                 ; 2509 1 200 180 E506
                SLL     A                      ; 250B 1 200 180 53
                LB      A, ACCH                ; 250C 0 200 180 F507
                JGE     knockretard_store_vcal_7             ; 250E 0 200 180 CD02
                LB      A, #0ffh               ; 2510 0 200 180 77FF
knockretard_store_vcal_7:     VCAL    7                      ; 2512 0 200 180 17
                RB      off(00230h).0          ; 2513 0 200 180 C43008
                MOVB    off(002a3h), #018h     ; 2516 0 200 180 C4A39818
                SJ      knockretard_store_store_r0             ; 251A 0 200 180 CB02
knockretard_store_if_eq_goto_253c:     JEQ     knockretard_store_clear_ram230_bit0             ; 251C 0 200 180 C91E
knockretard_store_store_r0:     STB     A, r0                  ; 251E 0 200 180 88
                LB      A, off(002a3h)         ; 251F 0 200 180 F4A3
                JEQ     knockretard_store_load_r0_2             ; 2521 0 200 180 C90E
                DECB    off(002a3h)            ; 2523 0 200 180 C4A317
                JBS     off(00219h).4, knockretard_store_load_r0_2 ; 2526 0 200 180 EC1908
                CMP     0b0h, #00004h          ; 2529 0 200 180 B5B0C00400
                LB      A, r0                  ; 252E 0 200 180 78
                JGE     tipin_decay_zero_clear_carry             ; 252F 0 200 180 CD0F
knockretard_store_load_r0_2:     LB      A, r0                  ; 2531 0 200 180 78
                JEQ     knockretard_store_set_carry             ; 2532 0 200 180 C905
                ADDB    A, #001h               ; 2534 0 200 180 8601
                JGE     knockretard_store_set_carry             ; 2536 0 200 180 CD01
                CLRB    A                      ; 2538 0 200 180 FA
knockretard_store_set_carry:     SC                             ; 2539 0 200 180 85
                SJ      tipin_decay_zero_store_carry_ram230_bit1             ; 253A 0 200 180 CB05
knockretard_store_clear_ram230_bit0:     RB      off(00230h).0          ; 253C 0 200 180 C43008
tipin_decay_zero:     CLRB    A                      ; 253F 0 200 180 FA
tipin_decay_zero_clear_carry:     RC                             ; 2540 0 200 180 95
tipin_decay_zero_store_carry_ram230_bit1:     MB      off(00230h).1, C       ; 2541 0 200 180 C43039
                STB     A, off(002a2h)         ; 2544 0 200 180 D4A2
                CLRB    A                      ; 2546 0 200 180 FA
                JBR     off(0021bh).3, tipin_decay_zero_store_ram2cc ; 2547 0 200 180 DB1B0E
                JBS     off(00217h).0, tipin_decay_zero_store_ram2cc ; 254A 0 200 180 E8170B
                CMPB    0d9h, #000h            ; 254D 0 200 180 C5D9C000
                JGE     tipin_decay_zero_store_ram2cc             ; 2551 0 200 180 CD05
                JBR     off(0021ch).0, tipin_decay_zero_store_ram2cc ; 2553 0 200 180 D81C02
                LB      A, #015h               ; 2556 0 200 180 7715
tipin_decay_zero_store_ram2cc:     STB     A, off(002cch)         ; 2558 0 200 180 D4CC
                LB      A, #0d0h               ; 255A 0 200 180 77D0
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc ; 255C 0 200 180 E93102
                LB      A, #0cdh               ; 255F 0 200 180 77CD
tipin_decay_zero_cmp_acc:     CMPB    A, off(00289h)         ; 2561 0 200 180 C789
                JLT     tipin_decay_zero_clear_carry_2             ; 2563 0 200 180 CA42
                JBS     off(00220h).0, tipin_decay_zero_clear_carry_2 ; 2565 0 200 180 E8203F
                LB      A, off(00210h)         ; 2568 0 200 180 F410
                ANDB    A, #0b4h               ; 256A 0 200 180 D6B4
                JNE     tipin_decay_zero_clear_carry_2             ; 256C 0 200 180 CE39
                JBS     off(00211h).0, tipin_decay_zero_clear_carry_2 ; 256E 0 200 180 E81136
                JBS     off(00212h).0, tipin_decay_zero_clear_carry_2 ; 2571 0 200 180 E81233
                JBS     off(0021dh).2, tipin_decay_zero_clear_carry_2 ; 2574 0 200 180 EA1D30
                LB      A, #07ah               ; 2577 0 200 180 777A
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc_2 ; 2579 0 200 180 E93102
                LB      A, #080h               ; 257C 0 200 180 7780
tipin_decay_zero_cmp_acc_2:     CMPB    A, off(00289h)         ; 257E 0 200 180 C789
                JGE     tipin_decay_zero_store_carry_ram231_bit1             ; 2580 0 200 180 CD26
                LB      A, #09ch               ; 2582 0 200 180 779C
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc_3 ; 2584 0 200 180 E93102
                LB      A, #092h               ; 2587 0 200 180 7792
tipin_decay_zero_cmp_acc_3:     CMPB    A, off(00288h)         ; 2589 0 200 180 C788
                JLT     tipin_decay_zero_clear_carry_2             ; 258B 0 200 180 CA1A
                LB      A, #02ch               ; 258D 0 200 180 772C
                JBS     off(00231h).1, tipin_decay_zero_cmp_acc_4 ; 258F 0 200 180 E93102
                LB      A, #033h               ; 2592 0 200 180 7733
tipin_decay_zero_cmp_acc_4:     CMPB    A, off(00288h)         ; 2594 0 200 180 C788
                JGE     tipin_decay_zero_store_carry_ram231_bit1             ; 2596 0 200 180 CD10
                LB      A, off(002a2h)         ; 2598 0 200 180 F4A2
                JNE     tipin_decay_zero_clear_carry_2             ; 259A 0 200 180 CE0B
                CMPB    0d9h, #034h            ; 259C 0 200 180 C5D9C034
                JGE     tipin_decay_zero_store_carry_ram231_bit1             ; 25A0 0 200 180 CD06
                JBR     off(00216h).5, tipin_decay_zero_clear_carry_2 ; 25A2 0 200 180 DD1602
                SJ      tipin_decay_zero_store_carry_ram231_bit1             ; 25A5 0 200 180 CB01
tipin_decay_zero_clear_carry_2:     RC                             ; 25A7 0 200 180 95
tipin_decay_zero_store_carry_ram231_bit1:     MB      off(00231h).1, C       ; 25A8 0 200 180 C43139
                MOV     DP, #tipin_decay_zero_tbl          ; 25AB 0 200 180 622257
                JBS     off(0021dh).0, tipin_decay_zero_load_ram0ef ; 25AE 0 200 180 E81D07
                LB      A, (001b4h-00180h)[USP] ; 25B1 0 200 180 F334
                JEQ     tipin_decay_zero_store_ram2c4             ; 25B3 0 200 180 C919
                MOV     DP, #tipin_decay_zero_tbl_2          ; 25B5 0 200 180 627469
tipin_decay_zero_load_ram0ef:     LB      A, 0efh                ; 25B8 0 200 180 F5EF
                MOV     X1, 0cch               ; 25BA 0 200 180 B5CC78
                JBS     off(0021dh).1, tipin_decay_zero_call_4523 ; 25BD 0 200 180 E91D09
                LB      A, 0eeh                ; 25C0 0 200 180 F5EE
                MOV     X1, 0cah               ; 25C2 0 200 180 B5CA78
                SUB     DP, #00014h            ; 25C5 0 200 180 92A01400
tipin_decay_zero_call_4523:     CAL     scale_result_common_sub_extnd_acc             ; 25C9 0 200 180 322345
                SUBB    A, #080h               ; 25CC 0 200 180 A680
tipin_decay_zero_store_ram2c4:     STB     A, off(002c4h)         ; 25CE 0 200 180 D4C4
                SC                             ; 25D0 0 200 180 85
                JBR     off(00221h).1, tipin_decay_zero_store_carry_ram238_bit0 ; 25D1 0 200 180 D9210F
                LB      A, (001a2h-00180h)[USP] ; 25D4 0 200 180 F322
                CMPB    A, #007h               ; 25D6 0 200 180 C607
                JLT     tipin_decay_zero_store_carry_ram238_bit0             ; 25D8 0 200 180 CA09
                LB      A, (001aah-00180h)[USP] ; 25DA 0 200 180 F32A
                CMPB    A, #019h               ; 25DC 0 200 180 C619
                JLT     tipin_decay_zero_store_carry_ram238_bit0             ; 25DE 0 200 180 CA03
                MB      C, off(0021ah).7       ; 25E0 0 200 180 C41A2F
tipin_decay_zero_store_carry_ram238_bit0:     MB      off(00238h).0, C       ; 25E3 0 200 180 C43838
                CLRB    A                      ; 25E6 0 200 180 FA
                RC                             ; 25E7 0 200 180 95
                JBS     off(00238h).0, scale_result_common_store_carry_ram238_bit1 ; 25E8 0 200 180 E83828
                JBS     off(00210h).3, scale_result_common_store_carry_ram238_bit1 ; 25EB 0 200 180 EB1025
                JBS     off(00211h).0, scale_result_common_store_carry_ram238_bit1 ; 25EE 0 200 180 E81122
                L       A, 0d0h                ; 25F1 1 200 180 E5D0
                ST      A, er2                 ; 25F3 1 200 180 8A
                CLR     er0                    ; 25F4 1 200 180 4415
                MOVB    r2, #005h              ; 25F6 1 200 180 9A05
scale_shift_loop:     SLL     A                      ; 25F8 1 200 180 53
                ADCB    r1, #000h              ; 25F9 1 200 180 219000
                SLL     A                      ; 25FC 1 200 180 53
                ADCB    r0, #000h              ; 25FD 1 200 180 209000
                DECB    r2                     ; 2600 1 200 180 BA
                JNE     scale_shift_loop             ; 2601 1 200 180 CEF5
                SLL     A                      ; 2603 1 200 180 53
                JGE     scale_direction_toggle             ; 2604 1 200 180 CD09
                SLL     A                      ; 2606 1 200 180 53
                JGE     scale_direction_toggle             ; 2607 1 200 180 CD06
                L       A, er0                 ; 2609 1 200 180 34
                AND     A, #00101h             ; 260A 1 200 180 D60101
                JNE     scale_result_common             ; 260D 1 200 180 CE03
scale_direction_toggle:     XORB    PSWH, #080h            ; 260F 1 200 180 A2F080
scale_result_common:     LB      A, r5                  ; 2612 0 200 180 7D
scale_result_common_store_carry_ram238_bit1:     MB      off(00238h).1, C       ; 2613 0 200 180 C43839
                SRLB    A                      ; 2616 0 200 180 63
                MB      off(00238h).2, C       ; 2617 0 200 180 C4383A
                STB     A, r5                  ; 261A 0 200 180 8D
                CLRB    A                      ; 261B 0 200 180 FA
                JBR     off(00221h).1, scale_result_common_store_ram2b4 ; 261C 0 200 180 D9212F
                CMPB    off(00289h), #00dh     ; 261F 0 200 180 C489C00D
                JLT     scale_result_common_vcal_7             ; 2623 0 200 180 CA28
                JBS     off(00232h).4, scale_result_common_load_ram0ef ; 2625 0 200 180 EC320F
                NOP                            ; 2628 0 200 180 00
                NOP                            ; 2629 0 200 180 00
                NOP                            ; 262A 0 200 180 00
                JBS     off(00212h).7, scale_result_common_load_ram0ef ; 262B 0 200 180 EF1209
                JBS     off(00238h).0, scale_result_common_load_ram289 ; 262E 0 200 180 E8381F
                JBS     off(00238h).1, scale_result_common_load_ram289 ; 2631 0 200 180 E9381C
                LB      A, r5                  ; 2634 0 200 180 7D
                SJ      scale_result_common_vcal_7             ; 2635 0 200 180 CB16
scale_result_common_load_ram0ef:     LB      A, 0efh                ; 2637 0 200 180 F5EF
                MOV     X1, 0cch               ; 2639 0 200 180 B5CC78
                MOV     DP, #scale_result_common_tbl_2          ; 263C 0 200 180 62026A
                JBS     off(0021dh).1, scale_result_common_call_4523 ; 263F 0 200 180 E91D08
                LB      A, 0eeh                ; 2642 0 200 180 F5EE
                MOV     X1, 0cah               ; 2644 0 200 180 B5CA78
                MOV     DP, #scale_result_common_tbl_3          ; 2647 0 200 180 62166A
scale_result_common_call_4523:     CAL     scale_result_common_sub_extnd_acc             ; 264A 0 200 180 322345
scale_result_common_vcal_7:     VCAL    7                      ; 264D 0 200 180 17
scale_result_common_store_ram2b4:     STB     A, off(002b4h)         ; 264E 0 200 180 D4B4
scale_result_common_load_ram289:     LB      A, off(00289h)         ; 2650 0 200 180 F489
                MOV     X1, #05046h            ; 2652 0 200 180 604650
                VCAL    0                      ; 2655 0 200 180 10
                STB     A, off(002b7h)         ; 2656 0 200 180 D4B7
                LB      A, #0ffh               ; 2658 0 200 180 77FF
                JBS     off(00232h).1, scale_result_common_cmp_acc ; 265A 0 200 180 E93202
                LB      A, #0ffh               ; 265D 0 200 180 77FF
scale_result_common_cmp_acc:     CMPB    A, off(00289h)         ; 265F 0 200 180 C789
                MB      off(00232h).1, C       ; 2661 0 200 180 C43239
                LB      A, off(00289h)         ; 2664 0 200 180 F489
                MOV     X1, #05000h            ; 2666 0 200 180 600050
                VCAL    0                      ; 2669 0 200 180 10
                STB     A, off(002a7h)         ; 266A 0 200 180 D4A7
                STB     A, r0                  ; 266C 0 200 180 88
                LB      A, off(002a8h)         ; 266D 0 200 180 F4A8
                MULB                           ; 266F 0 200 180 A234
                L       A, ACC                 ; 2671 1 200 180 E506
                MOVB    r0, #0d0h              ; 2673 1 200 180 98D0
                MOVB    r1, #015h              ; 2675 1 200 180 9915
                SLL     A                      ; 2677 1 200 180 53
                JLT     scale_result_common_load_r0             ; 2678 1 200 180 CA0D
                SLL     A                      ; 267A 1 200 180 53
                JLT     scale_result_common_load_r0             ; 267B 1 200 180 CA0A
                LB      A, ACCH                ; 267D 0 200 180 F507
                CMPB    A, r0                  ; 267F 0 200 180 48
                JGE     scale_result_common_load_r0             ; 2680 0 200 180 CD05
                CMPB    A, r1                  ; 2682 0 200 180 49
                JGE     scale_result_common_store_ram2a9             ; 2683 0 200 180 CD03
                MOVB    r0, r1                 ; 2685 0 200 180 2148
scale_result_common_load_r0:     LB      A, r0                  ; 2687 0 200 180 78
scale_result_common_store_ram2a9:     STB     A, off(002a9h)         ; 2688 0 200 180 D4A9
                JBS     off(00232h).1, scale_result_common_srlb_acc ; 268A 0 200 180 E93201
                SRLB    A                      ; 268D 0 200 180 63
scale_result_common_srlb_acc:     SRLB    A                      ; 268E 0 200 180 63
                CMPB    A, r1                  ; 268F 0 200 180 49
                JGE     scale_result_common_store_ram2c7             ; 2690 0 200 180 CD01
                LB      A, r1                  ; 2692 0 200 180 79
scale_result_common_store_ram2c7:     STB     A, off(002c7h)         ; 2693 0 200 180 D4C7
                LB      A, #0c8h               ; 2695 0 200 180 77C8
                JBS     off(00231h).2, scale_result_common_cmp_acc_2 ; 2697 0 200 180 EA3102
                LB      A, #0d0h               ; 269A 0 200 180 77D0
scale_result_common_cmp_acc_2:     CMPB    A, off(002a9h)         ; 269C 0 200 180 C7A9
                MB      off(00231h).2, C       ; 269E 0 200 180 C4313A
                MOV     DP, #0511eh            ; 26A1 0 200 180 621E51
                MOV     X1, 0cch               ; 26A4 0 200 180 B5CC78
                LB      A, 0efh                ; 26A7 0 200 180 F5EF
                JBS     off(0021dh).1, scale_result_common_if_ram231_bit2_set ; 26A9 0 200 180 E91D08
                MOV     DP, #05146h            ; 26AC 0 200 180 624651
                MOV     X1, 0cah               ; 26AF 0 200 180 B5CA78
                LB      A, 0eeh                ; 26B2 0 200 180 F5EE
scale_result_common_if_ram231_bit2_set:     JBS     off(00231h).2, scale_result_common_call_4523_2 ; 26B4 0 200 180 EA3111
                SUB     DP, #00014h            ; 26B7 0 200 180 92A01400
                JBR     off(0021dh).0, scale_result_common_call_4523_2 ; 26BB 0 200 180 D81D0A
                MOV     DP, #scale_result_common_tbl          ; 26BE 0 200 180 628869
                JBS     off(0021dh).1, scale_result_common_call_4523_2 ; 26C1 0 200 180 E91D04
                ADD     DP, #00014h            ; 26C4 0 200 180 92801400
scale_result_common_call_4523_2:     CAL     scale_result_common_sub_extnd_acc             ; 26C8 0 200 180 322345
                STB     A, off(002b6h)         ; 26CB 0 200 180 D4B6
                CLR     er3                    ; 26CD 0 200 180 4715
                JBS     off(00210h).5, scale_result_common_load_ram2b4 ; 26CF 0 200 180 ED1037
                JBR     off(00230h).1, scale_result_common_load_ram2ca ; 26D2 0 200 180 D93005
                LB      A, off(002a2h)         ; 26D5 0 200 180 F4A2
                CAL     scale_result_common_sub_extnd_acc_2             ; 26D7 0 200 180 32F246
scale_result_common_load_ram2ca:     LB      A, off(002cah)         ; 26DA 0 200 180 F4CA
                CAL     scale_result_common_sub_extnd_acc_2             ; 26DC 0 200 180 32F246
                LB      A, off(002afh)         ; 26DF 0 200 180 F4AF
                CAL     scale_result_common_sub_extnd_acc_2             ; 26E1 0 200 180 32F246
                LB      A, off(002abh)         ; 26E4 0 200 180 F4AB
                CAL     scale_result_common_sub_extnd_acc_2             ; 26E6 0 200 180 32F246
                LB      A, off(002b2h)         ; 26E9 0 200 180 F4B2
                EXTND                          ; 26EB 1 200 180 F8
                ADD     er3, A                 ; 26EC 1 200 180 4781
                LB      A, off(002aeh)         ; 26EE 0 200 180 F4AE
                EXTND                          ; 26F0 1 200 180 F8
                ADD     er3, A                 ; 26F1 1 200 180 4781
                LB      A, off(002adh)         ; 26F3 0 200 180 F4AD
                CAL     scale_result_common_sub_extnd_acc_3             ; 26F5 0 200 180 32F04F
                LB      A, off(002c4h)         ; 26F8 0 200 180 F4C4
                EXTND                          ; 26FA 1 200 180 F8
                ADD     er3, A                 ; 26FB 1 200 180 4781
                CLR     A                      ; 26FD 1 200 180 F9
                LB      A, off(002cch)         ; 26FE 0 200 180 F4CC
                L       A, ACC                 ; 2700 1 200 180 E506
                ADD     er3, A                 ; 2702 1 200 180 4781
                LB      A, off(002b3h)         ; 2704 0 200 180 F4B3
                EXTND                          ; 2706 1 200 180 F8
                ADD     er3, A                 ; 2707 1 200 180 4781
scale_result_common_load_ram2b4:     LB      A, off(002b4h)         ; 2709 0 200 180 F4B4
                EXTND                          ; 270B 1 200 180 F8
                ADD     er3, A                 ; 270C 1 200 180 4781
                LB      A, off(002ach)         ; 270E 0 200 180 F4AC
                EXTND                          ; 2710 1 200 180 F8
                ADD     er3, A                 ; 2711 1 200 180 4781
                CLR     A                      ; 2713 1 200 180 F9
                LB      A, off(002aah)         ; 2714 0 200 180 F4AA
                STB     A, r0                  ; 2716 0 200 180 88
                L       A, ACC                 ; 2717 1 200 180 E506
                ADD     A, er3                 ; 2719 1 200 180 0B
                JBR     off(00207h).7, ign_sum_clamp_check ; 271A 1 200 180 DF0705
                JLT     ign_sum_result             ; 271D 1 200 180 CA0A
                CLRB    A                      ; 271F 0 200 180 FA
                SJ      ign_sum_result             ; 2720 0 200 180 CB07
ign_sum_clamp_check:     CMP     A, #000ffh             ; 2722 1 200 180 C6FF00
                JLT     ign_sum_result             ; 2725 1 200 180 CA02
                LB      A, #0ffh               ; 2727 0 200 180 77FF
ign_sum_result:     LB      A, ACC                 ; 2729 0 200 180 F506
                STB     A, r4                  ; 272B 0 200 180 8C
                JBR     off(00231h).1, ign_sum_result_store_r5 ; 272C 0 200 180 D9311A
                LB      A, #0b3h               ; 272F 0 200 180 77B3
                MULB                           ; 2731 0 200 180 A234
                CLRB    A                      ; 2733 0 200 180 FA
                L       A, ACC                 ; 2734 1 200 180 E506
                SWAP                           ; 2736 1 200 180 83
                ADD     A, er3                 ; 2737 1 200 180 0B
                JBR     off(00207h).7, ign_sum_result_cmp_acc ; 2738 1 200 180 DF0705
                JLT     ign_sum_result_load_acc             ; 273B 1 200 180 CA0A
                CLRB    A                      ; 273D 0 200 180 FA
                SJ      ign_sum_result_load_acc             ; 273E 0 200 180 CB07
ign_sum_result_cmp_acc:     CMP     A, #000ffh             ; 2740 1 200 180 C6FF00
                JLT     ign_sum_result_load_acc             ; 2743 1 200 180 CA02
                LB      A, #0ffh               ; 2745 0 200 180 77FF
ign_sum_result_load_acc:     LB      A, ACC                 ; 2747 0 200 180 F506
ign_sum_result_store_r5:     STB     A, r5                  ; 2749 0 200 180 8D
                SC                             ; 274A 0 200 180 85
                JBS     off(00210h).5, ign_p40_toggle_store_carry_ram231_bit3 ; 274B 0 200 180 ED102C
                CMPB    0d9h, #0c5h            ; 274E 0 200 180 C5D9C0C5
                JLT     ign_p40_toggle_store_carry_ram231_bit3             ; 2752 0 200 180 CA26
                LB      A, #037h               ; 2754 0 200 180 7737
                MB      C, P3.3                ; 2756 0 200 180 C5242B
                JLT     ign_p40_clamp_store_r4             ; 2759 0 200 180 CA18
                LB      A, #000h               ; 275B 0 200 180 7700
                MB      C, off(0021ah).5       ; 275D 0 200 180 C41A2D
                JLT     ign_p40_clamp_store_r4             ; 2760 0 200 180 CA11
                JBS     off(00231h).3, ign_p40_toggle_load_r4 ; 2762 0 200 180 EB3118
                JBR     off(00217h).0, ign_p40_toggle ; 2765 0 200 180 D8170F
                LB      A, off(002b5h)         ; 2768 0 200 180 F4B5
                ADDB    A, #004h               ; 276A 0 200 180 8604
                JGE     ign_p40_clamp             ; 276C 0 200 180 CD02
                LB      A, #0ffh               ; 276E 0 200 180 77FF
ign_p40_clamp:     CMPB    A, r4                  ; 2770 0 200 180 4C
                JGE     ign_p40_toggle             ; 2771 0 200 180 CD04
ign_p40_clamp_store_r4:     STB     A, r4                  ; 2773 0 200 180 8C
                STB     A, r5                  ; 2774 0 200 180 8D
                STB     A, off(002b5h)         ; 2775 0 200 180 D4B5
ign_p40_toggle:     XORB    PSWH, #080h            ; 2777 0 200 180 A2F080
ign_p40_toggle_store_carry_ram231_bit3:     MB      off(00231h).3, C       ; 277A 0 200 180 C4313B
ign_p40_toggle_load_r4:     LB      A, r4                  ; 277D 0 200 180 7C
                CMPB    A, off(002b6h)         ; 277E 0 200 180 C7B6
                JGE     ign_p40_toggle_store_r4             ; 2780 0 200 180 CD02
                LB      A, off(002b6h)         ; 2782 0 200 180 F4B6
ign_p40_toggle_store_r4:     STB     A, r4                  ; 2784 0 200 180 8C
                ADDB    A, off(002b7h)         ; 2785 0 200 180 87B7
                JGE     ign_p40_toggle_store_ram2b8             ; 2787 0 200 180 CD02
                LB      A, #0ffh               ; 2789 0 200 180 77FF
ign_p40_toggle_store_ram2b8:     STB     A, off(002b8h)         ; 278B 0 200 180 D4B8
                LB      A, r5                  ; 278D 0 200 180 7D
                CMPB    A, off(002b6h)         ; 278E 0 200 180 C7B6
                JGE     ign_p40_toggle_store_r5             ; 2790 0 200 180 CD02
                LB      A, off(002b6h)         ; 2792 0 200 180 F4B6
ign_p40_toggle_store_r5:     STB     A, r5                  ; 2794 0 200 180 8D
                ADDB    A, off(002b7h)         ; 2795 0 200 180 87B7
                JGE     ign_p40_toggle_store_ram2b9             ; 2797 0 200 180 CD02
                LB      A, #0ffh               ; 2799 0 200 180 77FF
ign_p40_toggle_store_ram2b9:     STB     A, off(002b9h)         ; 279B 0 200 180 D4B9
                MOV     off(00282h), er2       ; 279D 0 200 180 467C82
                MOVB    r2, off(002b8h)        ; 27A0 0 200 180 C4B84A
                MOVB    r4, off(002a9h)        ; 27A3 0 200 180 C4A94C
                CAL     ign_angle_to_timer_convert             ; 27A6 0 200 180 32FB46
                MOV     DP, #0038dh            ; 27A9 0 200 180 628D03
                RB      PSWH.0                 ; 27AC 0 200 180 A208
                MB      09eh.6, C              ; 27AE 0 200 180 C59E3E
                STB     A, [DP]                ; 27B1 0 200 180 D2
                INC     DP                     ; 27B2 0 200 180 72
                L       A, er0                 ; 27B3 1 200 180 34
                ST      A, [DP]                ; 27B4 1 200 180 D2
                SB      PSWH.0                 ; 27B5 1 200 180 A218
                MOVB    r2, off(002b9h)        ; 27B7 1 200 180 C4B94A
                MOVB    r4, off(002a9h)        ; 27BA 1 200 180 C4A94C
                CAL     ign_angle_to_timer_convert             ; 27BD 1 200 180 32FB46
                MOV     DP, #00391h            ; 27C0 1 200 180 629103
                RB      PSWH.0                 ; 27C3 1 200 180 A208
                MB      09eh.7, C              ; 27C5 1 200 180 C59E3F
                ST      A, [DP]                ; 27C8 1 200 180 D2
                INC     DP                     ; 27C9 1 200 180 72
                L       A, er0                 ; 27CA 1 200 180 34
                ST      A, [DP]                ; 27CB 1 200 180 D2
                SB      PSWH.0                 ; 27CC 1 200 180 A218
                MOVB    r2, off(002b8h)        ; 27CE 1 200 180 C4B84A
                MOVB    r4, off(002c7h)        ; 27D1 1 200 180 C4C74C
                CAL     ign_angle_to_timer_convert             ; 27D4 1 200 180 32FB46
                MOV     DP, #00395h            ; 27D7 1 200 180 629503
                RB      PSWH.0                 ; 27DA 1 200 180 A208
                MB      09fh.0, C              ; 27DC 1 200 180 C59F38
                ST      A, [DP]                ; 27DF 1 200 180 D2
                INC     DP                     ; 27E0 1 200 180 72
                L       A, er0                 ; 27E1 1 200 180 34
                ST      A, [DP]                ; 27E2 1 200 180 D2
                SB      PSWH.0                 ; 27E3 1 200 180 A218
                LB      A, off(002d5h)         ; 27E5 0 200 180 F4D5
                JNE     ign_p40_toggle_clear_carry             ; 27E7 0 200 180 CE22
                JBR     off(0022ah).0, ign_p40_toggle_clear_carry ; 27E9 0 200 180 D82A1F
                MB      C, P4.7                ; 27EC 0 200 180 C5212F
                JBS     off(00238h).3, ign_p40_toggle_if_lt_goto_280c ; 27EF 0 200 180 EB3807
                XORB    PSWH, #080h            ; 27F2 0 200 180 A2F080
                JLT     dtc27_code27_latch             ; 27F5 0 200 180 CA15
                SJ      ign_p40_toggle_set_carry             ; 27F7 0 200 180 CB08
ign_p40_toggle_if_lt_goto_280c:     JLT     dtc27_code27_latch             ; 27F9 0 200 180 CA11
                RB      P2A.2                  ; 27FB 0 200 180 C5250A
                JBS     off(00238h).3, ign_p40_toggle_store_carry_ram238_bit3 ; 27FE 0 200 180 EB3801
ign_p40_toggle_set_carry:     SC                             ; 2801 0 200 180 85
ign_p40_toggle_store_carry_ram238_bit3:     MB      off(00238h).3, C       ; 2802 0 200 180 C4383B
                JLT     ign_p40_toggle_clear_carry             ; 2805 0 200 180 CA04
                MOVB    off(002d5h), #019h     ; 2807 0 200 180 C4D59819
ign_p40_toggle_clear_carry:     RC                             ; 280B 0 200 180 95
dtc27_code27_latch:     MB      09bh.2, C              ; 280C 0 200 180 C59B3A
                NOP                            ; 280F 0 200 180 00
                NOP                            ; 2810 0 200 180 00
                NOP                            ; 2811 0 200 180 00
                NOP                            ; 2812 0 200 180 00
                NOP                            ; 2813 0 200 180 00
                NOP                            ; 2814 0 200 180 00
                NOP                            ; 2815 0 200 180 00
                NOP                            ; 2816 0 200 180 00
                MB      C, 0a0h.7              ; 2817 0 200 180 C5A02F
                JLT     ign_p40_toggle_load_lrb             ; 281A 0 200 180 CA06
                J       ign_p40_toggle_load_ie             ; 281C 0 200 180 030E4E
                DB  000h,000h,000h ; 281F
ign_p40_toggle_load_lrb:     MOV     LRB, #00020h           ; 2822 0 100 180 572000
                MOV     USP, #00280h           ; 2825 0 100 280 A1988002
                L       A, (00214h-00280h)[USP] ; 2829 1 100 280 E394
                ST      A, off(00114h)         ; 282B 1 100 280 D414
                L       A, (00216h-00280h)[USP] ; 282D 1 100 280 E396
                ST      A, off(00116h)         ; 282F 1 100 280 D416
                L       A, (00218h-00280h)[USP] ; 2831 1 100 280 E398
                ST      A, off(00118h)         ; 2833 1 100 280 D418
                L       A, #01d4ch             ; 2835 1 100 280 674C1D
                JBS     off(0011bh).5, ign_p40_toggle_cmp_ram0ae ; 2838 1 100 280 ED1B03
                L       A, #00b45h             ; 283B 1 100 280 67450B
ign_p40_toggle_cmp_ram0ae:     CMP     0aeh, A                ; 283E 1 100 280 B5AEC1
                MB      off(0011bh).5, C       ; 2841 1 100 280 C41B3D
                LB      A, #0ffh               ; 2844 0 100 280 77FF
                JBS     off(0011dh).3, ign_p40_toggle_cmp_acc ; 2846 0 100 280 EB1D02
                LB      A, #0ffh               ; 2849 0 100 280 77FF
ign_p40_toggle_cmp_acc:     CMPB    A, off(00178h)         ; 284B 0 100 280 C778
                MB      off(0011dh).3, C       ; 284D 0 100 280 C41D3B
                LB      A, #0ffh               ; 2850 0 100 280 77FF
                JBR     off(00120h).4, ign_p40_toggle_store_ram1e7 ; 2852 0 100 280 DC2006
                JBS     off(00116h).1, ign_p40_toggle_store_ram1e7 ; 2855 0 100 280 E91603
                JBS     off(00115h).0, ign_p40_toggle_if_ram115_bit1_set ; 2858 0 100 280 E81505
ign_p40_toggle_store_ram1e7:     STB     A, off(001e7h)         ; 285B 0 100 280 D4E7
                J       vtec_state_active_check_clear_acc             ; 285D 0 100 280 033F29
ign_p40_toggle_if_ram115_bit1_set:     JBS     off(00115h).1, ign_p40_toggle_store_ram1e7 ; 2860 0 100 280 E915F8
                JBR     off(0011dh).3, ign_p40_toggle_store_ram1e7 ; 2863 0 100 280 DB1DF5
                JBR     off(00117h).2, ign_p40_toggle_store_ram1e7 ; 2866 0 100 280 DA17F2
                JBS     off(00113h).1, ign_p40_toggle_if_ram124_bit3_clr ; 2869 0 100 280 E91373
                CMPB    0deh, #0f6h            ; 286C 0 100 280 C5DEC0F6
                JGT     ign_p40_toggle_if_ram124_bit3_clr             ; 2870 0 100 280 C86D
                CMPB    0deh, #004h            ; 2872 0 100 280 C5DEC004
                JLT     ign_p40_toggle_if_ram124_bit3_clr             ; 2876 0 100 280 CA67
                STB     A, off(001e7h)         ; 2878 0 100 280 D4E7
                MOVB    r1, off(001b4h)        ; 287A 0 100 280 C4B449
                LB      A, off(001b2h)         ; 287D 0 100 280 F4B2
                JNE     ign_p40_toggle_subb_acc             ; 287F 0 100 280 CE58
                J       ign_p40_toggle_load_imm_2             ; 2881 0 100 280 03F04E
                DB  000h,000h,077h,0FFh,0C7h,079h,0C4h,031h ; 2884
                DB  03Eh,020h,015h,0CDh,002h,098h,002h,077h ; 288C
                DB  0FFh,0EFh,031h,002h,077h,0FFh,0C7h,078h ; 2894
                DB  0C4h,031h,03Fh,0CDh,001h,0A8h ; 289C
ign_p40_toggle_clear_r1:     CLRB    r1                     ; 28A2 0 100 280 2115
                CMPB    0deh, #0ffh            ; 28A4 0 100 280 C5DEC0FF
                JLE     ign_p40_toggle_load_imm             ; 28A8 0 100 280 CF23
                INCB    r1                     ; 28AA 0 100 280 A9
                LB      A, #006h               ; 28AB 0 100 280 7706
                MULB                           ; 28AD 0 100 280 A234
                EXTND                          ; 28AF 1 100 280 F8
                ADD     A, #ign_p40_toggle_tbl           ; 28B0 1 100 280 86B069
                MOV     DP, A                  ; 28B3 1 100 280 52
                LB      A, 0deh                ; 28B4 0 100 280 F5DE
                CMPCB   A, [DP]                ; 28B6 0 100 280 92AE
                JLE     ign_p40_toggle_load_imm             ; 28B8 0 100 280 CF13
                INCB    r1                     ; 28BA 0 100 280 A9
                JBS     off(00110h).3, ign_p40_toggle_load_imm ; 28BB 0 100 280 EB100F
                JBS     off(00110h).7, ign_p40_toggle_load_imm ; 28BE 0 100 280 EF100C
                DECB    r1                     ; 28C1 0 100 280 B9
ign_p40_toggle_cmp_acc_2:     CMPCB   A, [DP]                ; 28C2 0 100 280 92AE
                JLE     ign_p40_toggle_load_imm             ; 28C4 0 100 280 CF07
                INC     DP                     ; 28C6 0 100 280 72
                INCB    r1                     ; 28C7 0 100 280 A9
                CMPB    r1, #007h              ; 28C8 0 100 280 21C007
                JLT     ign_p40_toggle_cmp_acc_2             ; 28CB 0 100 280 CAF5
ign_p40_toggle_load_imm:     LB      A, #0ffh               ; 28CD 0 100 280 77FF
                JBR     off(0011ah).6, ign_p40_toggle_store_ram1b2 ; 28CF 0 100 280 DE1A09
                SRLB    A                      ; 28D2 0 100 280 63
                JBR     off(00128h).1, ign_p40_toggle_store_ram1b2 ; 28D3 0 100 280 D92805
                SRLB    A                      ; 28D6 0 100 280 63
                SJ      ign_p40_toggle_store_ram1b2             ; 28D7 0 100 280 CB02
ign_p40_toggle_subb_acc:     SUBB    A, #001h               ; 28D9 0 100 280 A601
ign_p40_toggle_store_ram1b2:     STB     A, off(001b2h)         ; 28DB 0 100 280 D4B2
                SJ      vtec_rpm_valid_check             ; 28DD 0 100 280 CB17
ign_p40_toggle_if_ram124_bit3_clr:     JBR     off(00124h).3, vtec_state_dispatch ; 28DF 0 100 280 DB240A
                STB     A, off(001e7h)         ; 28E2 0 100 280 D4E7
vtec_state_reset_no_pressure:     MOVB    off(001e8h), #0ffh     ; 28E4 0 100 280 C4E898FF
                MOVB    r1, #004h              ; 28E8 0 100 280 9904
                SJ      vtec_rpm_valid_check             ; 28EA 0 100 280 CB0A
vtec_state_dispatch:     LB      A, off(001e7h)         ; 28EC 0 100 280 F4E7
                JNE     vtec_state_reset_no_pressure             ; 28EE 0 100 280 CEF4
                LB      A, off(001e8h)         ; 28F0 0 100 280 F4E8
                JEQ     vtec_state_active_check_clear_acc             ; 28F2 0 100 280 C94B
                MOVB    r1, #002h              ; 28F4 0 100 280 9902
vtec_rpm_valid_check:     CMPB    off(00179h), #0ffh     ; 28F6 0 100 280 C479C0FF
                JGE     vtec_rpm_valid_check_cmp_r1             ; 28FA 0 100 280 CD05
                JBS     off(0011dh).0, vtec_state_confirm ; 28FC 0 100 280 E81D10
                SJ      vtec_state_active_check_clear_acc             ; 28FF 0 100 280 CB3E
vtec_rpm_valid_check_cmp_r1:     CMPB    r1, #001h              ; 2901 0 100 280 21C001
                JLE     vtec_state_active_check             ; 2904 0 100 280 CF06
                MOVB    off(001f6h), #0ffh     ; 2906 0 100 280 C4F698FF
                SJ      vtec_state_store             ; 290A 0 100 280 CB0C
vtec_state_active_check:     JBR     off(0011dh).0, vtec_state_active_check_load_r1 ; 290C 0 100 280 D81D2B
vtec_state_confirm:     LB      A, off(001f6h)         ; 290F 0 100 280 F4F6
                JEQ     vtec_state_active_check_load_r1             ; 2911 0 100 280 C927
                MOVB    r1, #002h              ; 2913 0 100 280 9902
                CLRB    off(001b2h)            ; 2915 0 100 280 C4B215
vtec_state_store:     LB      A, r1                  ; 2918 0 100 280 79
                STB     A, off(001b4h)         ; 2919 0 100 280 D4B4
                SB      off(0011dh).0          ; 291B 0 100 280 C41D18
                JNE     vtec_state_store_cmp_ram1b6             ; 291E 0 100 280 CE07
                MOVB    off(001b6h), #00ch     ; 2920 0 100 280 C4B6980C
                CLRB    A                      ; 2924 0 100 280 FA
                STB     A, off(001aeh)         ; 2925 0 100 280 D4AE
vtec_state_store_cmp_ram1b6:     CMPB    off(001b6h), #008h     ; 2927 0 100 280 C4B6C008
                JGT     vtec_state_store_goto_2948             ; 292B 0 100 280 C80B
                CLR     A                      ; 292D 1 100 280 F9
                LB      A, r1                  ; 292E 0 100 280 79
                MOV     DP, #tbl_cfg_69c6          ; 292F 0 100 280 62C669
                ADD     DP, A                  ; 2932 0 100 280 9281
                LCB     A, [DP]                ; 2934 0 100 280 92AA
                STB     A, off(001aeh)         ; 2936 0 100 280 D4AE
vtec_state_store_goto_2948:     SJ      vtec_state_store_goto_6e00             ; 2938 0 100 280 CB0E
vtec_state_active_check_load_r1:     LB      A, r1                  ; 293A 0 100 280 79
                CMPB    A, #001h               ; 293B 0 100 280 C601
                JEQ     vtec_state_active_check_store_ram1b4             ; 293D 0 100 280 C901
vtec_state_active_check_clear_acc:     CLRB    A                      ; 293F 0 100 280 FA
vtec_state_active_check_store_ram1b4:     STB     A, off(001b4h)         ; 2940 0 100 280 D4B4
                RB      off(0011dh).0          ; 2942 0 100 280 C41D08
                CLRB    off(001b2h)            ; 2945 0 100 280 C4B215
vtec_state_store_goto_6e00:     J       vtec_state_store_set_carry             ; 2948 0 100 280 03006E
                DW  00000h           ; 294B
;  [flow] VTEC state machine + duty value: 011Dh.0/.1 = engaged/active latches, 01B4h = requested
;    state (0/1/2 set here), 01B6h = dwell/confirm countdown, 01AEh = soliton duty value taken from
;    tbl_cfg_69c6 (@69C6) when 01B6h <= 8. r1=2 means 'active'.
vtec_state_store_load_x1:     MOV     X1, 0cch               ; 294D 0 100 280 B5CC78
                JBS     off(0011dh).1, vtec_state_store_call_4523 ; 2950 0 100 280 E91D08
                LB      A, 0eeh                ; 2953 0 100 280 F5EE
                MOV     DP, #tbl_6a4f          ; 2955 0 100 280 624F6A
                MOV     X1, 0cah               ; 2958 0 100 280 B5CA78
vtec_state_store_call_4523:     CAL     scale_result_common_sub_extnd_acc             ; 295B 0 100 280 322345
                LB      A, 0e3h                ; 295E 0 100 280 F5E3
                CMPB    A, r6                  ; 2960 0 100 280 4E
                JGE     vtec_state_store_store_ram135             ; 2961 0 100 280 CD01
                LB      A, r6                  ; 2963 0 100 280 7E
vtec_state_store_store_ram135:     STB     A, off(00135h)         ; 2964 0 100 280 D435
                LB      A, #0cah               ; 2966 0 100 280 77CA
                JBS     off(0012eh).7, vtec_state_store_cmp_acc ; 2968 0 100 280 EF2E02
                LB      A, #0cdh               ; 296B 0 100 280 77CD
vtec_state_store_cmp_acc:     CMPB    A, off(00179h)         ; 296D 0 100 280 C779
                MB      off(0012eh).7, C       ; 296F 0 100 280 C42E3F
;  [flow] fuel row multiplier per cam state: interpolate tbl_fuel_row_mult_lo40 (@605A, 40 x 16-bit,
;    ~0776h.. values) / tbl_fuel_row_mult_hi40 (@6082) at row 0EEh/0EFh, scalar X1=0CAh/0CCh.
;    (p13info 'scalar? or multiplier? 16bit' at 605A/6082 -- it is the row-multiplier row feeding the
;    fuel calc; result kept in r0/0E9h area and used with the map value below.)
                MOV     DP, #tbl_fuel_row_mult_hi40          ; 2972 0 100 280 628260
                MOV     X1, 0cch               ; 2975 0 100 280 B5CC78
                LB      A, 0efh                ; 2978 0 100 280 F5EF
                J       vtec_state_store_if_ram11d_bit1_set             ; 297A 0 100 280 038029
                DB  0EFh,02Eh,00Bh ; 297D
vtec_state_store_if_ram11d_bit1_set:     JBS     off(0011dh).1, vtec_state_store_call_48d2 ; 2980 0 100 280 E91D08
                MOV     DP, #tbl_fuel_row_mult_lo40          ; 2983 0 100 280 625A60
                MOV     X1, 0cah               ; 2986 0 100 280 B5CA78
                LB      A, 0eeh                ; 2989 0 100 280 F5EE
vtec_state_store_call_48d2:     CAL     vtec_state_store_sub_clear_acch             ; 298B 0 100 280 32D248
                MOVB    r0, 0e9h               ; 298E 0 100 280 C5E948
                JBS     off(00119h).0, vtec_state_store_clear_ram12d_bit3 ; 2991 0 100 280 E8190F
                LB      A, #006h               ; 2994 0 100 280 7706
                CMPB    A, r0                  ; 2996 0 100 280 48
                MB      off(0012dh).3, C       ; 2997 0 100 280 C42D3B
                LB      A, #00ah               ; 299A 0 100 280 770A
                CMPB    A, r0                  ; 299C 0 100 280 48
                MB      off(0012dh).4, C       ; 299D 0 100 280 C42D3C
                RC                             ; 29A0 0 100 280 95
                SJ      vtec_state_store_store_carry_ram12d_bit2             ; 29A1 0 100 280 CB09
vtec_state_store_clear_ram12d_bit3:     RB      off(0012dh).3          ; 29A3 0 100 280 C42D0B
                RB      off(0012dh).4          ; 29A6 0 100 280 C42D0C
                LB      A, #005h               ; 29A9 0 100 280 7705
                CMPB    A, r0                  ; 29AB 0 100 280 48
vtec_state_store_store_carry_ram12d_bit2:     MB      off(0012dh).2, C       ; 29AC 0 100 280 C42D3A
                JBS     off(0011ah).6, tipin_gate_common_clear_acc ; 29AF 0 100 280 EE1A44
                JBS     off(0011dh).0, tipin_gate_common_clear_acc ; 29B2 0 100 280 E81D41
                JBS     off(00114h).0, tipin_gate_common_clear_acc ; 29B5 0 100 280 E8143E
                JBR     off(0012dh).2, accelenrich_clear_pulse_check ; 29B8 0 100 280 DA2D1A
                JBR     off(00119h).1, tipin_gate_common_load_ram146 ; 29BB 0 100 280 D9193E
                JBR     off(0012dh).5, vtec_state_store_load_imm ; 29BE 0 100 280 DD2D54
                CMPB    0e1h, #0d0h            ; 29C1 0 100 280 C5E1C0D0
                JGE     tipin_gate_common_clear_acc             ; 29C5 0 100 280 CD2F
                CMPB    0e7h, #09ah            ; 29C7 0 100 280 C5E7C09A
                JGE     tipin_gate_common_clear_acc             ; 29CB 0 100 280 CD29
                CAL     accelenrich_base_calc             ; 29CD 0 100 280 325049
                RB      off(0012eh).1          ; 29D0 0 100 280 C42E09
                SJ      tipin_gate_common_clear_ram182             ; 29D3 0 100 280 CB4F
accelenrich_clear_pulse_check:     JBR     off(0012dh).4, accelenrich_clear_pulse_check_cmp_ram179 ; 29D5 0 100 280 DC2D03
                CLR     off(00146h)            ; 29D8 0 100 280 B44615
accelenrich_clear_pulse_check_cmp_ram179:     CMPB    off(00179h), #053h     ; 29DB 0 100 280 C479C053
                JLT     tipin_gate_common_load_ram146             ; 29DF 0 100 280 CA1B
                JBR     off(0012dh).3, tipin_gate_common ; 29E1 0 100 280 DB2D08
                JBR     off(00119h).1, tipin_gate_common ; 29E4 0 100 280 D91905
                CAL     accelenrich_clear_pulse_check_sub_load_x1             ; 29E7 0 100 280 323349
                SJ      tipin_gate_common_store_ram182             ; 29EA 0 100 280 CB0B
tipin_gate_common:     LB      A, off(00182h)         ; 29EC 0 100 280 F482
                JEQ     tipin_gate_common_load_ram146             ; 29EE 0 100 280 C90C
                ADDB    A, #002h               ; 29F0 0 100 280 8602
                JLT     tipin_gate_common_load_ram146             ; 29F2 0 100 280 CA08
                SJ      tipin_gate_common_store_ram182             ; 29F4 0 100 280 CB01
tipin_gate_common_clear_acc:     CLRB    A                      ; 29F6 0 100 280 FA
tipin_gate_common_store_ram182:     STB     A, off(00182h)         ; 29F7 0 100 280 D482
                CLR     A                      ; 29F9 1 100 280 F9
                SJ      tipin_gate_common_store_ram146             ; 29FA 1 100 280 CB2B
tipin_gate_common_load_ram146:     L       A, off(00146h)         ; 29FC 1 100 280 E446
                JEQ     tipin_gate_common_clear_ram182             ; 29FE 1 100 280 C924
                CMP     A, #00000h             ; 2A00 1 100 280 C60000
                MOV     er0, #00093h           ; 2A03 1 100 280 44989300
                JLT     tipin_gate_common_sub_acc             ; 2A07 1 100 280 CA04
                MOV     er0, #00093h           ; 2A09 1 100 280 44989300
tipin_gate_common_sub_acc:     SUB     A, er0                 ; 2A0D 1 100 280 28
                JLT     tipin_gate_common_clear_acc             ; 2A0E 1 100 280 CAE6
                SB      off(0012eh).1          ; 2A10 1 100 280 C42E19
                SJ      tipin_gate_common_clear_ram182             ; 2A13 1 100 280 CB0F
vtec_state_store_load_imm:     LB      A, #006h               ; 2A15 0 100 280 7706
                CMPB    A, 0f0h                ; 2A17 0 100 280 C5F0C2
                JLT     vtec_state_store_load_ram18e             ; 2A1A 0 100 280 CA03
                JBS     off(0012eh).1, tipin_gate_common_load_ram146 ; 2A1C 0 100 280 E92EDD
vtec_state_store_load_ram18e:     LB      A, off(0018eh)         ; 2A1F 0 100 280 F48E
                CAL     accelenrich_rpm_tier1_clear_acch             ; 2A21 0 100 280 326B49
tipin_gate_common_clear_ram182:     CLRB    off(00182h)            ; 2A24 0 100 280 C48215
tipin_gate_common_store_ram146:     STB     A, off(00146h)         ; 2A27 0 100 280 D446
                CMPB    A, #001h               ; 2A29 0 100 280 C601
                NOP                            ; 2A2B 0 100 280 00
                MB      off(0012dh).5, C       ; 2A2C 0 100 280 C42D3D
                JBS     off(00116h).1, Cranking ; 2A2F 0 100 280 E91603
                J       tipin_gate_common_clear_ram09f_bit1             ; 2A32 0 100 280 031B2B
Cranking:     MOV     X1, #0537ah            ; 2A35 0 100 280 607A53
                LB      A, 0d9h                ; 2A38 0 100 280 F5D9
                VCAL    1                      ; 2A3A 0 100 280 11
                STB     A, off(0013eh)         ; 2A3B 0 100 280 D43E
                MOV     X1, #Cranking_tbl          ; 2A3D 0 100 280 602A6A
                L       A, 0aeh                ; 2A40 1 100 280 E5AE
                CAL     idleign_table_lookup_sub_load_acc             ; 2A42 1 100 280 324644
                LB      A, r6                  ; 2A45 0 100 280 7E
                STB     A, off(00180h)         ; 2A46 0 100 280 D480
                MOV     X1, #05393h            ; 2A48 0 100 280 609353
                LB      A, 0e0h                ; 2A4B 0 100 280 F5E0
                VCAL    2                      ; 2A4D 0 100 280 12
                STB     A, off(00183h)         ; 2A4E 0 100 280 D483
                MOVB    r0, off(00180h)        ; 2A50 0 100 280 C48048
                MULB                           ; 2A53 0 100 280 A234
                L       A, ACC                 ; 2A55 1 100 280 E506
                MOV     er0, off(0013eh)       ; 2A57 1 100 280 B43E48
                MUL                            ; 2A5A 1 100 280 9035
                SLL     A                      ; 2A5C 1 100 280 53
                ROL     er1                    ; 2A5D 1 100 280 45B7
                JLT     Cranking_load_imm             ; 2A5F 1 100 280 CA05
                SLL     A                      ; 2A61 1 100 280 53
                L       A, er1                 ; 2A62 1 100 280 35
                ROL     A                      ; 2A63 1 100 280 33
                JGE     Cranking_add_acc             ; 2A64 1 100 280 CD03
Cranking_load_imm:     L       A, #0ffffh             ; 2A66 1 100 280 67FFFF
Cranking_add_acc:     ADD     A, off(00146h)         ; 2A69 1 100 280 8746
                JGE     Cranking_load_carry_ram09f_bit1             ; 2A6B 1 100 280 CD03
                L       A, #0ffffh             ; 2A6D 1 100 280 67FFFF
Cranking_load_carry_ram09f_bit1:     MB      C, 09fh.1              ; 2A70 1 100 280 C59F29
                JGE     crankfuel_add_adjust             ; 2A73 1 100 280 CD02
                SRL     A                      ; 2A75 1 100 280 63
                SRL     A                      ; 2A76 1 100 280 63
crankfuel_add_adjust:     ADD     A, off(00142h)         ; 2A77 1 100 280 8742
                JGE     crankfuel_add_adjust_load_dp             ; 2A79 1 100 280 CD03
                L       A, #0ffffh             ; 2A7B 1 100 280 67FFFF
crankfuel_add_adjust_load_dp:     MOV     DP, #00382h            ; 2A7E 1 100 280 628203
                ST      A, [DP]                ; 2A81 1 100 280 D2
                INC     DP                     ; 2A82 1 100 280 72
                INC     DP                     ; 2A83 1 100 280 72
                RB      PSWH.0                 ; 2A84 1 100 280 A208
                ST      A, [DP]                ; 2A86 1 100 280 D2
                INC     DP                     ; 2A87 1 100 280 72
                INC     DP                     ; 2A88 1 100 280 72
                ST      A, [DP]                ; 2A89 1 100 280 D2
                INC     DP                     ; 2A8A 1 100 280 72
                INC     DP                     ; 2A8B 1 100 280 72
                ST      A, [DP]                ; 2A8C 1 100 280 D2
                INC     DP                     ; 2A8D 1 100 280 72
                INC     DP                     ; 2A8E 1 100 280 72
                ST      A, [DP]                ; 2A8F 1 100 280 D2
                SB      PSWH.0                 ; 2A90 1 100 280 A218
                JBR     off(00111h).6, crankfuel_add_adjust_if_ram110_bit7_set ; 2A92 1 100 280 DE1105
                SB      off(0011ah).0          ; 2A95 1 100 280 C41A18
                SJ      postfuel_calc_start             ; 2A98 1 100 280 CB2A
crankfuel_add_adjust_if_ram110_bit7_set:     JBS     off(00110h).7, crankfuel_add_adjust_if_ram111_bit0_set ; 2A9A 1 100 280 EF1003
                JBR     off(00127h).6, crankfuel_add_adjust_load_carry_ram09f_bit1 ; 2A9D 1 100 280 DE2706
crankfuel_add_adjust_if_ram111_bit0_set:     JBS     off(00111h).0, postfuel_calc_start ; 2AA0 1 100 280 E81121
                JBS     off(00127h).7, postfuel_calc_start ; 2AA3 1 100 280 EF271E
crankfuel_add_adjust_load_carry_ram09f_bit1:     MB      C, 09fh.1              ; 2AA6 1 100 280 C59F29
                JLT     crankfuel_add_adjust_load_dp_2             ; 2AA9 1 100 280 CA0C
                CMPB    off(0019dh), #004h     ; 2AAB 1 100 280 C49DC004
                JNE     postfuel_calc_start             ; 2AAF 1 100 280 CE13
                CMPB    0d9h, #0eah            ; 2AB1 1 100 280 C5D9C0EA
                JGE     postfuel_calc_start             ; 2AB5 1 100 280 CD0D
crankfuel_add_adjust_load_dp_2:     MOV     DP, #0004ch            ; 2AB7 1 100 280 624C00
                ST      A, [DP]                ; 2ABA 1 100 280 D2
                INC     DP                     ; 2ABB 1 100 280 72
                INC     DP                     ; 2ABC 1 100 280 72
                ST      A, [DP]                ; 2ABD 1 100 280 D2
                INC     DP                     ; 2ABE 1 100 280 72
                INC     DP                     ; 2ABF 1 100 280 72
                ST      A, [DP]                ; 2AC0 1 100 280 D2
                INC     DP                     ; 2AC1 1 100 280 72
                INC     DP                     ; 2AC2 1 100 280 72
                ST      A, [DP]                ; 2AC3 1 100 280 D2
postfuel_calc_start:     SB      off(0011dh).4          ; 2AC4 1 100 280 C41D1C
                LB      A, 0d9h                ; 2AC7 0 100 280 F5D9
                CMPB    A, #0c8h               ; 2AC9 0 100 280 C6C8
                MB      PSWL.5, C              ; 2ACB 0 100 280 A33D
                MOV     X1, #0522ah            ; 2ACD 0 100 280 602A52
                VCAL    1                      ; 2AD0 0 100 280 11
                STB     A, off(00158h)         ; 2AD1 0 100 280 D458
                CLRB    off(00157h)            ; 2AD3 0 100 280 C45715
                MOV     er2, #02000h           ; 2AD6 0 100 280 46980020
                SUBB    A, r2                  ; 2ADA 0 100 280 2A
                STB     A, r3                  ; 2ADB 0 100 280 8B
                CLRB    r0                     ; 2ADC 0 100 280 2015
                MOVB    r1, #0b3h              ; 2ADE 0 100 280 99B3
                MB      C, PSWL.5              ; 2AE0 0 100 280 A32D
                JLT     postfuel_hyst_upper_calc             ; 2AE2 0 100 280 CA02
                MOVB    r1, #080h              ; 2AE4 0 100 280 9980
postfuel_hyst_upper_calc:     MUL                            ; 2AE6 0 100 280 9035
                L       A, er1                 ; 2AE8 1 100 280 35
                ADD     A, er2                 ; 2AE9 1 100 280 0A
                ST      A, off(0015ah)         ; 2AEA 1 100 280 D45A
                L       A, er3                 ; 2AEC 1 100 280 37
                MOVB    r1, #066h              ; 2AED 1 100 280 9966
                MB      C, PSWL.5              ; 2AEF 1 100 280 A32D
                JLT     postfuel_hyst_lower_calc             ; 2AF1 1 100 280 CA02
                MOVB    r1, #04ch              ; 2AF3 1 100 280 994C
postfuel_hyst_lower_calc:     MUL                            ; 2AF5 1 100 280 9035
                L       A, er1                 ; 2AF7 1 100 280 35
                ADD     A, er2                 ; 2AF8 1 100 280 0A
                ST      A, off(0015ch)         ; 2AF9 1 100 280 D45C
                LB      A, off(0017bh)         ; 2AFB 0 100 280 F47B
                MOVB    r0, A                  ; 2AFD 0 100 280 208A
                LB      A, #066h               ; 2AFF 0 100 280 7766
                MULB                           ; 2B01 0 100 280 A234
                L       A, ACC                 ; 2B03 1 100 280 E506
                SLL     A                      ; 2B05 1 100 280 53
                LB      A, ACCH                ; 2B06 0 100 280 F507
                JGE     postfuel_hyst_lower_calc_cmp_acc             ; 2B08 0 100 280 CD02
                LB      A, #0ffh               ; 2B0A 0 100 280 77FF
postfuel_hyst_lower_calc_cmp_acc:     CMPB    A, #040h               ; 2B0C 0 100 280 C640
                JGE     accel_iac_store             ; 2B0E 0 100 280 CD02
                LB      A, #040h               ; 2B10 0 100 280 7740
accel_iac_store:     STB     A, off(00181h)         ; 2B12 0 100 280 D481
                MOVB    off(0019fh), #057h     ; 2B14 0 100 280 C49F9857
                J       accel_iac_store_if_ram11e_bit1_set             ; 2B18 0 100 280 03B233
tipin_gate_common_clear_ram09f_bit1:     RB      09fh.1                 ; 2B1B 0 100 280 C59F09
                JBR     off(0011dh).4, tipin_gate_common_load_ram181 ; 2B1E 0 100 280 DC1D4F
                L       A, #07000h                                         ; 2B21 1 100 280 670070
                CMPB    off(00159h), #02ah     ; 2B24 1 100 280 C459C02A
                JLE     tipin_gate_common_load_imm             ; 2B28 1 100 280 CF06
                CMP     off(00158h), off(0015ah) ; 2B2A 1 100 280 B458C35A
                JGT     tipin_gate_common_subb_ram157             ; 2B2E 1 100 280 C80C
tipin_gate_common_load_imm:     L       A, #00b00h             ; 2B30 1 100 280 67000B
                CMP     off(00158h), off(0015ch) ; 2B33 1 100 280 B458C35C
                JGT     tipin_gate_common_subb_ram157             ; 2B37 1 100 280 C803
                L       A, #00340h             ; 2B39 1 100 280 674003
tipin_gate_common_subb_ram157:     SUBB    off(00157h), A         ; 2B3C 1 100 280 C457A1
                CLRB    A                      ; 2B3F 0 100 280 FA
                L       A, ACC                 ; 2B40 1 100 280 E506
                SWAP                           ; 2B42 1 100 280 83
                MOV     er0, off(00158h)       ; 2B43 1 100 280 B45848
                SBC     er0, A                 ; 2B46 1 100 280 44B1
                CMP     er0, #02000h           ; 2B48 1 100 280 44C00020
                JLE     tipin_gate_common_clear_ram11d_bit4             ; 2B4C 1 100 280 CF1F
                MOV     off(00158h), er0       ; 2B4E 1 100 280 447C58
                LB      A, 0d9h                ; 2B51 0 100 280 F5D9
                CMPB    A, #02eh               ; 2B53 0 100 280 C62E
                L       A, off(00158h)         ; 2B55 1 100 280 E458
                JLT     tipin_gate_common_store_ram15e             ; 2B57 1 100 280 CA20
                JBR     off(00124h).0, tipin_gate_common_store_ram15e ; 2B59 1 100 280 D8241D
                CLRB    r0                     ; 2B5C 1 100 280 2015
                MOVB    r1, #08dh              ; 2B5E 1 100 280 998D
                MUL                            ; 2B60 1 100 280 9035
                SLL     A                      ; 2B62 1 100 280 53
                ROL     er1                    ; 2B63 1 100 280 45B7
                L       A, er1                 ; 2B65 1 100 280 35
                JGE     tipin_gate_common_store_ram15e             ; 2B66 1 100 280 CD11
                L       A, #0ffffh             ; 2B68 1 100 280 67FFFF
                SJ      tipin_gate_common_store_ram15e             ; 2B6B 1 100 280 CB0C
tipin_gate_common_clear_ram11d_bit4:     RB      off(0011dh).4          ; 2B6D 1 100 280 C41D0C
tipin_gate_common_load_ram181:     MOVB    off(00181h), #040h     ; 2B70 0 100 280 C4819840
                L       A, #02000h             ; 2B74 1 100 280 670020
                ST      A, off(00158h)         ; 2B77 1 100 280 D458
tipin_gate_common_store_ram15e:     ST      A, off(0015eh)         ; 2B79 1 100 280 D45E
                MOVB    r6, #080h              ; 2B7B 1 100 280 9E80
                JBR     off(00118h).4, tipin_gate_common_load_r6 ; 2B7D 1 100 280 DC1840
                J       tipin_gate_common_if_ram11d_bit1_set             ; 2B80 1 100 280 03862B
                DB  0EFh,02Eh,01Bh ; 2B83
tipin_gate_common_if_ram11d_bit1_set:     JBS     off(0011dh).1, tipin_gate_common_load_ram0ef ; 2B86 1 100 280 E91D18
                LB      A, 0eeh                ; 2B89 0 100 280 F5EE
                CMPB    A, #00eh               ; 2B8B 0 100 280 C60E
                JGE     tipin_gate_common_load_r6             ; 2B8D 0 100 280 CD31
                SUBB    A, #004h               ; 2B8F 0 100 280 A604
                JLT     tipin_gate_common_load_r6             ; 2B91 0 100 280 CA2D
                MOV     DP, #tbl_corr_map_a_623a          ; 2B93 0 100 280 623A62
                JBS     off(00120h).0, tipin_gate_common_load_x1 ; 2B96 0 100 280 E82003
                MOV     DP, #tbl_corr_map_b_62a8          ; 2B99 0 100 280 62A862
tipin_gate_common_load_x1:     MOV     X1, 0cah               ; 2B9C 0 100 280 B5CA78
                SJ      tipin_gate_common_load_r1             ; 2B9F 0 100 280 CB16
tipin_gate_common_load_ram0ef:     LB      A, 0efh                ; 2BA1 0 100 280 F5EF
                CMPB    A, #00eh               ; 2BA3 0 100 280 C60E
                JGE     tipin_gate_common_load_r6             ; 2BA5 0 100 280 CD19
                SUBB    A, #004h               ; 2BA7 0 100 280 A604
                JLT     tipin_gate_common_load_r6             ; 2BA9 0 100 280 CA15
                MOV     DP, #tbl_corr_map_c_6316          ; 2BAB 0 100 280 621663
                JBS     off(00120h).0, tipin_gate_common_load_x1_2 ; 2BAE 0 100 280 E82003
                MOV     DP, #tbl_corr_map_d_6384          ; 2BB1 0 100 280 628463
tipin_gate_common_load_x1_2:     MOV     X1, 0cch               ; 2BB4 0 100 280 B5CC78
tipin_gate_common_load_r1:     MOVB    r1, 0edh               ; 2BB7 0 100 280 C5ED49
                MOV     X2, 0c6h               ; 2BBA 0 100 280 B5C679
                CAL     tipin_gate_common_sub_load_r0             ; 2BBD 0 100 280 324545
tipin_gate_common_load_r6:     LB      A, r6                  ; 2BC0 0 100 280 7E
                STB     A, off(0018fh)         ; 2BC1 0 100 280 D48F
                LB      A, #0bah               ; 2BC3 0 100 280 77BA
                JBS     off(00130h).4, tipin_gate_common_cmp_acc ; 2BC5 0 100 280 EC3002
                LB      A, #0c0h               ; 2BC8 0 100 280 77C0
tipin_gate_common_cmp_acc:     CMPB    A, off(00179h)         ; 2BCA 0 100 280 C779
                MB      off(00130h).4, C       ; 2BCC 0 100 280 C4303C
                LB      A, #01dh               ; 2BCF 0 100 280 771D
                JBR     off(00130h).6, tipin_gate_common_cmp_acc_2 ; 2BD1 0 100 280 DE3002
                LB      A, #01bh               ; 2BD4 0 100 280 771B
tipin_gate_common_cmp_acc_2:     CMPB    A, 0d9h                ; 2BD6 0 100 280 C5D9C2
                MB      off(00130h).6, C       ; 2BD9 0 100 280 C4303E
                LB      A, #017h               ; 2BDC 0 100 280 7717
                JBR     off(00130h).5, tipin_gate_common_cmp_acc_3 ; 2BDE 0 100 280 DD3002
                LB      A, #014h               ; 2BE1 0 100 280 7714
tipin_gate_common_cmp_acc_3:     CMPB    A, 0d9h                ; 2BE3 0 100 280 C5D9C2
                MB      off(00130h).5, C       ; 2BE6 0 100 280 C4303D
                LB      A, off(00179h)         ; 2BE9 0 100 280 F479
                CMPB    A, #040h               ; 2BEB 0 100 280 C640
                MB      off(00130h).7, C       ; 2BED 0 100 280 C4303F
                MOV     X1, #05267h            ; 2BF0 0 100 280 606752
                VCAL    0                      ; 2BF3 0 100 280 10
                JBS     off(00130h).7, tipin_gate_common_store_r2 ; 2BF4 0 100 280 EF3034
                JBS     off(00130h).5, tipin_gate_common_subb_acc ; 2BF7 0 100 280 ED300A
                LB      A, #050h               ; 2BFA 0 100 280 7750
                XCHGB   A, r6                  ; 2BFC 0 100 280 2610
                SUBB    A, r6                  ; 2BFE 0 100 280 2E
                JGE     tipin_gate_common_store_r2             ; 2BFF 0 100 280 CD2A
                CLRB    A                      ; 2C01 0 100 280 FA
                SJ      tipin_gate_common_store_r2             ; 2C02 0 100 280 CB27
tipin_gate_common_subb_acc:     SUBB    A, off(0019ah)         ; 2C04 0 100 280 A79A
                JGE     tipin_gate_common_if_ram11f_bit5_clr             ; 2C06 0 100 280 CD01
                CLRB    A                      ; 2C08 0 100 280 FA
tipin_gate_common_if_ram11f_bit5_clr:     JBR     off(0011fh).5, tipin_gate_common_store_r2 ; 2C09 0 100 280 DD1F1F
                JBR     off(00130h).4, tipin_gate_common_store_r2 ; 2C0C 0 100 280 DC301C
                STB     A, r2                  ; 2C0F 0 100 280 8A
                JBS     off(00115h).6, tipin_gate_common_load_imm_2 ; 2C10 0 100 280 EE1510
                JBR     off(00130h).6, tipin_gate_common_load_imm_2 ; 2C13 0 100 280 DE300D
                LB      A, off(00179h)         ; 2C16 0 100 280 F479
                MOV     X1, #05277h            ; 2C18 0 100 280 607752
                VCAL    0                      ; 2C1B 0 100 280 10
                SUBB    A, off(0019ah)         ; 2C1C 0 100 280 A79A
                JGE     tipin_gate_common_load_ram1b7             ; 2C1E 0 100 280 CD0C
                CLRB    A                      ; 2C20 0 100 280 FA
                SJ      tipin_gate_common_load_ram1b7             ; 2C21 0 100 280 CB09
tipin_gate_common_load_imm_2:     LB      A, #040h               ; 2C23 0 100 280 7740
                XCHGB   A, r2                  ; 2C25 0 100 280 2210
                SUBB    A, r2                  ; 2C27 0 100 280 2A
                JGE     tipin_gate_common_store_r2             ; 2C28 0 100 280 CD01
                CLRB    A                      ; 2C2A 0 100 280 FA
tipin_gate_common_store_r2:     STB     A, r2                  ; 2C2B 0 100 280 8A
tipin_gate_common_load_ram1b7:     MOVB    off(001b7h), r2        ; 2C2C 0 100 280 227CB7
                STB     A, r3                  ; 2C2F 0 100 280 8B
                LB      A, #008h               ; 2C30 0 100 280 7708
                STB     A, r4                  ; 2C32 0 100 280 8C
                LB      A, r3                  ; 2C33 0 100 280 7B
                SUBB    A, r4                  ; 2C34 0 100 280 2C
                JGE     tipin_gate_common_store_ram1b9             ; 2C35 0 100 280 CD01
                CLRB    A                      ; 2C37 0 100 280 FA
tipin_gate_common_store_ram1b9:     STB     A, off(001b9h)         ; 2C38 0 100 280 D4B9
                CMPB    A, off(00178h)         ; 2C3A 0 100 280 C778
                MB      off(0011ch).6, C       ; 2C3C 0 100 280 C41C3E
                LB      A, #010h               ; 2C3F 0 100 280 7710
                STB     A, r4                  ; 2C41 0 100 280 8C
                LB      A, off(00179h)         ; 2C42 0 100 280 F479
                MOV     X1, #tbl_inj_pw_volt_6911          ; 2C44 0 100 280 601169
                VCAL    0                      ; 2C47 0 100 280 10
                JBR     off(0011ch).4, tipin_gate_common_cmp_acc_4 ; 2C48 0 100 280 DC1C05
                LB      A, #005h               ; 2C4B 0 100 280 7705
                XCHGB   A, r6                  ; 2C4D 0 100 280 2610
                SUBB    A, r6                  ; 2C4F 0 100 280 2E
tipin_gate_common_cmp_acc_4:     CMPB    A, 0abh                ; 2C50 0 100 280 C5ABC2
                JLT     tipin_gate_common_clear_ram1e5             ; 2C53 0 100 280 CA1C
                LB      A, r2                  ; 2C55 0 100 280 7A
                JBR     off(0011ch).4, tipin_gate_common_cmp_acc_5 ; 2C56 0 100 280 DC1C04
                SUBB    A, r4                  ; 2C59 0 100 280 2C
                JGE     tipin_gate_common_cmp_acc_5             ; 2C5A 0 100 280 CD01
                CLRB    A                      ; 2C5C 0 100 280 FA
tipin_gate_common_cmp_acc_5:     CMPB    A, off(00178h)         ; 2C5D 0 100 280 C778
                JLT     tipin_gate_common_if_ram130_bit4_set             ; 2C5F 0 100 280 CA06
                LB      A, #005h               ; 2C61 0 100 280 7705
                STB     A, off(001e5h)         ; 2C63 0 100 280 D4E5
                SJ      tipin_gate_common_store_carry_ram11c_bit4             ; 2C65 0 100 280 CB0E
tipin_gate_common_if_ram130_bit4_set:     JBS     off(00130h).4, tipin_gate_common_clear_ram1e5 ; 2C67 0 100 280 EC3007
                LB      A, off(001e5h)         ; 2C6A 0 100 280 F4E5
                JEQ     tipin_gate_common_set_carry             ; 2C6C 0 100 280 C906
                RC                             ; 2C6E 0 100 280 95
                SJ      tipin_gate_common_store_carry_ram11c_bit4             ; 2C6F 0 100 280 CB04
tipin_gate_common_clear_ram1e5:     CLRB    off(001e5h)            ; 2C71 0 100 280 C4E515
tipin_gate_common_set_carry:     SC                             ; 2C74 0 100 280 85
tipin_gate_common_store_carry_ram11c_bit4:     MB      off(0011ch).4, C       ; 2C75 0 100 280 C41C3C
                NOP                            ; 2C78 0 100 280 00
                NOP                            ; 2C79 0 100 280 00
                NOP                            ; 2C7A 0 100 280 00
                LB      A, r3                  ; 2C7B 0 100 280 7B
                JBR     off(0011dh).5, tipin_gate_common_store_ram1b8 ; 2C7C 0 100 280 DD1D04
                SUBB    A, r4                  ; 2C7F 0 100 280 2C
                JGE     tipin_gate_common_store_ram1b8             ; 2C80 0 100 280 CD01
                CLRB    A                      ; 2C82 0 100 280 FA
tipin_gate_common_store_ram1b8:     STB     A, off(001b8h)         ; 2C83 0 100 280 D4B8
                CMPB    A, off(00178h)         ; 2C85 0 100 280 C778
                CAL     tipin_gate_common_sub_store_carry_ram11d_bit5             ; 2C87 0 100 280 329070
                SC                             ; 2C8A 0 100 280 85
                JBR     off(0011fh).5, tipin_gate_common_store_carry_ram11c_bit7 ; 2C8B 0 100 280 DD1F59
                JBS     off(00115h).6, tipin_gate_common_store_carry_ram11c_bit7 ; 2C8E 0 100 280 EE1556
                MOVB    r4, #0ffh              ; 2C91 0 100 280 9CFF
                J       tipin_gate_common_if_ram130_bit6_set               ; 2C93 0 100 280 030070
tipin_gate_common_if_ram11c_bit6_set:     JBS     off(0011ch).6, tipin_gate_common_load_ram1db ; 2C96 0 100 280 EE1C1A
                RB      off(00131h).0          ; 2C99 0 100 280 C43108
                JEQ     tipin_gate_common_clear_ram1d9             ; 2C9C 0 100 280 C904
                MOVB    off(001dah), off(001d9h) ; 2C9E 0 100 280 C4D97CDA
tipin_gate_common_clear_ram1d9:     CLRB    off(001d9h)            ; 2CA2 0 100 280 C4D915
                RC                             ; 2CA5 0 100 280 95
                SJ      tipin_gate_common_store_carry_ram11c_bit7             ; 2CA6 0 100 280 CB3F
tipin_gate_common_set_ram131_bit0:     SB      off(00131h).0          ; 2CA8 0 100 280 C43118
                CLRB    off(001dbh)            ; 2CAB 0 100 280 C4DB15
                MOVB    off(001d9h), r4        ; 2CAE 0 100 280 247CD9
                SJ      tipin_gate_common_store_carry_ram11c_bit7             ; 2CB1 0 100 280 CB34
tipin_gate_common_load_ram1db:     LB      A, off(001dbh)         ; 2CB3 0 100 280 F4DB
                SB      off(00131h).0          ; 2CB5 0 100 280 C43118
                JNE     tipin_gate_common_clear_ram1d8             ; 2CB8 0 100 280 CE24
                CLR     A                      ; 2CBA 1 100 280 F9
                LB      A, off(001d8h)         ; 2CBB 0 100 280 F4D8
                MOV     er0, A                 ; 2CBD 0 100 280 448A
                LB      A, off(001dah)         ; 2CBF 0 100 280 F4DA
                MOV     er1, A                 ; 2CC1 0 100 280 458A
                LB      A, off(001dbh)         ; 2CC3 0 100 280 F4DB
                L       A, ACC                 ; 2CC5 1 100 280 E506
                ADD     A, er0                 ; 2CC7 1 100 280 08
                SUB     A, er1                 ; 2CC8 1 100 280 29
                MB      PSWL.4, C              ; 2CC9 1 100 280 A33C
                LB      A, ACC                 ; 2CCB 0 100 280 F506
                CMPB    ACCH, #000h            ; 2CCD 0 100 280 C507C000
                JEQ     tipin_gate_common_cmp_acc_6             ; 2CD1 0 100 280 C905
                CLRB    A                      ; 2CD3 0 100 280 FA
                MB      C, PSWL.4              ; 2CD4 0 100 280 A32C
                ADCB    A, #0ffh               ; 2CD6 0 100 280 96FF
tipin_gate_common_cmp_acc_6:     CMPB    A, r4                  ; 2CD8 0 100 280 4C
                JLT     tipin_gate_common_store_ram1db             ; 2CD9 0 100 280 CA01
                LB      A, r4                  ; 2CDB 0 100 280 7C
tipin_gate_common_store_ram1db:     STB     A, off(001dbh)         ; 2CDC 0 100 280 D4DB
tipin_gate_common_clear_ram1d8:     CLRB    off(001d8h)            ; 2CDE 0 100 280 C4D815
                CMPB    off(001d9h), A         ; 2CE1 0 100 280 C4D9C1
                XORB    PSWH, #080h            ; 2CE4 0 100 280 A2F080
tipin_gate_common_store_carry_ram11c_bit7:     MB      off(0011ch).7, C       ; 2CE7 0 100 280 C41C3F
                LB      A, #080h               ; 2CEA 0 100 280 7780
                JBS     off(00118h).4, tipin_gate_common_store_ram193 ; 2CEC 0 100 280 EC181C
;  [flow] main fuel map lookup: profile by 021Dh.1 -> tbl_fuel_hi_cam (@6172) or tbl_fuel_lo_cam
;    (@60AA) [p13info 'Low/High Cam Fuel Table' confirmed @60AA/6172]. Index: row = 0EEh/0EFh,
;    X1 = scalar 0CAh/0CCh, column r1 = 0EDh with fraction scalar X2 = 0C6h, CAL 4545 interpolates,
;    result = base fuel byte -> 0193h. Below: 2D17+ applies a correction map (tbl_corr_map_lo/hi
;    6A77/6A8B or the all-FF tables 6923/6937), multipliers 0199h/02BAh, final base pulse -> 0183h
;    clamped by tbl_inj_pw_volt_6911 (voltage vs pw 2-word pairs @6911, p13info did not cover it).
                LB      A, 0efh                ; 2CEF 0 100 280 F5EF
                MOV     X1, 0cch               ; 2CF1 0 100 280 B5CC78
                MOV     DP, #tbl_fuel_hi_cam          ; 2CF4 0 100 280 627261
                JBS     off(0011dh).1, tipin_gate_common_load_r1_2 ; 2CF7 0 100 280 E91D08
                LB      A, 0eeh                ; 2CFA 0 100 280 F5EE
                MOV     X1, 0cah               ; 2CFC 0 100 280 B5CA78
                MOV     DP, #tbl_fuel_lo_cam          ; 2CFF 0 100 280 62AA60
tipin_gate_common_load_r1_2:     MOVB    r1, 0edh               ; 2D02 0 100 280 C5ED49
                MOV     X2, 0c6h               ; 2D05 0 100 280 B5C679
                CAL     tipin_gate_common_sub_load_r0             ; 2D08 0 100 280 324545
tipin_gate_common_store_ram193:     STB     A, off(00193h)         ; 2D0B 0 100 280 D493
                SRLB    A                      ; 2D0D 0 100 280 63
                JBS     off(0011dh).0, tipin_gate_common_clear_ram11c_bit3 ; 2D0E 0 100 280 E81D37
                JBR     off(0011ch).5, tipin_gate_common_clear_ram11c_bit3 ; 2D11 0 100 280 DD1C34
                JBR     off(0011ch).4, tipin_gate_common_if_ram11c_bit7_clr ; 2D14 0 100 280 DC1C25
                JBS     off(0011ch).7, tipin_gate_common_set_ram11c_bit3 ; 2D17 0 100 280 EF1C25
                JBR     off(00130h).6, tipin_gate_common_set_ram11c_bit3 ; 2D1A 0 100 280 DE3022
                MOV     DP, #tbl_allff_6923          ; 2D1D 0 100 280 622369
                MOV     X1, 0cch               ; 2D20 0 100 280 B5CC78
                LB      A, 0efh                ; 2D23 0 100 280 F5EF
                JBS     off(0011dh).1, tipin_gate_common_call_4523 ; 2D25 0 100 280 E91D08
                MOV     DP, #tbl_allff_6937          ; 2D28 0 100 280 623769
                MOV     X1, 0cah               ; 2D2B 0 100 280 B5CA78
                LB      A, 0eeh                ; 2D2E 0 100 280 F5EE
tipin_gate_common_call_4523:     CAL     scale_result_common_sub_extnd_acc             ; 2D30 0 100 280 322345
                MOVB    r0, off(00193h)        ; 2D33 0 100 280 C49348
                MULB                           ; 2D36 0 100 280 A234
                LB      A, ACCH                ; 2D38 0 100 280 F507
                SJ      tipin_gate_common_set_ram11c_bit3             ; 2D3A 0 100 280 CB03
tipin_gate_common_if_ram11c_bit7_clr:     JBR     off(0011ch).7, tipin_gate_common_clear_ram11c_bit3 ; 2D3C 0 100 280 DF1C09
tipin_gate_common_set_ram11c_bit3:     SB      off(0011ch).3          ; 2D3F 0 100 280 C41C1B
                CMPB    A, off(0017bh)         ; 2D42 0 100 280 C77B
                JGT     tipin_gate_common_set_ram11c_bit2             ; 2D44 0 100 280 C80F
                SJ      tipin_gate_common_load_imm_3             ; 2D46 0 100 280 CB06
tipin_gate_common_clear_ram11c_bit3:     RB      off(0011ch).3          ; 2D48 0 100 280 C41C0B
                RB      off(00131h).1          ; 2D4B 0 100 280 C43109
tipin_gate_common_load_imm_3:     LB      A, #040h               ; 2D4E 0 100 280 7740
                RB      off(0011ch).2          ; 2D50 0 100 280 C41C0A
                SJ      tipin_gate_common_store_ram183             ; 2D53 0 100 280 CB60
tipin_gate_common_set_ram11c_bit2:     SB      off(0011ch).2          ; 2D55 0 100 280 C41C1A
                MOVB    r0, off(00199h)        ; 2D58 0 100 280 C49948
                MULB                           ; 2D5B 0 100 280 A234
                SLL     ACC                    ; 2D5D 0 100 280 B506D7
                LB      A, ACCH                ; 2D60 0 100 280 F507
                JGE     tipin_gate_common_store_r4             ; 2D62 0 100 280 CD02
                LB      A, #0ffh               ; 2D64 0 100 280 77FF
tipin_gate_common_store_r4:     STB     A, r4                  ; 2D66 0 100 280 8C
                LB      A, (002b4h-00280h)[USP] ; 2D67 0 100 280 F334
                VCAL    7                      ; 2D69 0 100 280 17
                JBS     off(00131h).1, tipin_gate_common_cmp_acc_7 ; 2D6A 0 100 280 E93109
                CMPB    A, #00dh               ; 2D6D 0 100 280 C60D
                JLT     tipin_gate_common_cmp_acc_7             ; 2D6F 0 100 280 CA05
                SB      off(00131h).1          ; 2D71 0 100 280 C43119
                SJ      tipin_gate_common_load_ram0ef_2             ; 2D74 0 100 280 CB09
tipin_gate_common_cmp_acc_7:     CMPB    A, #007h               ; 2D76 0 100 280 C607
                JGE     tipin_gate_common_load_ram0ef_2             ; 2D78 0 100 280 CD05
                RB      off(00131h).1          ; 2D7A 0 100 280 C43109
                SJ      tipin_gate_common_rom_load_tbl_6921             ; 2D7D 0 100 280 CB24
;  [flow] 80h-based correction map lookup (tbl_corr_map_lo_6a77 / tbl_corr_map_hi_6a8b by cam row),
;    same row/scalar index; result scales the 0193h base fuel by x/80h.
tipin_gate_common_load_ram0ef_2:     LB      A, 0efh                ; 2D7F 0 100 280 F5EF
                MOV     DP, #tbl_corr_map_hi_6a8b          ; 2D81 0 100 280 628B6A
                MOV     X1, 0cch               ; 2D84 0 100 280 B5CC78
                JBS     off(0011dh).1, tipin_gate_common_call_4523_2 ; 2D87 0 100 280 E91D08
                LB      A, 0eeh                ; 2D8A 0 100 280 F5EE
                MOV     DP, #tbl_corr_map_lo_6a77          ; 2D8C 0 100 280 62776A
                MOV     X1, 0cah               ; 2D8F 0 100 280 B5CA78
tipin_gate_common_call_4523_2:     CAL     scale_result_common_sub_extnd_acc             ; 2D92 0 100 280 322345
                MOVB    r0, r4                 ; 2D95 0 100 280 2448
                MULB                           ; 2D97 0 100 280 A234
                SLL     ACC                    ; 2D99 0 100 280 B506D7
                LB      A, ACCH                ; 2D9C 0 100 280 F507
                JGE     tipin_gate_common_store_r4_2             ; 2D9E 0 100 280 CD02
                LB      A, #0ffh               ; 2DA0 0 100 280 77FF
tipin_gate_common_store_r4_2:     STB     A, r4                  ; 2DA2 0 100 280 8C
tipin_gate_common_rom_load_tbl_6921:     LC      A, tbl_dw_6921            ; 2DA3 0 100 280 909C2169
                CMPB    A, r4                  ; 2DA7 0 100 280 4C
                JGE     tipin_gate_common_load_ram1dc             ; 2DA8 0 100 280 CD01
                STB     A, r4                  ; 2DAA 0 100 280 8C
tipin_gate_common_load_ram1dc:     LB      A, off(001dch)         ; 2DAB 0 100 280 F4DC
                JNE     tipin_gate_common_load_r4             ; 2DAD 0 100 280 CE05
                LB      A, ACCH                ; 2DAF 0 100 280 F507
                CMPB    A, r4                  ; 2DB1 0 100 280 4C
                JGE     tipin_gate_common_store_ram183             ; 2DB2 0 100 280 CD01
tipin_gate_common_load_r4:     LB      A, r4                  ; 2DB4 0 100 280 7C
tipin_gate_common_store_ram183:     STB     A, off(00183h)         ; 2DB5 0 100 280 D483
                MB      C, off(0011ah).2       ; 2DB7 0 100 280 C41A2A
                MB      off(0011ah).3, C       ; 2DBA 0 100 280 C41A3B
                JBR     off(00120h).0, tipin_gate_common_if_ram11d_bit1_set_2 ; 2DBD 0 100 280 D8202C
                JBR     off(0011ah).0, tipin_gate_common_if_ram11d_bit1_set_2 ; 2DC0 0 100 280 D81A29
                LB      A, 0dfh                ; 2DC3 0 100 280 F5DF
                CMPB    A, #064h               ; 2DC5 0 100 280 C664
                JGE     tipin_gate_common_if_ram11d_bit1_set_2             ; 2DC7 0 100 280 CD23
                LB      A, 0ebh                ; 2DC9 0 100 280 F5EB
                SUBB    A, 0dfh                ; 2DCB 0 100 280 C5DFA2
                JLT     tipin_gate_common_if_ram124_bit5_set             ; 2DCE 0 100 280 CA04
                CMPB    A, #005h               ; 2DD0 0 100 280 C605
                JGE     tipin_gate_common_set_ram12d_bit7             ; 2DD2 0 100 280 CD15
tipin_gate_common_if_ram124_bit5_set:     JBS     off(00124h).5, tipin_gate_common_if_ram11d_bit1_set_2 ; 2DD4 0 100 280 ED2415
                JBS     off(0011ah).6, tipin_gate_common_if_ram11d_bit1_set_2 ; 2DD7 0 100 280 EE1A12
                JBS     off(00119h).5, tipin_gate_common_if_ram11d_bit1_set_2 ; 2DDA 0 100 280 ED190F
                L       A, 0b2h                ; 2DDD 1 100 280 E5B2
                CMP     A, #00160h             ; 2DDF 1 100 280 C66001
                JLT     tipin_gate_common_if_ram11d_bit1_set_2             ; 2DE2 1 100 280 CA08
                SB      off(0012eh).0          ; 2DE4 1 100 280 C42E18
                SJ      tipin_gate_common_if_ram11d_bit1_set_2             ; 2DE7 1 100 280 CB03
tipin_gate_common_set_ram12d_bit7:     SB      off(0012dh).7          ; 2DE9 0 100 280 C42D1F
tipin_gate_common_if_ram11d_bit1_set_2:     JBS     off(0011dh).1, tipin_gate_common_load_x1_3 ; 2DEC 0 100 280 E91D0B
                MOV     X1, #053cfh            ; 2DEF 0 100 280 60CF53
                JBR     off(0011ah).0, tipin_gate_common_load_ram179 ; 2DF2 0 100 280 D81A0E
                MOV     X1, #053e7h            ; 2DF5 0 100 280 60E753
                SJ      tipin_gate_common_load_ram179             ; 2DF8 0 100 280 CB09
tipin_gate_common_load_x1_3:     MOV     X1, #053dbh            ; 2DFA 0 100 280 60DB53
                JBR     off(0011ah).0, tipin_gate_common_load_ram179 ; 2DFD 0 100 280 D81A03
                MOV     X1, #053f3h            ; 2E00 0 100 280 60F353
tipin_gate_common_load_ram179:     LB      A, off(00179h)         ; 2E03 0 100 280 F479
                VCAL    0                      ; 2E05 0 100 280 10
                SUBB    A, off(00197h)         ; 2E06 0 100 280 A797
                JLT     tipin_gate_common_store_carry_ram130_bit0             ; 2E08 0 100 280 CA02
                CMPB    A, off(00178h)         ; 2E0A 0 100 280 C778
tipin_gate_common_store_carry_ram130_bit0:     MB      off(00130h).0, C       ; 2E0C 0 100 280 C43038
                LB      A, off(0016fh)         ; 2E0F 0 100 280 F46F
                MOVB    r0, #060h              ; 2E11 0 100 280 9860
                JBR     off(0011ah).0, postig_threshold_check1 ; 2E13 0 100 280 D81A04
                LB      A, off(0016eh)         ; 2E16 0 100 280 F46E
                MOVB    r0, #04ch              ; 2E18 0 100 280 984C
postig_threshold_check1:     JBR     off(00115h).2, rpm_threshold_adjust ; 2E1A 0 100 280 DA1504
                CMPB    A, r0                  ; 2E1D 0 100 280 48
                JGE     rpm_threshold_adjust             ; 2E1E 0 100 280 CD01
                LB      A, r0                  ; 2E20 0 100 280 78
rpm_threshold_adjust:     CMPB    0dfh, #028h            ; 2E21 0 100 280 C5DFC028
                JBR     off(00120h).0, rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold ; 2E25 0 100 280 D82004
                CMPB    0dfh, #007h            ; 2E28 0 100 280 C5DFC007
rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold:     JLT     rpm_secondary_threshold_check             ; 2E2C 0 100 280 CA0C
                JBR     off(00130h).1, rpm_secondary_threshold_check ; 2E2E 0 100 280 D93009
                JBS     off(0011ah).0, rpm_secondary_threshold_check ; 2E31 0 100 280 E81A06
                ADDB    A, #020h               ; 2E34 0 100 280 8620
                JGE     rpm_secondary_threshold_check             ; 2E36 0 100 280 CD02
                LB      A, #0ffh               ; 2E38 0 100 280 77FF
rpm_secondary_threshold_check:     CMPB    A, off(00179h)         ; 2E3A 0 100 280 C779
                MB      off(00130h).3, C       ; 2E3C 0 100 280 C4303B
                LB      A, #074h               ; 2E3F 0 100 280 7774
                JBS     off(00130h).2, revlimiter_engage_resume_check ; 2E41 0 100 280 EA3002
                LB      A, #080h               ; 2E44 0 100 280 7780
revlimiter_engage_resume_check:     CMPB    A, off(00179h)         ; 2E46 0 100 280 C779
                MB      off(00130h).2, C       ; 2E48 0 100 280 C4303A
                RB      off(0011bh).3          ; 2E4B 0 100 280 C41B0B
                JBS     off(00111h).5, revlimiter_engage_resume_check_if_ram110_bit6_set ; 2E4E 0 100 280 ED110B
                MB      C, 099h.3              ; 2E51 0 100 280 C5992B
                JLT     revlimiter_engage_resume_check_if_ram110_bit6_set             ; 2E54 0 100 280 CA06
                LB      A, ADCR4H              ; 2E56 0 100 280 F571
                CMPB    A, #008h               ; 2E58 0 100 280 C608
                JGE     revlimiter_engage_resume_check_load_ram16c             ; 2E5A 0 100 280 CD1E
revlimiter_engage_resume_check_if_ram110_bit6_set:     JBS     off(00110h).6, vaccut_rpm_check ; 2E5C 0 100 280 EE1013
                MB      C, 098h.2              ; 2E5F 0 100 280 C5982A
                JLT     vaccut_rpm_check             ; 2E62 0 100 280 CA0E
                CMPB    0abh, #02eh            ; 2E64 0 100 280 C5ABC02E
                JGE     revlimiter_engage_resume_check_load_ram16c             ; 2E68 0 100 280 CD10
                MOV     X1, #revlimiter_engage_resume_check_tbl          ; 2E6A 0 100 280 604B57
                LB      A, 0abh                ; 2E6D 0 100 280 F5AB
                VCAL    2                      ; 2E6F 0 100 280 12
                SJ      vaccut_rpm_check_cmp_acc             ; 2E70 0 100 280 CB02
vaccut_rpm_check:     LB      A, #080h               ; 2E72 0 100 280 7780
vaccut_rpm_check_cmp_acc:     CMPB    A, off(00179h)         ; 2E74 0 100 280 C779
                JGE     ofc_enable_check_if_ram130_bit0_set             ; 2E76 0 100 280 CD5B
                SJ      revlimiter_fuelcut_set             ; 2E78 0 100 280 CB47
;  [flow] rev/speed limiter engage+resume. 0AEh = RPM word (p13info '0AEh 16-bit RPM' verified:
;    compared against the limiter words and reset to FFFFh at boot/loss-of-signal).
;    2E81: cut  = (RPM word > 016Ah); 2E95: resume above 0238h/0217h words when flag 011Ah.4 picks
;    the resume word 016Ch. 2E86/2E89 also consult CEL words 0110h.3 / 0111h.7 (p13info CEL words).
;    2EA9: SPEED limiter: CMPB 0DFh(VSS km/h), #0FFh -- the immediate at 2EAC is the p13info
;    'Speed Limiter 0-255, FF disables' byte; 0FFh = no speed (km/h) realistically reaches it.
;    01E3h/01E4h latch which limiter is waiting to be cleared; actual cut = PSWL.5 (fuel-cut strobe).
revlimiter_engage_resume_check_load_ram16c:     L       A, off(0016ch)         ; 2E7A 1 100 280 E46C
                JBS     off(0011ah).4, revlimiter_engage_resume_check_cmp_acc ; 2E7C 1 100 280 EC1A02
                L       A, off(0016ah)         ; 2E7F 1 100 280 E46A
revlimiter_engage_resume_check_cmp_acc:     CMP     A, 0aeh                ; 2E81 1 100 280 B5AEC2
                JGT     revlimiter_fuelcut_set             ; 2E84 1 100 280 C83B
                JBS     off(00110h).3, revlimiter_engage_resume_check_load_imm ; 2E86 1 100 280 EB1003
                JBR     off(00111h).7, revlimiter_engage_resume_check_load_ram11e ; 2E89 1 100 280 DF110E
revlimiter_engage_resume_check_load_imm:     L       A, #00238h             ; 2E8C 1 100 280 673802
                JBS     off(0011ah).4, revlimiter_engage_resume_check_cmp_acc_2 ; 2E8F 1 100 280 EC1A03
                L       A, #00217h             ; 2E92 1 100 280 671702
revlimiter_engage_resume_check_cmp_acc_2:     CMP     A, 0aeh                ; 2E95 1 100 280 B5AEC2
                JGT     revlimiter_fuelcut_set             ; 2E98 1 100 280 C827
revlimiter_engage_resume_check_load_ram11e:     LB      A, off(0011eh)         ; 2E9A 0 100 280 F41E
                ANDB    A, #078h               ; 2E9C 0 100 280 D678
                JNE     fuelcuttrack_store             ; 2E9E 0 100 280 CE39
                JBR     off(0011fh).0, fuelcut_extra_gate ; 2EA0 0 100 280 D81F24
                LB      A, #0ffh               ; 2EA3 0 100 280 77FF
                CMPB    A, off(00179h)         ; 2EA5 0 100 280 C779
                JGE     revlimiter_engage_resume_check_load_imm_2             ; 2EA7 0 100 280 CD0A
                CMPB    0dfh, #0ffh            ; 2EA9 0 100 280 C5DFC0FF
                JGE     revlimiter_engage_resume_check_load_ram1e3             ; 2EAD 0 100 280 CD0A
                LB      A, off(001e4h)         ; 2EAF 0 100 280 F4E4
                JNE     revlimiter_fuelcut_set             ; 2EB1 0 100 280 CE0E
revlimiter_engage_resume_check_load_imm_2:     LB      A, #0ffh               ; 2EB3 0 100 280 77FF
                STB     A, off(001e3h)         ; 2EB5 0 100 280 D4E3
                SJ      fuelcut_extra_gate             ; 2EB7 0 100 280 CB0E
revlimiter_engage_resume_check_load_ram1e3:     LB      A, off(001e3h)         ; 2EB9 0 100 280 F4E3
                JNE     fuelcut_extra_gate             ; 2EBB 0 100 280 CE0A
                LB      A, #0ffh               ; 2EBD 0 100 280 77FF
                STB     A, off(001e4h)         ; 2EBF 0 100 280 D4E4
revlimiter_fuelcut_set:     SB      PSWL.5                 ; 2EC1 1 100 280 A31D
                RB      PSWL.4                 ; 2EC3 1 100 280 A30C
                SJ      revlimiter_fuelcut_set_if_ram12d_bit7_set             ; 2EC5 1 100 280 CB3C
fuelcut_extra_gate:     JBS     off(0011ah).0, ofc_enable_check ; 2EC7 0 100 280 E81A03
                JBR     off(00116h).2, ofc_enable_check_if_ram130_bit0_set ; 2ECA 0 100 280 DA1606
ofc_enable_check:     JBR     off(00117h).2, ofc_enable_check_if_ram130_bit3_set ; 2ECD 0 100 280 DA1714
                RB      off(00130h).1          ; 2ED0 0 100 280 C43009
ofc_enable_check_if_ram130_bit0_set:     JBS     off(00130h).0, fuelcuttrack_store ; 2ED3 0 100 280 E83003
                JBS     off(00130h).2, ofc_enable_check_clear_pswl_bit5 ; 2ED6 0 100 280 EA3013
fuelcuttrack_store:     LB      A, #01eh               ; 2ED9 0 100 280 771E
                STB     A, off(001f3h)         ; 2EDB 0 100 280 D4F3
fuelcuttrack_store_clear_pswl_bit4:     RB      PSWL.4                 ; 2EDD 0 100 280 A30C
                RB      PSWL.5                 ; 2EDF 0 100 280 A30D
                RC                             ; 2EE1 0 100 280 95
                SJ      fuelcuttrack_store_if_ram111_bit6_clr             ; 2EE2 0 100 280 CB2E
ofc_enable_check_if_ram130_bit3_set:     JBS     off(00130h).3, ofc_enable_check_clear_pswl_bit5 ; 2EE4 0 100 280 EB3005
                SB      off(00130h).1          ; 2EE7 0 100 280 C43019
                SJ      fuelcuttrack_store             ; 2EEA 0 100 280 CBED
ofc_enable_check_clear_pswl_bit5:     RB      PSWL.5                 ; 2EEC 0 100 280 A30D
                SB      PSWL.4                 ; 2EEE 0 100 280 A31C
                JBS     off(0011ah).0, revlimiter_fuelcut_set_if_ram12d_bit7_set ; 2EF0 0 100 280 E81A10
                LB      A, #004h               ; 2EF3 0 100 280 7704
                JBS     off(00120h).0, ofc_enable_check_cmp_acc ; 2EF5 0 100 280 E82002
                LB      A, #003h               ; 2EF8 0 100 280 7703
ofc_enable_check_cmp_acc:     CMPB    A, 0e6h                ; 2EFA 0 100 280 C5E6C2
                JLE     fuelcuttrack_store             ; 2EFD 0 100 280 CFDA
                J       ofc_enable_check_load_ram1f3             ; 2EFF 0 100 280 03E06F
                DB  000h ; 2F02
revlimiter_fuelcut_set_if_ram12d_bit7_set:     JBS     off(0012dh).7, revlimiter_fuelcut_set_nop_acc ; 2F03 1 100 280 EF2D06
                JBS     off(0012eh).0, revlimiter_fuelcut_set_nop_acc ; 2F06 1 100 280 E82E03
                JBS     off(0012dh).5, revlimiter_fuelcut_set_set_carry ; 2F09 1 100 280 ED2D05
revlimiter_fuelcut_set_nop_acc:     NOP                            ; 2F0C 1 100 280 00
                NOP                            ; 2F0D 1 100 280 00
                NOP                            ; 2F0E 1 100 280 00
                SJ      fuelcuttrack_store_clear_pswl_bit4             ; 2F0F 1 100 280 CBCC
revlimiter_fuelcut_set_set_carry:     SC                             ; 2F11 1 100 280 85
fuelcuttrack_store_if_ram111_bit6_clr:     JBR     off(00111h).6, fuelcuttrack_store_store_carry_ram11a_bit0 ; 2F12 0 100 280 DE1101
                SC                             ; 2F15 0 100 280 85
fuelcuttrack_store_store_carry_ram11a_bit0:     MB      off(0011ah).0, C       ; 2F16 0 100 280 C41A38
                MB      C, PSWL.5              ; 2F19 0 100 280 A32D
                MB      off(0011ah).4, C       ; 2F1B 0 100 280 C41A3C
                MB      C, PSWL.4              ; 2F1E 0 100 280 A32C
                MB      off(0011ah).2, C       ; 2F20 0 100 280 C41A3A
                RB      PSWL.5                 ; 2F23 0 100 280 A30D
                MOVB    r2, #03ch              ; 2F25 0 100 280 9A3C
                LB      A, off(0011eh)         ; 2F27 0 100 280 F41E
                ANDB    A, #078h               ; 2F29 0 100 280 D678
                JNE     fuelcuttrack_store_goto_2fe5             ; 2F2B 0 100 280 CE11
                JBR     off(0011dh).0, fuelcuttrack_store_if_ram12d_bit5_clr ; 2F2D 0 100 280 D81D08
                LB      A, off(00178h)         ; 2F30 0 100 280 F478
                CAL     fuelcuttrack_store_sub_load_x1             ; 2F32 0 100 280 32706E
                VCAL    0                      ; 2F35 0 100 280 10
                SJ      to_set_pswl4_flag_b_set_ram11c_bit0             ; 2F36 0 100 280 CB76
fuelcuttrack_store_if_ram12d_bit5_clr:     JBR     off(0012dh).5, fuelcuttrack_store_goto_2fe5 ; 2F38 0 100 280 DD2D03
                JBR     off(0011ch).3, fuelcuttrack_store_if_ram116_bit5_clr ; 2F3B 0 100 280 DB1C03
fuelcuttrack_store_goto_2fe5:     J       ignmap2_result_check_clear_acc             ; 2F3E 0 100 280 03E52F
fuelcuttrack_store_if_ram116_bit5_clr:     JBR     off(00116h).5, postig_result_default ; 2F41 0 100 280 DD166F
                JBR     off(00116h).2, postig_result_default ; 2F44 0 100 280 DA166C
                JBR     off(00117h).4, fuelcuttrack_store_load_imm ; 2F47 0 100 280 DC1705
                RB      off(00128h).3          ; 2F4A 0 100 280 C4280B
                SJ      postig_result_default             ; 2F4D 0 100 280 CB64
fuelcuttrack_store_load_imm:     L       A, #052b3h             ; 2F4F 1 100 280 67B352
                MOV     X1, #052c1h            ; 2F52 1 100 280 60C152
                JBS     off(00120h).0, fuelcuttrack_store_if_ram11c_bit0_set ; 2F55 1 100 280 E82006
                L       A, #05297h             ; 2F58 1 100 280 679752
                MOV     X1, #052a5h            ; 2F5B 1 100 280 60A552
fuelcuttrack_store_if_ram11c_bit0_set:     JBS     off(0011ch).0, fuelcuttrack_store_load_ram0d9 ; 2F5E 1 100 280 E81C01
                MOV     X1, A                  ; 2F61 1 100 280 50
fuelcuttrack_store_load_ram0d9:     LB      A, 0d9h                ; 2F62 0 100 280 F5D9
                VCAL    0                      ; 2F64 0 100 280 10
                JBR     off(00115h).2, idle_mode_gate3 ; 2F65 0 100 280 DA150B
                LB      A, #060h               ; 2F68 0 100 280 7760
                JBR     off(0011ch).0, fuelcuttrack_store_cmp_acc ; 2F6A 0 100 280 D81C02
                LB      A, #04ah               ; 2F6D 0 100 280 774A
fuelcuttrack_store_cmp_acc:     CMPB    A, r6                  ; 2F6F 0 100 280 4E
                JGE     idle_mode_gate3             ; 2F70 0 100 280 CD01
                LB      A, r6                  ; 2F72 0 100 280 7E
idle_mode_gate3:     JBR     off(00120h).0, idle_mode_gate3_cmp_acc ; 2F73 0 100 280 D82018
                JBS     off(0011ch).0, idle_mode_gate3_cmp_acc ; 2F76 0 100 280 E81C15
                JBR     off(00128h).3, idle_mode_gate3_cmp_acc ; 2F79 0 100 280 DB2812
                CMPB    0d9h, #02eh            ; 2F7C 0 100 280 C5D9C02E
                JLT     idle_mode_gate3_cmp_acc             ; 2F80 0 100 280 CA0C
                CMPB    0dfh, #00ah            ; 2F82 0 100 280 C5DFC00A
                JLT     idle_mode_gate3_cmp_acc             ; 2F86 0 100 280 CA06
                ADDB    A, #01ah               ; 2F88 0 100 280 861A
                JGE     idle_mode_gate3_cmp_acc             ; 2F8A 0 100 280 CD02
                LB      A, #0ffh               ; 2F8C 0 100 280 77FF
idle_mode_gate3_cmp_acc:     CMPB    A, off(00179h)         ; 2F8E 0 100 280 C779
                JLT     idle_mode_gate3_cmp_ram0d9             ; 2F90 0 100 280 CA05
                SB      off(00128h).3          ; 2F92 0 100 280 C4281B
                SJ      ignmap2_result_check_clear_acc             ; 2F95 0 100 280 CB4E
idle_mode_gate3_cmp_ram0d9:     CMPB    0d9h, #034h            ; 2F97 0 100 280 C5D9C034
                JGE     postig_result_high             ; 2F9B 0 100 280 CD08
                JBR     off(00120h).0, postig_result_high ; 2F9D 0 100 280 D82005
                LB      A, off(001f5h)         ; 2FA0 0 100 280 F4F5
                STB     A, r2                  ; 2FA2 0 100 280 8A
                JNE     ignmap2_result_check_clear_acc             ; 2FA3 0 100 280 CE40
postig_result_high:     LB      A, #0d9h               ; 2FA5 0 100 280 77D9
                JBS     off(00120h).0, to_set_pswl4_flag_b ; 2FA7 0 100 280 E82002
                LB      A, #0e6h               ; 2FAA 0 100 280 77E6
to_set_pswl4_flag_b:     SB      PSWL.5                 ; 2FAC 0 100 280 A31D
to_set_pswl4_flag_b_set_ram11c_bit0:     SB      off(0011ch).0          ; 2FAE 0 100 280 C41C18
                SJ      to_set_pswl4_flag_b_store_ram18a             ; 2FB1 0 100 280 CB36
postig_result_default:     LB      A, #080h               ; 2FB3 0 100 280 7780
                MOV     X1, #053dbh            ; 2FB5 0 100 280 60DB53
                JBS     off(0011dh).1, ignmap2_table_select ; 2FB8 0 100 280 E91D03
                MOV     X1, #053cfh            ; 2FBB 0 100 280 60CF53
ignmap2_table_select:     JBR     off(0011ch).0, ignmap2_rpm_gate ; 2FBE 0 100 280 D81C0B
                LB      A, #074h               ; 2FC1 0 100 280 7774
                MOV     X1, #053f3h            ; 2FC3 0 100 280 60F353
                JBS     off(0011dh).1, ignmap2_rpm_gate ; 2FC6 0 100 280 E91D03
                MOV     X1, #053e7h            ; 2FC9 0 100 280 60E753
ignmap2_rpm_gate:     CMPB    A, off(00179h)         ; 2FCC 0 100 280 C779
                JGE     ignmap2_result_check_clear_acc             ; 2FCE 0 100 280 CD15
                LB      A, off(00179h)         ; 2FD0 0 100 280 F479
                VCAL    0                      ; 2FD2 0 100 280 10
                ADDB    A, #001h               ; 2FD3 0 100 280 8601
                JGE     ignmap2_result_check             ; 2FD5 0 100 280 CD02
                LB      A, #0ffh               ; 2FD7 0 100 280 77FF
ignmap2_result_check:     SUBB    A, off(00197h)         ; 2FD9 0 100 280 A797
                JLT     ignmap2_result_check_clear_acc             ; 2FDB 0 100 280 CA08
                CMPB    A, off(00178h)         ; 2FDD 0 100 280 C778
                JLE     ignmap2_result_check_clear_acc             ; 2FDF 0 100 280 CF04
                LB      A, #0e6h               ; 2FE1 0 100 280 77E6
                SJ      to_set_pswl4_flag_b_set_ram11c_bit0             ; 2FE3 0 100 280 CBC9
ignmap2_result_check_clear_acc:     CLRB    A                      ; 2FE5 0 100 280 FA
                RB      off(0011ch).0          ; 2FE6 0 100 280 C41C08
to_set_pswl4_flag_b_store_ram18a:     STB     A, off(0018ah)         ; 2FE9 0 100 280 D48A
                MB      C, PSWL.5              ; 2FEB 0 100 280 A32D
                MB      off(0011ch).1, C       ; 2FED 0 100 280 C41C39
                MOVB    off(001f5h), r2        ; 2FF0 0 100 280 227CF5
                LB      A, #0efh               ; 2FF3 0 100 280 77EF
                JBS     off(0012fh).0, to_set_pswl4_flag_b_cmp_acc ; 2FF5 0 100 280 E82F02
                LB      A, #0f5h               ; 2FF8 0 100 280 77F5
to_set_pswl4_flag_b_cmp_acc:     CMPB    A, off(00179h)         ; 2FFA 0 100 280 C779
                MB      off(0012fh).0, C       ; 2FFC 0 100 280 C42F38
                JLT     to_set_pswl4_flag_b_store_carry_ram11b_bit6             ; 2FFF 0 100 280 CA0A
                LB      A, #00fh               ; 3001 0 100 280 770F
                JBS     off(0011bh).6, to_set_pswl4_flag_b_cmp_ram0af ; 3003 0 100 280 EE1B02
                LB      A, #00fh               ; 3006 0 100 280 770F
to_set_pswl4_flag_b_cmp_ram0af:     CMPB    0afh, A                ; 3008 0 100 280 C5AFC1
to_set_pswl4_flag_b_store_carry_ram11b_bit6:     MB      off(0011bh).6, C       ; 300B 0 100 280 C41B3E
                RC                             ; 300E 0 100 280 95
                JBS     off(0012fh).0, to_set_pswl4_flag_b_store_carry_ram11b_bit2 ; 300F 0 100 280 E82F0C
                JBS     off(0011ch).3, to_set_pswl4_flag_b_store_carry_ram11b_bit2 ; 3012 0 100 280 EB1C09
                JBS     off(0011ch).0, to_set_pswl4_flag_b_store_carry_ram11b_bit2 ; 3015 0 100 280 E81C06
                JBS     off(0011ah).0, to_set_pswl4_flag_b_store_carry_ram11b_bit2 ; 3018 0 100 280 E81A03
                MB      C, off(0011bh).6       ; 301B 0 100 280 C41B2E
to_set_pswl4_flag_b_store_carry_ram11b_bit2:     MB      off(0011bh).2, C       ; 301E 0 100 280 C41B3A
                LB      A, #0bah               ; 3021 0 100 280 77BA
                JBS     off(0011bh).7, to_set_pswl4_flag_b_cmp_acc_2 ; 3023 0 100 280 EF1B02
                LB      A, #0c0h               ; 3026 0 100 280 77C0
to_set_pswl4_flag_b_cmp_acc_2:     CMPB    A, off(00179h)         ; 3028 0 100 280 C779
                MB      off(0011bh).7, C       ; 302A 0 100 280 C41B3F
                JBR     off(00117h).0, to_set_pswl4_flag_b_load_carry_ram12f_bit3 ; 302D 0 100 280 D81704
                MOVB    off(001e1h), #019h     ; 3030 0 100 280 C4E19819
to_set_pswl4_flag_b_load_carry_ram12f_bit3:     MB      C, off(0012fh).3       ; 3034 0 100 280 C42F2B
                MB      PSWL.4, C              ; 3037 0 100 280 A33C
                LB      A, #01fh               ; 3039 0 100 280 771F
                CMPB    0e0h, #0dbh            ; 303B 0 100 280 C5E0C0DB
                JLT     to_set_pswl4_flag_b_cmp_acc_3             ; 303F 0 100 280 CA02
                LB      A, #01dh               ; 3041 0 100 280 771D
to_set_pswl4_flag_b_cmp_acc_3:     CMPB    A, 0dah                ; 3043 0 100 280 C5DAC2
                MB      off(0012fh).3, C       ; 3046 0 100 280 C42F3B
                MB      C, PSWL.4              ; 3049 0 100 280 A32C
                JBR     off(0012fh).3, to_set_pswl4_flag_b_store_carry_ram12f_bit2 ; 304B 0 100 280 DB2F04
                RB      PSWL.4                 ; 304E 0 100 280 A30C
                MB      C, PSWH.6              ; 3050 0 100 280 A22E
to_set_pswl4_flag_b_store_carry_ram12f_bit2:     MB      off(0012fh).2, C       ; 3052 0 100 280 C42F3A
                L       A, off(00172h)         ; 3055 1 100 280 E472
                JEQ     to_set_pswl4_flag_b_load_r0             ; 3057 1 100 280 C903
                DEC     off(00172h)            ; 3059 1 100 280 B47217
to_set_pswl4_flag_b_load_r0:     MOVB    r0, #064h              ; 305C 1 100 280 9864
                JBS     off(0011dh).0, to_set_pswl4_flag_b_clear_ram196_2 ; 305E 1 100 280 E81D49
                JBR     off(0011fh).0, to_set_pswl4_flag_b_if_ram118_bit6_set ; 3061 1 100 280 D81F0B
                MB      C, 0a0h.0              ; 3064 1 100 280 C5A028
                JGE     to_set_pswl4_flag_b_if_ram118_bit6_set             ; 3067 1 100 280 CD06
                JBR     off(0012fh).2, to_set_pswl4_flag_b_clear_ram196_2 ; 3069 1 100 280 DA2F3E
                RB      0a0h.0                 ; 306C 1 100 280 C5A008
to_set_pswl4_flag_b_if_ram118_bit6_set:     JBS     off(00118h).6, to_set_pswl4_flag_b_load_imm ; 306F 1 100 280 EE1821
                JBR     off(00118h).2, to_set_pswl4_flag_b_clear_ram196_2 ; 3072 1 100 280 DA1835
                JBS     off(0011ch).3, to_set_pswl4_flag_b_clear_ram196_2 ; 3075 1 100 280 EB1C32
                JBR     off(00118h).0, to_set_pswl4_flag_b_clear_ram196 ; 3078 1 100 280 D8181D
                JBS     off(0012fh).0, to_set_pswl4_flag_b_clear_ram196_2 ; 307B 1 100 280 E82F2C
                JBR     off(0011bh).6, to_set_pswl4_flag_b_load_ram196 ; 307E 1 100 280 DE1B31
                JBS     off(0011ah).0, to_set_pswl4_flag_b_load_ram196 ; 3081 1 100 280 E81A2E
                JBS     off(0011ch).0, to_set_pswl4_flag_b_load_ram196 ; 3084 1 100 280 E81C2B
                SB      off(0011bh).1          ; 3087 1 100 280 C41B19
                MOVB    off(001efh), r0        ; 308A 1 100 280 207CEF
                CAL     to_set_pswl4_flag_b_sub_clear_acc             ; 308D 1 100 280 321A47
                L       A, er1                 ; 3090 1 100 280 35
                SJ      o2_trim_dp_table_read_store_ram160             ; 3091 1 100 280 CB37
to_set_pswl4_flag_b_load_imm:     L       A, #08290h             ; 3093 1 100 280 679082
                SJ      o2_trim_dp_table_read_clear_ram11b_bit1             ; 3096 1 100 280 CB2C
to_set_pswl4_flag_b_clear_ram196:     CLRB    off(00196h)            ; 3098 1 100 280 C49615
                MOVB    off(001efh), r0        ; 309B 1 100 280 207CEF
                MOV     DP, #00308h            ; 309E 1 100 280 620803
                JBR     off(00117h).0, o2_trim_dp_table_read ; 30A1 1 100 280 D81703
                MOV     DP, #00304h            ; 30A4 1 100 280 620403
o2_trim_dp_table_read:     L       A, [DP]                ; 30A7 1 100 280 E2
                SJ      o2_trim_dp_table_read_clear_ram11b_bit1             ; 30A8 1 100 280 CB1A
to_set_pswl4_flag_b_clear_ram196_2:     CLRB    off(00196h)            ; 30AA 1 100 280 C49615
                MOVB    off(001efh), r0        ; 30AD 1 100 280 207CEF
                SJ      to_set_pswl4_flag_b_load_imm_2             ; 30B0 1 100 280 CB0F
to_set_pswl4_flag_b_load_ram196:     MOVB    off(00196h), #00ah     ; 30B2 1 100 280 C496980A
                LB      A, off(001efh)         ; 30B6 0 100 280 F4EF
                JEQ     to_set_pswl4_flag_b_load_imm_2             ; 30B8 0 100 280 C907
                L       A, off(00160h)         ; 30BA 1 100 280 E460
                SB      off(0011bh).1          ; 30BC 1 100 280 C41B19
                SJ      o2_trim_dp_table_read_clear_ram11b_bit0             ; 30BF 1 100 280 CB06
to_set_pswl4_flag_b_load_imm_2:     L       A, #08000h             ; 30C1 1 100 280 670080
o2_trim_dp_table_read_clear_ram11b_bit1:     RB      off(0011bh).1          ; 30C4 1 100 280 C41B09
o2_trim_dp_table_read_clear_ram11b_bit0:     RB      off(0011bh).0          ; 30C7 1 100 280 C41B08
o2_trim_dp_table_read_store_ram160:     ST      A, off(00160h)         ; 30CA 1 100 280 D460
                LB      A, off(0017eh)         ; 30CC 0 100 280 F47E
                JBS     off(0011dh).0, o2_trim_dp_table_read_store_ram180 ; 30CE 0 100 280 E81D28
                LB      A, #040h               ; 30D1 0 100 280 7740
                JBS     off(0011ch).2, o2_trim_dp_table_read_store_ram180 ; 30D3 0 100 280 EA1C23
                JBS     off(0011ch).0, o2_trim_dp_table_read_store_ram180 ; 30D6 0 100 280 E81C20
                MOV     X1, #051b9h            ; 30D9 0 100 280 60B951
                MOV     X2, #0017ah            ; 30DC 0 100 280 617A01
                JBR     off(0011bh).0, o2_trim_dp_table_read_if_ram120_bit0_set ; 30DF 0 100 280 D81B06
                ADD     X1, #00004h            ; 30E2 0 100 280 90800400
                INC     X2                     ; 30E6 0 100 280 71
                INC     X2                     ; 30E7 0 100 280 71
o2_trim_dp_table_read_if_ram120_bit0_set:     JBS     off(00120h).0, o2_trim_dp_table_read_load_tbl_x2 ; 30E8 0 100 280 E82001
                INC     X1                     ; 30EB 0 100 280 70
o2_trim_dp_table_read_load_tbl_x2:     LB      A, 00000h[X2]          ; 30EC 0 100 280 F10000
                STB     A, r6                  ; 30EF 0 100 280 8E
                LB      A, 00001h[X2]          ; 30F0 0 100 280 F10100
                STB     A, r7                  ; 30F3 0 100 280 8F
                LB      A, off(00178h)         ; 30F4 0 100 280 F478
                CAL     knockretard_table_gate_sub_load_acc             ; 30F6 0 100 280 32EE43
o2_trim_dp_table_read_store_ram180:     STB     A, off(00180h)         ; 30F9 0 100 280 D480
                LB      A, off(00178h)         ; 30FB 0 100 280 F478
                MOV     X1, #052efh            ; 30FD 0 100 280 60EF52
                VCAL    0                      ; 3100 0 100 280 10
                MOVB    ACCH, #002h            ; 3101 0 100 280 C5079802
                MOVB    r0, off(00189h)        ; 3105 0 100 280 C48948
                CLRB    r1                     ; 3108 0 100 280 2115
                MUL                            ; 310A 0 100 280 9035
                SRL     er1                    ; 310C 0 100 280 45E7
                RORB    ACCH                   ; 310E 0 100 280 C507C7
                LB      A, r2                  ; 3111 0 100 280 7A
                L       A, ACC                 ; 3112 1 100 280 E506
                SWAP                           ; 3114 1 100 280 83
                ADD     A, #00200h             ; 3115 1 100 280 860002
                ST      A, off(00154h)         ; 3118 1 100 280 D454
                LB      A, off(00183h)         ; 311A 0 100 280 F483
                JBS     off(0011ch).2, o2_trim_dp_table_read_load_r0 ; 311C 0 100 280 EA1C02
                LB      A, off(00180h)         ; 311F 0 100 280 F480
o2_trim_dp_table_read_load_r0:     MOVB    r0, off(0018fh)        ; 3121 0 100 280 C48F48
                MULB                           ; 3124 0 100 280 A234
                MOV     er0, A                 ; 3126 0 100 280 448A
                LB      A, off(0018ah)         ; 3128 0 100 280 F48A
                JEQ     o2_trim_dp_table_read_load_ram182             ; 312A 0 100 280 C907
                STB     A, ACCH                ; 312C 0 100 280 D507
                CLRB    A                      ; 312E 0 100 280 FA
                MUL                            ; 312F 0 100 280 9035
                MOV     er0, er1               ; 3131 0 100 280 4548
o2_trim_dp_table_read_load_ram182:     LB      A, off(00182h)         ; 3133 0 100 280 F482
                JEQ     o2_trim_dp_table_read_load_ram162             ; 3135 0 100 280 C907
                STB     A, ACCH                ; 3137 0 100 280 D507
                CLRB    A                      ; 3139 0 100 280 FA
                MUL                            ; 313A 0 100 280 9035
                MOV     er0, er1               ; 313C 0 100 280 4548
o2_trim_dp_table_read_load_ram162:     L       A, off(00162h)         ; 313E 1 100 280 E462
                MUL                            ; 3140 1 100 280 9035
                MOV     er0, er1               ; 3142 1 100 280 4548
                L       A, off(00154h)         ; 3144 1 100 280 E454
                MUL                            ; 3146 1 100 280 9035
                SRL     er1                    ; 3148 1 100 280 45E7
                ROR     A                      ; 314A 1 100 280 43
                SRL     er1                    ; 314B 1 100 280 45E7
                ROR     A                      ; 314D 1 100 280 43
                MOVB    r1, r2                 ; 314E 1 100 280 2249
                MOVB    r0, ACCH               ; 3150 1 100 280 C50748
                LB      A, r3                  ; 3153 0 100 280 7B
                JEQ     injtimer_mul_chain2             ; 3154 0 100 280 C904
                MOV     er0, #0ffffh           ; 3156 0 100 280 4498FFFF
injtimer_mul_chain2:     L       A, off(00152h)         ; 315A 1 100 280 E452
                MUL                            ; 315C 1 100 280 9035
                MOV     er0, er1               ; 315E 1 100 280 4548
                JBS     off(0011bh).0, injtimer_mul_final ; 3160 1 100 280 E81B1C
                JBR     off(0011dh).4, injtimer_mul_final ; 3163 1 100 280 DC1D19
                SLL     A                      ; 3166 1 100 280 53
                ROL     er0                    ; 3167 1 100 280 44B7
                JLT     injtimer_mul_clamp             ; 3169 1 100 280 CA0A
                SLL     A                      ; 316B 1 100 280 53
                ROL     er0                    ; 316C 1 100 280 44B7
                JLT     injtimer_mul_clamp             ; 316E 1 100 280 CA05
                SLL     A                      ; 3170 1 100 280 53
                ROL     er0                    ; 3171 1 100 280 44B7
                JGE     injtimer_mul_chain3             ; 3173 1 100 280 CD04
injtimer_mul_clamp:     MOV     er0, #0ffffh           ; 3175 1 100 280 4498FFFF
injtimer_mul_chain3:     L       A, off(0015eh)         ; 3179 1 100 280 E45E
                MUL                            ; 317B 1 100 280 9035
                MOV     er0, er1               ; 317D 1 100 280 4548
injtimer_mul_final:     L       A, off(00160h)         ; 317F 1 100 280 E460
                MUL                            ; 3181 1 100 280 9035
                MOV     off(00150h), er1       ; 3183 1 100 280 457C50
                JBS     off(00110h).2, dwell_zero_result ; 3186 1 100 280 EA104C
                JBS     off(00110h).4, dwell_zero_result ; 3189 1 100 280 EC1049
                JBS     off(0011dh).0, dwell_zero_result ; 318C 1 100 280 E81D46
                LB      A, off(00179h)         ; 318F 0 100 280 F479
                CMPB    A, #0c0h               ; 3191 0 100 280 C6C0
                JGE     dwell_zero_result             ; 3193 0 100 280 CD40
                CMPB    A, #001h               ; 3195 0 100 280 C601
                JLT     dwell_zero_result             ; 3197 0 100 280 CA3C
                JBS     off(00128h).4, injtimer_mul_final_load_imm ; 3199 0 100 280 EC2809
                CMPB    0e2h, #010h            ; 319C 0 100 280 C5E2C010
                JLT     dwell_zero_result             ; 31A0 0 100 280 CA33
                SB      off(00128h).4          ; 31A2 0 100 280 C4281C
injtimer_mul_final_load_imm:     LB      A, #004h               ; 31A5 0 100 280 7704
                JBS     off(00119h).3, injtimer_mul_final_cmp_acc ; 31A7 0 100 280 EB1908
                LB      A, #004h               ; 31AA 0 100 280 7704
                CMPB    0ffh, #01eh            ; 31AC 0 100 280 C5FFC01E
                JLT     dwell_zero_result             ; 31B0 0 100 280 CA23
injtimer_mul_final_cmp_acc:     CMPB    A, 0e6h                ; 31B2 0 100 280 C5E6C2
                JGE     dwell_zero_result             ; 31B5 0 100 280 CD1E
                MOVB    r0, off(00187h)        ; 31B7 0 100 280 C48748
                MOVB    r1, #010h              ; 31BA 0 100 280 9910
                JBS     off(00119h).3, dwell_clamp_check ; 31BC 0 100 280 EB1905
                MOVB    r0, off(00188h)        ; 31BF 0 100 280 C48848
                MOVB    r1, #014h              ; 31C2 0 100 280 9914
dwell_clamp_check:     LB      A, 0e6h                ; 31C4 0 100 280 F5E6
                CMPB    A, r1                  ; 31C6 0 100 280 49
                JLE     dwell_mul_apply             ; 31C7 0 100 280 CF01
                LB      A, r1                  ; 31C9 0 100 280 79
dwell_mul_apply:     MULB                           ; 31CA 0 100 280 A234
                L       A, ACC                 ; 31CC 1 100 280 E506
                SRL     A                      ; 31CE 1 100 280 63
                JBS     off(00119h).3, dwell_store_result ; 31CF 1 100 280 EB1904
                VCAL    7                      ; 31D2 1 100 280 17
                SJ      dwell_store_result             ; 31D3 1 100 280 CB01
dwell_zero_result:     CLR     A                      ; 31D5 1 100 280 F9
dwell_store_result:     ST      A, off(00144h)         ; 31D6 1 100 280 D444
                CLRB    r4                     ; 31D8 1 100 280 2415
                RC                             ; 31DA 1 100 280 95
                JBS     off(0011dh).0, rpm_accel_clamp_store_carry_ram12e_bit2 ; 31DB 1 100 280 E81D55
                JBR     off(00116h).6, rpm_accel_clamp_store_carry_ram12e_bit2 ; 31DE 1 100 280 DE1652
                JBS     off(0012eh).2, dwell_store_result_if_ram116_bit2_clr ; 31E1 1 100 280 EA2E05
                JBS     off(00116h).7, rpm_accel_clamp_load_r4 ; 31E4 1 100 280 EF164F
                SJ      dwell_store_result_load_carry_ram119_bit4             ; 31E7 1 100 280 CB06
dwell_store_result_if_ram116_bit2_clr:     JBR     off(00116h).2, dwell_store_result_load_carry_ram119_bit4 ; 31E9 1 100 280 DA1603
                JBR     off(0012dh).0, rpm_accel_clamp_store_carry_ram12e_bit2 ; 31EC 1 100 280 D82D44
dwell_store_result_load_carry_ram119_bit4:     MB      C, off(00119h).4       ; 31EF 1 100 280 C4192C
                L       A, #000b3h             ; 31F2 1 100 280 67B300
                JBS     off(00116h).7, dwell_store_result_if_lt_goto_rpm_accel_secondary_calc ; 31F5 1 100 280 EF1606
                XORB    PSWH, #080h            ; 31F8 1 100 280 A2F080
                L       A, #000b3h             ; 31FB 1 100 280 67B300
dwell_store_result_if_lt_goto_rpm_accel_secondary_calc:     JLT     rpm_accel_secondary_calc             ; 31FE 1 100 280 CA05
                CMP     A, 0b0h                ; 3200 1 100 280 B5B0C2
                JLT     rpm_accel_clamp_store_carry_ram12e_bit2             ; 3203 1 100 280 CA2E
rpm_accel_secondary_calc:     CLRB    r0                     ; 3205 1 100 280 2015
                MOVB    r1, #018h              ; 3207 1 100 280 9918
                CMPB    0d9h, #02eh            ; 3209 1 100 280 C5D9C02E
                JGE     rpm_accel_secondary_calc_load_ram0b4             ; 320D 1 100 280 CD0B
                JBS     off(00120h).0, rpm_accel_secondary_calc_load_ram0b4 ; 320F 1 100 280 E82008
                CMPB    0dfh, #005h            ; 3212 1 100 280 C5DFC005
                JLT     rpm_accel_secondary_calc_load_ram0b4             ; 3216 1 100 280 CA02
                MOVB    r1, #000h              ; 3218 1 100 280 9900
rpm_accel_secondary_calc_load_ram0b4:     L       A, 0b4h                ; 321A 1 100 280 E5B4
                MUL                            ; 321C 1 100 280 9035
                MOVB    r4, #023h              ; 321E 1 100 280 9C23
                SLL     A                      ; 3220 1 100 280 53
                ROL     er1                    ; 3221 1 100 280 45B7
                JLT     rpm_accel_clamp             ; 3223 1 100 280 CA0D
                SLL     A                      ; 3225 1 100 280 53
                ROL     er1                    ; 3226 1 100 280 45B7
                JLT     rpm_accel_clamp             ; 3228 1 100 280 CA08
                LB      A, r3                  ; 322A 0 100 280 7B
                JNE     rpm_accel_clamp             ; 322B 0 100 280 CE05
                LB      A, r2                  ; 322D 0 100 280 7A
                CMPB    A, r4                  ; 322E 0 100 280 4C
                JGE     rpm_accel_clamp             ; 322F 0 100 280 CD01
                STB     A, r4                  ; 3231 0 100 280 8C
rpm_accel_clamp:     SC                             ; 3232 0 100 280 85
rpm_accel_clamp_store_carry_ram12e_bit2:     MB      off(0012eh).2, C       ; 3233 1 100 280 C42E3A
rpm_accel_clamp_load_r4:     LB      A, r4                  ; 3236 0 100 280 7C
                JEQ     rpm_accel_clamp_store_ram18d             ; 3237 0 100 280 C904
                JBR     off(00116h).7, rpm_accel_clamp_store_ram18d ; 3239 0 100 280 DF1601
                VCAL    7                      ; 323C 0 100 280 17
rpm_accel_clamp_store_ram18d:     STB     A, off(0018dh)         ; 323D 0 100 280 D48D
                CLR     er1                    ; 323F 0 100 280 4515
                JBS     off(0011dh).0, rpm_accel_clamp_clear_r0_2 ; 3241 0 100 280 E81D4B
                JBS     off(0011ah).6, rpm_accel_clamp_clear_r0_2 ; 3244 0 100 280 EE1A48
                MOVB    r0, #004h              ; 3247 0 100 280 9804
                JBS     off(0011ah).0, rpm_accel_clamp_clear_ram12d_bit7 ; 3249 0 100 280 E81A45
                LB      A, off(00198h)         ; 324C 0 100 280 F498
                JEQ     rpm_accel_clamp_clear_r0_2             ; 324E 0 100 280 C93F
                LB      A, off(00179h)         ; 3250 0 100 280 F479
                MOV     X1, #rpm_accel_clamp_tbl          ; 3252 0 100 280 604B69
                VCAL    1                      ; 3255 0 100 280 11
                CLR     er1                    ; 3256 0 100 280 4515
                MOVB    r0, off(00198h)        ; 3258 0 100 280 C49848
                DECB    r0                     ; 325B 0 100 280 B8
                JBS     off(00119h).5, rpm_accel_clamp_load_ram148 ; 325C 0 100 280 ED1938
                ; warning: had to flip DD
                CMP     A, 0b2h                ; 325F 1 100 280 B5B2C2
                JGE     rpm_accel_clamp_load_ram148             ; 3262 1 100 280 CD33
                MOV     er1, #0038ah           ; 3264 1 100 280 45988A03
                JBS     off(0012dh).7, rpm_accel_clamp_clear_r0_2 ; 3268 1 100 280 EF2D24
                L       A, #00177h             ; 326B 1 100 280 677701
                JBS     off(0012eh).0, rpm_accel_clamp_clear_r0 ; 326E 1 100 280 E82E09
                L       A, #000b5h             ; 3271 1 100 280 67B500
                JBS     off(00120h).0, rpm_accel_clamp_clear_r0 ; 3274 1 100 280 E82003
                L       A, #000b5h             ; 3277 1 100 280 67B500
rpm_accel_clamp_clear_r0:     CLRB    r0                     ; 327A 1 100 280 2015
                MOVB    r1, off(00194h)        ; 327C 1 100 280 C49449
                MUL                            ; 327F 1 100 280 9035
                SLL     A                      ; 3281 1 100 280 53
                ROL     er1                    ; 3282 1 100 280 45B7
                JLT     rpm_accel_clamp_load_er1             ; 3284 1 100 280 CA05
                SLL     A                      ; 3286 1 100 280 53
                ROL     er1                    ; 3287 1 100 280 45B7
                JGE     rpm_accel_clamp_clear_r0_2             ; 3289 1 100 280 CD04
rpm_accel_clamp_load_er1:     MOV     er1, #0ffffh           ; 328B 1 100 280 4598FFFF
rpm_accel_clamp_clear_r0_2:     CLRB    r0                     ; 328F 1 100 280 2015
rpm_accel_clamp_clear_ram12d_bit7:     RB      off(0012dh).7          ; 3291 1 100 280 C42D0F
                RB      off(0012eh).0          ; 3294 1 100 280 C42E08
rpm_accel_clamp_load_ram148:     MOV     off(00148h), er1       ; 3297 1 100 280 457C48
                MOVB    off(00198h), r0        ; 329A 1 100 280 207C98
                LB      A, off(0019fh)         ; 329D 0 100 280 F49F
                JEQ     rpm_accel_clamp_clear_acc_2             ; 329F 0 100 280 C916
                CMPB    0d8h, #000h            ; 32A1 0 100 280 C5D8C000
                JGE     rpm_accel_clamp_clear_acc             ; 32A5 0 100 280 CD0D
                CMPB    0ffh, #032h            ; 32A7 0 100 280 C5FFC032
                JLT     rpm_accel_clamp_store_ram19f             ; 32AB 0 100 280 CA08
                JBS     off(0011ah).2, rpm_accel_clamp_store_ram19f ; 32AD 0 100 280 EA1A05
                SUBB    A, #002h               ; 32B0 0 100 280 A602
                JGE     rpm_accel_clamp_store_ram19f             ; 32B2 0 100 280 CD01
rpm_accel_clamp_clear_acc:     CLRB    A                      ; 32B4 0 100 280 FA
rpm_accel_clamp_store_ram19f:     STB     A, off(0019fh)         ; 32B5 0 100 280 D49F
rpm_accel_clamp_clear_acc_2:     CLR     A                      ; 32B7 1 100 280 F9
                CMPB    0d9h, #02eh            ; 32B8 1 100 280 C5D9C02E
                JLT     injtimer_bank_b_store             ; 32BC 1 100 280 CA13
                L       A, off(00146h)         ; 32BE 1 100 280 E446
                JEQ     injtimer_bank_b_store             ; 32C0 1 100 280 C90F
                CLRB    r0                     ; 32C2 1 100 280 2015
                MOVB    r1, off(00185h)        ; 32C4 1 100 280 C48549
                MUL                            ; 32C7 1 100 280 9035
                SLL     A                      ; 32C9 1 100 280 53
                L       A, er1                 ; 32CA 1 100 280 35
                ROL     A                      ; 32CB 1 100 280 33
                JGE     injtimer_bank_b_store             ; 32CC 1 100 280 CD03
                L       A, #0ffffh             ; 32CE 1 100 280 67FFFF
injtimer_bank_b_store:     ST      A, off(0014ch)         ; 32D1 1 100 280 D44C
                L       A, off(00148h)         ; 32D3 1 100 280 E448
                CMP     A, off(0014ch)         ; 32D5 1 100 280 C74C
                JGE     injtimer_bank_c_check             ; 32D7 1 100 280 CD02
                L       A, off(0014ch)         ; 32D9 1 100 280 E44C
injtimer_bank_c_check:     L       A, ACC                 ; 32DB 1 100 280 E506
                JEQ     injtimer_bank_c_check_store_ram14e             ; 32DD 1 100 280 C907
                ADD     A, off(00142h)         ; 32DF 1 100 280 8742
                JGE     injtimer_bank_c_check_store_ram14e             ; 32E1 1 100 280 CD03
                L       A, #0ffffh             ; 32E3 1 100 280 67FFFF
injtimer_bank_c_check_store_ram14e:     ST      A, off(0014eh)         ; 32E6 1 100 280 D44E
                JBR     off(0011ah).2, injtimer_bank_c_check_load_ram146 ; 32E8 1 100 280 DA1A14
                MOV     DP, #00382h            ; 32EB 1 100 280 628203
                CLR     A                      ; 32EE 1 100 280 F9
                ST      A, [DP]                ; 32EF 1 100 280 D2
                INC     DP                     ; 32F0 1 100 280 72
                INC     DP                     ; 32F1 1 100 280 72
                ST      A, [DP]                ; 32F2 1 100 280 D2
                INC     DP                     ; 32F3 1 100 280 72
                INC     DP                     ; 32F4 1 100 280 72
                ST      A, [DP]                ; 32F5 1 100 280 D2
                INC     DP                     ; 32F6 1 100 280 72
                INC     DP                     ; 32F7 1 100 280 72
                ST      A, [DP]                ; 32F8 1 100 280 D2
                INC     DP                     ; 32F9 1 100 280 72
                INC     DP                     ; 32FA 1 100 280 72
                ST      A, [DP]                ; 32FB 1 100 280 D2
                J       accel_iac_store_if_ram11e_bit1_set             ; 32FC 1 100 280 03B233
injtimer_bank_c_check_load_ram146:     L       A, off(00146h)         ; 32FF 1 100 280 E446
                JEQ     injtimer_bank_c_check_store_er3             ; 3301 1 100 280 C92C
                LB      A, off(00181h)         ; 3303 0 100 280 F481
                MOVB    r0, off(00186h)        ; 3305 0 100 280 C48648
                MULB                           ; 3308 0 100 280 A234
                MOVB    r1, off(0017fh)        ; 330A 0 100 280 C47F49
                CLRB    r0                     ; 330D 0 100 280 2015
                MUL                            ; 330F 0 100 280 9035
                MOV     er0, er1               ; 3311 0 100 280 4548
                L       A, off(00152h)         ; 3313 1 100 280 E452
                MUL                            ; 3315 1 100 280 9035
                MOV     er0, er1               ; 3317 1 100 280 4548
                L       A, off(00146h)         ; 3319 1 100 280 E446
                MUL                            ; 331B 1 100 280 9035
                SRL     er1                    ; 331D 1 100 280 45E7
                ROR     A                      ; 331F 1 100 280 43
                SRL     er1                    ; 3320 1 100 280 45E7
                ROR     A                      ; 3322 1 100 280 43
                LB      A, r2                  ; 3323 0 100 280 7A
                L       A, ACC                 ; 3324 1 100 280 E506
                SWAP                           ; 3326 1 100 280 83
                CMPB    r3, #000h              ; 3327 1 100 280 23C000
                JEQ     injtimer_bank_c_check_store_er3             ; 332A 1 100 280 C903
                L       A, #0ffffh             ; 332C 1 100 280 67FFFF
injtimer_bank_c_check_store_er3:     ST      A, er3                 ; 332F 1 100 280 8B
                ST      A, off(00140h)         ; 3330 1 100 280 D440
                L       A, er3                 ; 3332 1 100 280 37
                CLR     er3                    ; 3333 1 100 280 4715
                MOVB    r6, off(0019fh)        ; 3335 1 100 280 C49F4E
                ADD     A, er3                 ; 3338 1 100 280 0B
                JLT     tipin_time_clamp             ; 3339 1 100 280 CA08
                ADD     A, off(00142h)         ; 333B 1 100 280 8742
                JLT     tipin_time_clamp             ; 333D 1 100 280 CA04
                ADD     A, off(00148h)         ; 333F 1 100 280 8748
                JGE     tipin_time_finalize             ; 3341 1 100 280 CD03
tipin_time_clamp:     L       A, #0ffffh             ; 3343 1 100 280 67FFFF
tipin_time_finalize:     ST      A, er0                 ; 3346 1 100 280 88
                LB      A, off(0018dh)         ; 3347 0 100 280 F48D
                EXTND                          ; 3349 1 100 280 F8
                MOV     er3, off(00144h)       ; 334A 1 100 280 B4444B
                CAL     tipin_time_finalize_sub_load_acc             ; 334D 1 100 280 32B544
                LB      A, off(0018bh)         ; 3350 0 100 280 F48B
                EXTND                          ; 3352 1 100 280 F8
                CAL     tipin_time_finalize_sub_load_acc             ; 3353 1 100 280 32B544
                CMP     A, #08000h             ; 3356 1 100 280 C60080
                JGE     tipin_time_finalize_add_acc             ; 3359 1 100 280 CD08
                ADD     A, er0                 ; 335B 1 100 280 08
                JGE     tipin_time_finalize_cmp_acc             ; 335C 1 100 280 CD08
tipin_time_finalize_load_imm:     L       A, #07fffh             ; 335E 1 100 280 67FF7F
                SJ      tipin_result_store             ; 3361 1 100 280 CB08
tipin_time_finalize_add_acc:     ADD     A, er0                 ; 3363 1 100 280 08
                JGE     tipin_result_store             ; 3364 1 100 280 CD05
tipin_time_finalize_cmp_acc:     CMP     A, #08000h             ; 3366 1 100 280 C60080
                JGE     tipin_time_finalize_load_imm             ; 3369 1 100 280 CDF3
tipin_result_store:     ST      A, er3                 ; 336B 1 100 280 8B
                MOV     X2, A                  ; 336C 1 100 280 51
                L       A, off(0013eh)         ; 336D 1 100 280 E43E
                MOV     er0, off(00150h)       ; 336F 1 100 280 B45048
                MUL                            ; 3372 1 100 280 9035
                SRL     er1                    ; 3374 1 100 280 45E7
                ROR     A                      ; 3376 1 100 280 43
                LB      A, r2                  ; 3377 0 100 280 7A
                L       A, ACC                 ; 3378 1 100 280 E506
                SWAP                           ; 337A 1 100 280 83
                CMPB    r3, #000h              ; 337B 1 100 280 23C000
                JEQ     injtimer_bank_a_calc             ; 337E 1 100 280 C903
                L       A, #0ffffh             ; 3380 1 100 280 67FFFF
injtimer_bank_a_calc:     ST      A, er2                 ; 3383 1 100 280 8A
                XCHG    A, er3                 ; 3384 1 100 280 4710
                VCAL    5                      ; 3386 1 100 280 15
                MOV     DP, #00382h            ; 3387 1 100 280 628203
                MOV     er0, [DP]              ; 338A 1 100 280 B248
                ST      A, [DP]                ; 338C 1 100 280 D2
                MOV     X1, #052dfh            ; 338D 1 100 280 60DF52
cylinder_ign_correct_loop:     INC     DP                     ; 3390 1 100 280 72
                INC     DP                     ; 3391 1 100 280 72
                L       A, er2                 ; 3392 1 100 280 36
                JBR     off(0011bh).1, cylinder_ign_correct_apply ; 3393 1 100 280 D91B0F
                ST      A, er0                 ; 3396 1 100 280 88
                CLR     A                      ; 3397 1 100 280 F9
                LCB     A, [X1]                ; 3398 1 100 280 90AA
                SWAP                           ; 339A 1 100 280 83
                MUL                            ; 339B 1 100 280 9035
                SLL     A                      ; 339D 1 100 280 53
                L       A, er1                 ; 339E 1 100 280 35
                ROL     A                      ; 339F 1 100 280 33
                JGE     cylinder_ign_correct_apply             ; 33A0 1 100 280 CD03
                L       A, #0ffffh             ; 33A2 1 100 280 67FFFF
cylinder_ign_correct_apply:     MOV     er3, X2                ; 33A5 1 100 280 914B
                XCHG    A, er3                 ; 33A7 1 100 280 4710
                VCAL    5                      ; 33A9 1 100 280 15
                ST      A, [DP]                ; 33AA 1 100 280 D2
                INC     X1                     ; 33AB 1 100 280 70
                CMP     DP, #0038ah            ; 33AC 1 100 280 92C08A03
                JLT     cylinder_ign_correct_loop             ; 33B0 1 100 280 CADE
accel_iac_store_if_ram11e_bit1_set:     JBS     off(0011eh).1, o2_trim_gate_common ; 33B2 0 100 280 E91E5F
                JBS     off(00118h).3, o2_trim_gate_common ; 33B5 0 100 280 EB185C
                L       A, off(00110h)         ; 33B8 1 100 280 E410
                AND     A, #08075h             ; 33BA 1 100 280 D67580
                JNE     o2_trim_gate_common             ; 33BD 1 100 280 CE55
                L       A, off(00112h)         ; 33BF 1 100 280 E412
                AND     A, #01420h             ; 33C1 1 100 280 D62014
                JNE     o2_trim_gate_common             ; 33C4 1 100 280 CE4E
                CMPB    0feh, #01eh            ; 33C6 1 100 280 C5FEC01E
                JLT     o2_trim_gate_common             ; 33CA 1 100 280 CA48
                CMPB    0d9h, #028h            ; 33CC 1 100 280 C5D9C028
                JGE     o2_trim_gate_common             ; 33D0 1 100 280 CD42
                LB      A, 0dah                ; 33D2 0 100 280 F5DA
                STB     A, r0                  ; 33D4 0 100 280 88
                JBS     off(0011ah).2, o2_store_prev_reading ; 33D5 0 100 280 EA1A23
                CMPB    off(00179h), #05ah     ; 33D8 0 100 280 C479C05A
                JGE     o2_gate_tps_check             ; 33DC 0 100 280 CD04
                MOVB    off(001e6h), #032h     ; 33DE 0 100 280 C4E69832
o2_gate_tps_check:     LB      A, off(001e6h)         ; 33E2 0 100 280 F4E6
                JNE     o2_gate_dp_set             ; 33E4 0 100 280 CE03
                SB      off(00131h).3          ; 33E6 0 100 280 C4311B
o2_gate_dp_set:     RC                             ; 33E9 0 100 280 95
                JBS     off(0011ah).4, dtc01_o2_latch ; 33EA 0 100 280 EC1A2F
                JBR     off(0011ch).3, dtc01_o2_latch ; 33ED 0 100 280 DB1C2C
                LB      A, #046h               ; 33F0 0 100 280 7746
                CMPB    A, off(00183h)         ; 33F2 0 100 280 C783
                JGE     dtc01_o2_latch             ; 33F4 0 100 280 CD26
                CMPB    r0, #003h              ; 33F6 0 100 280 20C003
                SJ      dtc01_o2_latch             ; 33F9 0 100 280 CB21
o2_store_prev_reading:     JBS     off(0011ah).3, o2_store_prev_reading_if_ram131_bit3_clr ; 33FB 0 100 280 EB1A02
                STB     A, off(001abh)         ; 33FE 0 100 280 D4AB
o2_store_prev_reading_if_ram131_bit3_clr:     JBR     off(00131h).3, o2_trim_gate_reset_dp ; 3400 0 100 280 DB3114
                CMPB    A, #04dh               ; 3403 0 100 280 C64D
                JLE     o2_trim_gate_common             ; 3405 0 100 280 CF0D
                JBS     off(00117h).2, o2_trim_gate_common ; 3407 0 100 280 EA170A
                LB      A, off(001abh)         ; 340A 0 100 280 F4AB
                SUBB    A, r0                  ; 340C 0 100 280 28
                JGE     o2_delta_magnitude_check             ; 340D 0 100 280 CD01
                VCAL    7                      ; 340F 0 100 280 17
o2_delta_magnitude_check:     CMPB    A, #002h               ; 3410 0 100 280 C602
                JLT     dtc01_o2_latch             ; 3412 0 100 280 CA08
o2_trim_gate_common:     RB      off(00131h).3          ; 3414 0 100 280 C4310B
o2_trim_gate_reset_dp:     MOVB    off(001e6h), #032h     ; 3417 0 100 280 C4E69832
                RC                             ; 341B 0 100 280 95
dtc01_o2_latch:     MB      098h.4, C              ; 341C 0 100 280 C5983C
                LB      A, off(0019dh)         ; 341F 0 100 280 F49D
                JEQ     o2_trim_step_start_load_imm             ; 3421 0 100 280 C90B
                MB      C, 09fh.1              ; 3423 0 100 280 C59F29
                JGE     o2_trim_step_start_subb_acc             ; 3426 0 100 280 CD02
                LB      A, #004h               ; 3428 0 100 280 7704
o2_trim_step_start_subb_acc:     SUBB    A, #001h               ; 342A 0 100 280 A601
                STB     A, off(0019dh)         ; 342C 0 100 280 D49D
o2_trim_step_start_load_imm:     LB      A, #000h               ; 342E 0 100 280 7700
                JBS     off(00114h).7, injector_effective_pw_skip_store_ram19b ; 3430 0 100 280 EF146C
                LB      A, #005h               ; 3433 0 100 280 7705
                JBS     off(0011dh).0, injector_effective_pw_skip_store_ram19b ; 3435 0 100 280 E81D67
                LB      A, #008h               ; 3438 0 100 280 7708
                JBS     off(00110h).2, o2_trim_step_start_store_r6 ; 343A 0 100 280 EA1047
                JBS     off(00110h).4, o2_trim_step_start_store_r6 ; 343D 0 100 280 EC1044
                JBS     off(00110h).5, o2_trim_step_start_store_r6 ; 3440 0 100 280 ED1041
                JBS     off(00111h).4, o2_trim_step_start_store_r6 ; 3443 0 100 280 EC113E
                LB      A, #007h               ; 3446 0 100 280 7707
                JBS     off(00116h).1, o2_trim_step_start_store_r6 ; 3448 0 100 280 E91639
                CLR     DP                     ; 344B 0 100 280 9215
                LB      A, 0d9h                ; 344D 0 100 280 F5D9
                CMPB    A, #0a5h               ; 344F 0 100 280 C6A5
                JGE     o2_trim_step_start_load_imm_2             ; 3451 0 100 280 CD0C
                ADD     DP, #00003h            ; 3453 0 100 280 92800300
                CMPB    A, #028h               ; 3457 0 100 280 C628
                JGE     o2_trim_step_start_load_imm_2             ; 3459 0 100 280 CD04
                ADD     DP, #00003h            ; 345B 0 100 280 92800300
o2_trim_step_start_load_imm_2:     LB      A, #02fh               ; 345F 0 100 280 772F
                JBR     off(00132h).4, o2_trim_step_start_cmp_acc ; 3461 0 100 280 DC3202
                LB      A, #028h               ; 3464 0 100 280 7728
o2_trim_step_start_cmp_acc:     CMPB    A, 0e2h                ; 3466 0 100 280 C5E2C2
                MB      off(00132h).4, C       ; 3469 0 100 280 C4323C
                LB      A, #09ch               ; 346C 0 100 280 779C
                JBR     off(00132h).3, o2_trim_step_start_cmp_acc_2 ; 346E 0 100 280 DB3202
                LB      A, #094h               ; 3471 0 100 280 7794
o2_trim_step_start_cmp_acc_2:     CMPB    A, 0e2h                ; 3473 0 100 280 C5E2C2
                MB      off(00132h).3, C       ; 3476 0 100 280 C4323B
                JLT     o2_trim_step_start_rom_load_051a3h_dp             ; 3479 0 100 280 CA05
                INC     DP                     ; 347B 0 100 280 72
                JBS     off(00132h).4, o2_trim_step_start_rom_load_051a3h_dp ; 347C 0 100 280 EC3201
                INC     DP                     ; 347F 0 100 280 72
o2_trim_step_start_rom_load_051a3h_dp:     LCB     A, 051a3h[DP]          ; 3480 0 100 280 92ABA351
o2_trim_step_start_store_r6:     STB     A, r6                  ; 3484 0 100 280 8E
                CLR     er0                    ; 3485 0 100 280 4415
                MOV     DP, #00382h            ; 3487 0 100 280 628203
                L       A, [DP]                ; 348A 1 100 280 E2
                MOV     er2, off(00136h)       ; 348B 1 100 280 B4364A
                DIV                            ; 348E 1 100 280 9037
                JLT     injector_effective_pw_skip             ; 3490 1 100 280 CA0C
                CMP     A, #0000bh             ; 3492 1 100 280 C60B00
                JGT     injector_effective_pw_skip             ; 3495 1 100 280 C807
                LB      A, ACC                 ; 3497 0 100 280 F506
                XCHGB   A, r6                  ; 3499 0 100 280 2610
                SUBB    A, r6                  ; 349B 0 100 280 2E
                JGE     injector_effective_pw_skip_store_ram19b             ; 349C 0 100 280 CD01
injector_effective_pw_skip:     CLRB    A                      ; 349E 0 100 280 FA
injector_effective_pw_skip_store_ram19b:     STB     A, off(0019bh)         ; 349F 0 100 280 D49B
                JBR     off(0011eh).2, injector_effective_pw_skip_load_imm ; 34A1 0 100 280 DA1E09
                LB      A, off(00179h)         ; 34A4 0 100 280 F479
                MOV     X1, #injector_effective_pw_skip_tbl_6          ; 34A6 0 100 280 603A6A
                VCAL    0                      ; 34A9 0 100 280 10
                J       injector_effective_pw_skip_clear_carry             ; 34AA 0 100 280 037635
injector_effective_pw_skip_load_imm:     LB      A, #038h               ; 34AD 0 100 280 7738
                JBS     off(0012fh).4, injector_effective_pw_skip_cmp_acc ; 34AF 0 100 280 EC2F02
                LB      A, #040h               ; 34B2 0 100 280 7740
injector_effective_pw_skip_cmp_acc:     CMPB    A, off(00178h)         ; 34B4 0 100 280 C778
                MB      off(0012fh).4, C       ; 34B6 0 100 280 C42F3C
                LB      A, #013h               ; 34B9 0 100 280 7713
                JBS     off(0012fh).5, injector_effective_pw_skip_cmp_acc_2 ; 34BB 0 100 280 ED2F02
                LB      A, #02ah               ; 34BE 0 100 280 772A
injector_effective_pw_skip_cmp_acc_2:     CMPB    A, 0e2h                ; 34C0 0 100 280 C5E2C2
                MB      off(0012fh).5, C       ; 34C3 0 100 280 C42F3D
                LB      A, #0c5h               ; 34C6 0 100 280 77C5
                JBS     off(0012fh).6, injector_effective_pw_skip_cmp_acc_3 ; 34C8 0 100 280 EE2F02
                LB      A, #0c8h               ; 34CB 0 100 280 77C8
injector_effective_pw_skip_cmp_acc_3:     CMPB    A, off(00179h)         ; 34CD 0 100 280 C779
                MB      off(0012fh).6, C       ; 34CF 0 100 280 C42F3E
                JLT     injector_effective_pw_skip_goto_3575             ; 34D2 0 100 280 CA06
                JBS     off(0011dh).2, injector_effective_pw_skip_goto_3575 ; 34D4 0 100 280 EA1D03
                JBR     off(00116h).1, injector_effective_pw_skip_if_ram119_bit6_set ; 34D7 0 100 280 D91603
injector_effective_pw_skip_goto_3575:     J       injector_effective_pw_skip_clear_acc_2             ; 34DA 0 100 280 037535
injector_effective_pw_skip_if_ram119_bit6_set:     JBS     off(00119h).6, injector_effective_pw_skip_goto_3575 ; 34DD 0 100 280 EE19FA
                L       A, off(00110h)         ; 34E0 1 100 280 E410
                AND     A, #0907ch             ; 34E2 1 100 280 D67C90
                JNE     injector_effective_pw_skip_goto_3575             ; 34E5 1 100 280 CEF3
                JBS     off(0011ah).0, injector_effective_pw_skip_goto_3575 ; 34E7 1 100 280 E81AF0
                JBS     off(0011ch).3, injector_effective_pw_skip_goto_3575 ; 34EA 1 100 280 EB1CED
                JBR     off(00117h).2, injector_effective_pw_skip_goto_3575 ; 34ED 1 100 280 DA17EA
                JBS     off(00113h).2, injector_effective_pw_skip_if_ram11b_bit2_clr ; 34F0 1 100 280 EA1306
                JBS     off(00113h).4, injector_effective_pw_skip_if_ram11b_bit2_clr ; 34F3 1 100 280 EC1303
                JBR     off(00110h).0, injector_effective_pw_skip_if_ram11b_bit0_clr ; 34F6 1 100 280 D81005
injector_effective_pw_skip_if_ram11b_bit2_clr:     JBR     off(0011bh).2, injector_effective_pw_skip_clear_acc_2 ; 34F9 1 100 280 DA1B79
                SJ      injector_effective_pw_skip_load_imm_2             ; 34FC 1 100 280 CB03
injector_effective_pw_skip_if_ram11b_bit0_clr:     JBR     off(0011bh).0, injector_effective_pw_skip_clear_acc_2 ; 34FE 1 100 280 D81B74
injector_effective_pw_skip_load_imm_2:     LB      A, #035h               ; 3501 0 100 280 7735
                JBR     off(0011fh).3, injector_effective_pw_skip_cmp_acc_4 ; 3503 0 100 280 DB1F02
                LB      A, #070h               ; 3506 0 100 280 7770
injector_effective_pw_skip_cmp_acc_4:     CMPB    A, 0d9h                ; 3508 0 100 280 C5D9C2
                JLE     injector_effective_pw_skip_clear_acc_2             ; 350B 0 100 280 CF68
                JBR     off(0012fh).4, injector_effective_pw_skip_clear_acc_2 ; 350D 0 100 280 DC2F65
                JBR     off(0012fh).5, injector_effective_pw_skip_clear_acc_2 ; 3510 0 100 280 DD2F62
                CLRB    r6                     ; 3513 0 100 280 2615
                JBS     off(0011dh).1, injector_effective_pw_skip_load_ram0ef ; 3515 0 100 280 E91D18
                LB      A, 0eeh                ; 3518 0 100 280 F5EE
                CMPB    A, #00eh               ; 351A 0 100 280 C60E
                JGE     injector_effective_pw_skip_clear_acc             ; 351C 0 100 280 CD31
                SUBB    A, #004h               ; 351E 0 100 280 A604
                JLT     injector_effective_pw_skip_clear_acc             ; 3520 0 100 280 CA2D
                MOV     DP, #injector_effective_pw_skip_tbl_2          ; 3522 0 100 280 624067
                JBS     off(00120h).0, injector_effective_pw_skip_load_x1 ; 3525 0 100 280 E82003
                MOV     DP, #injector_effective_pw_skip_tbl_3          ; 3528 0 100 280 62AE67
injector_effective_pw_skip_load_x1:     MOV     X1, 0cah               ; 352B 0 100 280 B5CA78
                SJ      injector_effective_pw_skip_load_r1             ; 352E 0 100 280 CB16
injector_effective_pw_skip_load_ram0ef:     LB      A, 0efh                ; 3530 0 100 280 F5EF
                CMPB    A, #00eh               ; 3532 0 100 280 C60E
                JGE     injector_effective_pw_skip_clear_acc             ; 3534 0 100 280 CD19
                SUBB    A, #004h               ; 3536 0 100 280 A604
                JLT     injector_effective_pw_skip_clear_acc             ; 3538 0 100 280 CA15
                MOV     DP, #tbl_zero_681c          ; 353A 0 100 280 621C68
                JBS     off(00120h).0, injector_effective_pw_skip_load_x1_2 ; 353D 0 100 280 E82003
                MOV     DP, #tbl_zero_688a          ; 3540 0 100 280 628A68
injector_effective_pw_skip_load_x1_2:     MOV     X1, 0cch               ; 3543 0 100 280 B5CC78
injector_effective_pw_skip_load_r1:     MOVB    r1, 0edh               ; 3546 0 100 280 C5ED49
                MOV     X2, 0c6h               ; 3549 0 100 280 B5C679
                CAL     tipin_gate_common_sub_load_r0             ; 354C 0 100 280 324545
injector_effective_pw_skip_clear_acc:     CLR     A                      ; 354F 1 100 280 F9
                LB      A, (00290h-00280h)[USP] ; 3550 0 100 280 F310
                MB      C, ACC.7               ; 3552 0 100 280 C5062F
                JLT     injector_effective_pw_skip_addb_acc             ; 3555 0 100 280 CA07
                ADDB    A, r6                  ; 3557 0 100 280 0E
                JGE     injector_effective_pw_skip_store_ram190             ; 3558 0 100 280 CD08
                LB      A, #0ffh               ; 355A 0 100 280 77FF
                SJ      injector_effective_pw_skip_store_ram190             ; 355C 0 100 280 CB04
injector_effective_pw_skip_addb_acc:     ADDB    A, r6                  ; 355E 0 100 280 0E
                JLT     injector_effective_pw_skip_store_ram190             ; 355F 0 100 280 CA01
                CLRB    A                      ; 3561 0 100 280 FA
injector_effective_pw_skip_store_ram190:     STB     A, off(00190h)         ; 3562 0 100 280 D490
                MOVB    r0, off(00195h)        ; 3564 0 100 280 C49548
                MULB                           ; 3567 0 100 280 A234
                L       A, ACC                 ; 3569 1 100 280 E506
                SLL     A                      ; 356B 1 100 280 53
                LB      A, ACCH                ; 356C 0 100 280 F507
                JGE     injector_effective_pw_skip_set_carry             ; 356E 0 100 280 CD02
                LB      A, #0ffh               ; 3570 0 100 280 77FF
injector_effective_pw_skip_set_carry:     SC                             ; 3572 0 100 280 85
                SJ      injector_effective_pw_skip_store_carry_ram11b_bit4             ; 3573 0 100 280 CB02
injector_effective_pw_skip_clear_acc_2:     CLRB    A                      ; 3575 0 100 280 FA
injector_effective_pw_skip_clear_carry:     RC                             ; 3576 0 100 280 95
injector_effective_pw_skip_store_carry_ram11b_bit4:     MB      off(0011bh).4, C       ; 3577 0 100 280 C41B3C
                STB     A, (00294h-00280h)[USP] ; 357A 0 100 280 D314
                RC                             ; 357C 0 100 280 95
                JEQ     injector_effective_pw_skip_store_carry_ram01f_bit4             ; 357D 0 100 280 C901
                SC                             ; 357F 0 100 280 85
injector_effective_pw_skip_store_carry_ram01f_bit4:     MB      P4SF.4, C              ; 3580 0 100 280 C51F3C
                MB      C, off(00116h).2       ; 3583 0 100 280 C4162A
                MB      off(0012dh).0, C       ; 3586 0 100 280 C42D38
                MB      C, off(00115h).3       ; 3589 0 100 280 C4152B
                MB      off(0012dh).1, C       ; 358C 0 100 280 C42D39
                LB      A, #019h               ; 358F 0 100 280 7719
                JBS     off(0012eh).4, injector_effective_pw_skip_cmp_acc_5 ; 3591 0 100 280 EC2E02
                LB      A, #01eh               ; 3594 0 100 280 771E
injector_effective_pw_skip_cmp_acc_5:     CMPB    A, 0dfh                ; 3596 0 100 280 C5DFC2
                MB      off(0012eh).4, C       ; 3599 0 100 280 C42E3C
                LB      A, #0cch               ; 359C 0 100 280 77CC
                JBS     off(0012eh).5, injector_effective_pw_skip_cmp_acc_6 ; 359E 0 100 280 ED2E02
                LB      A, #0cfh               ; 35A1 0 100 280 77CF
injector_effective_pw_skip_cmp_acc_6:     CMPB    A, off(00179h)         ; 35A3 0 100 280 C779
                MB      off(0012eh).5, C       ; 35A5 0 100 280 C42E3D
                LB      A, #0e3h               ; 35A8 0 100 280 77E3
                JBS     off(0012eh).6, injector_effective_pw_skip_cmp_acc_7 ; 35AA 0 100 280 EE2E02
                LB      A, #0e5h               ; 35AD 0 100 280 77E5
injector_effective_pw_skip_cmp_acc_7:     CMPB    A, off(00179h)         ; 35AF 0 100 280 C779
                MB      off(0012eh).6, C       ; 35B1 0 100 280 C42E3E
                LB      A, off(00179h)         ; 35B4 0 100 280 F479
                MOV     X1, #injector_effective_pw_skip_tbl          ; 35B6 0 100 280 60B656
                VCAL    0                      ; 35B9 0 100 280 10
                J       injector_effective_pw_skip_if_ram11a_bit1_clr             ; 35BA 0 100 280 03406F
injector_effective_pw_skip_subb_acc:     SUBB    A, #010h               ; 35BD 0 100 280 A610
                JGE     injector_effective_pw_skip_cmp_acc_8             ; 35BF 0 100 280 CD01
                CLRB    A                      ; 35C1 0 100 280 FA
injector_effective_pw_skip_cmp_acc_8:     CMPB    A, off(00178h)         ; 35C2 0 100 280 C778
                STB     A, off(001bbh)         ; 35C4 0 100 280 D4BB
                MB      off(0012fh).1, C       ; 35C6 0 100 280 C42F39
                LB      A, #044h               ; 35C9 0 100 280 7744
                CMPB    A, 0d9h                ; 35CB 0 100 280 C5D9C2
                JLT     injector_effective_pw_skip_store_carry_ram127_bit0             ; 35CE 0 100 280 CA03
                JBS     off(0011ch).3, injector_effective_pw_skip_clear_r0 ; 35D0 0 100 280 EB1C03
injector_effective_pw_skip_store_carry_ram127_bit0:     MB      off(00127h).0, C       ; 35D3 0 100 280 C42738
injector_effective_pw_skip_clear_r0:     CLRB    r0                     ; 35D6 0 100 280 2015
                J       injector_effective_pw_skip_if_ram121_bit0_set             ; 35D8 0 100 280 03806F
injector_effective_pw_skip_load_ram110:     L       A, off(00110h)         ; 35DB 1 100 280 E410
                AND     A, #0c0bch             ; 35DD 1 100 280 D6BCC0
                JNE     injector_effective_pw_skip_andb_r0             ; 35E0 1 100 280 CE20
                LB      A, off(00112h)         ; 35E2 0 100 280 F412
                ANDB    A, #031h               ; 35E4 0 100 280 D631
                JNE     injector_effective_pw_skip_andb_r0             ; 35E6 0 100 280 CE1A
                MOVB    r0, #0c0h              ; 35E8 0 100 280 98C0
                CMPB    0ffh, #032h            ; 35EA 0 100 280 C5FFC032
                JLT     injector_effective_pw_skip_andb_r0             ; 35EE 0 100 280 CA12
                JBS     off(00127h).0, injector_effective_pw_skip_andb_r0 ; 35F0 0 100 280 E8270F
                JBR     off(0012eh).4, injector_effective_pw_skip_andb_r0 ; 35F3 0 100 280 DC2E0C
                JBR     off(00120h).0, injector_effective_pw_skip_if_ram12e_bit5_set ; 35F6 0 100 280 D82003
                JBS     off(00124h).5, injector_effective_pw_skip_if_ram11d_bit1_set ; 35F9 0 100 280 ED2403
injector_effective_pw_skip_if_ram12e_bit5_set:     JBS     off(0012eh).5, injector_effective_pw_skip_if_ram12f_bit1_set ; 35FC 0 100 280 ED2E0B
injector_effective_pw_skip_if_ram11d_bit1_set:     JBS     off(0011dh).1, injector_effective_pw_skip_clear_ram1e2 ; 35FF 0 100 280 E91D12
injector_effective_pw_skip_andb_r0:     ANDB    r0, #07fh              ; 3602 0 100 280 20D07F
                RB      off(0011ah).1          ; 3605 0 100 280 C41A09
                SJ      injector_effective_pw_skip_load_ram1f1             ; 3608 0 100 280 CB1A
injector_effective_pw_skip_if_ram12f_bit1_set:     JBS     off(0012fh).1, injector_effective_pw_skip_load_ram1e2 ; 360A 0 100 280 E92F20
                JBS     off(0012eh).6, injector_effective_pw_skip_load_ram1e2 ; 360D 0 100 280 EE2E1D
                LB      A, off(001e2h)         ; 3610 0 100 280 F4E2
                JNE     injector_effective_pw_skip_set_ram11a_bit1             ; 3612 0 100 280 CE1D
injector_effective_pw_skip_clear_ram1e2:     CLRB    off(001e2h)            ; 3614 0 100 280 C4E215
                ANDB    r0, #07fh              ; 3617 0 100 280 20D07F
                RB      off(0011ah).1          ; 361A 0 100 280 C41A09
                JBS     off(00125h).4, injector_effective_pw_skip_load_ram1f1_2 ; 361D 0 100 280 EC2517
injector_effective_pw_skip_load_ram1f2:     LB      A, off(001f2h)         ; 3620 0 100 280 F4F2
                JNE     injector_effective_pw_skip_set_ram11d_bit1             ; 3622 0 100 280 CE1B
injector_effective_pw_skip_load_ram1f1:     MOVB    off(001f1h), #00ah     ; 3624 0 100 280 C4F1980A
injector_effective_pw_skip_clear_ram11d_bit1:     RB      off(0011dh).1          ; 3628 0 100 280 C41D09
                SJ      injector_effective_pw_skip_load_dp             ; 362B 0 100 280 CB15
injector_effective_pw_skip_load_ram1e2:     MOVB    off(001e2h), #00ah     ; 362D 0 100 280 C4E2980A
injector_effective_pw_skip_set_ram11a_bit1:     SB      off(0011ah).1          ; 3631 0 100 280 C41A19
                JBR     off(00125h).4, injector_effective_pw_skip_load_ram1f2 ; 3634 0 100 280 DC25E9
injector_effective_pw_skip_load_ram1f1_2:     LB      A, off(001f1h)         ; 3637 0 100 280 F4F1
                JNE     injector_effective_pw_skip_clear_ram11d_bit1             ; 3639 0 100 280 CEED
                MOVB    off(001f2h), #00ah     ; 363B 0 100 280 C4F2980A
injector_effective_pw_skip_set_ram11d_bit1:     SB      off(0011dh).1          ; 363F 0 100 280 C41D19
injector_effective_pw_skip_load_dp:     MOV     DP, #0c000h            ; 3642 0 100 280 6200C0
                RB      PSWH.0                 ; 3645 0 100 280 A208
                LB      A, (00226h-00280h)[USP] ; 3647 0 100 280 F3A6
                ANDB    A, #03fh               ; 3649 0 100 280 D63F
                ORB     A, r0                  ; 364B 0 100 280 68
                STB     A, (00226h-00280h)[USP] ; 364C 0 100 280 D3A6
                XORB    A, #024h               ; 364E 0 100 280 F624
                STB     A, [DP]                ; 3650 0 100 280 D2
                SB      PSWH.0                 ; 3651 0 100 280 A218
                LB      A, #0c8h               ; 3653 0 100 280 77C8
                JBS     off(0011ah).6, injector_effective_pw_skip_cmp_acc_9 ; 3655 0 100 280 EE1A02
                LB      A, #0cah               ; 3658 0 100 280 77CA
injector_effective_pw_skip_cmp_acc_9:     CMPB    A, off(00179h)         ; 365A 0 100 280 C779
                MB      off(0011ah).6, C       ; 365C 0 100 280 C41A3E
                LB      A, #0f4h               ; 365F 0 100 280 77F4
                JBS     off(00128h).1, injector_effective_pw_skip_cmp_acc_10 ; 3661 0 100 280 E92802
                LB      A, #0f6h               ; 3664 0 100 280 77F6
injector_effective_pw_skip_cmp_acc_10:     CMPB    A, off(00179h)         ; 3666 0 100 280 C779
                MB      off(00128h).1, C       ; 3668 0 100 280 C42839
                LB      A, #0c0h               ; 366B 0 100 280 77C0
                JBS     off(00128h).0, injector_effective_pw_skip_cmp_acc_11 ; 366D 0 100 280 E82802
                LB      A, #0c2h               ; 3670 0 100 280 77C2
injector_effective_pw_skip_cmp_acc_11:     CMPB    A, off(00179h)         ; 3672 0 100 280 C779
                MB      off(00128h).0, C       ; 3674 0 100 280 C42838
                SB      0a0h.2                 ; 3677 0 100 280 C5A01A
                MOV     DP, #00048h            ; 367A 0 100 280 624800
                MOV     X1, #0031eh            ; 367D 0 100 280 601E03
                CAL     learn_table2_check_sub_load_dp_ind             ; 3680 0 100 280 327D43
                MOV     IE, #00001h            ; 3683 0 100 280 B51A980100
                RB      off(00132h).2          ; 3688 0 100 280 C4320A
                L       A, off(0011ch)         ; 368B 1 100 280 E41C
                ST      A, (0021ch-00280h)[USP] ; 368D 1 100 280 D39C
                J       crank_cycle_er2_store_load_ram11a             ; 368F 1 100 280 033807
vcal_4:         NOP                            ; 3692 0 208 180 00
                NOP                            ; 3693 0 208 180 00
                NOP                            ; 3694 0 208 180 00
                RB      09eh.3                 ; 3695 0 208 180 C59E0B
                JEQ     vcal_4_clear_ram0a0_bit2             ; 3698 0 208 180 C902
                SJ      vcal_4_load_dp             ; 369A 0 208 180 CB2C
vcal_4_clear_ram0a0_bit2:     RB      0a0h.2                 ; 369C 0 208 180 C5A00A
                JEQ     vcal_4_call_4b80             ; 369F 0 208 180 C90B
                JBR     off(00234h).0, vcal_4_goto_3b2d ; 36A1 0 208 180 D83405
                RB      off(00235h).2          ; 36A4 0 208 180 C4350A
                JEQ     vcal_4_return             ; 36A7 0 208 180 C91E
vcal_4_goto_3b2d:     J       vcal_4_load_ram22c             ; 36A9 0 208 180 032D3B
vcal_4_call_4b80:     CAL     vcal_4_sub_pushs_lrb             ; 36AC 0 208 180 32804B
                NOP                            ; 36AF 0 208 180 00
                NOP                            ; 36B0 0 208 180 00
                NOP                            ; 36B1 0 208 180 00
                NOP                            ; 36B2 0 208 180 00
                NOP                            ; 36B3 0 208 180 00
                NOP                            ; 36B4 0 208 180 00
                NOP                            ; 36B5 0 208 180 00
                NOP                            ; 36B6 0 208 180 00
                RB      off(00235h).3          ; 36B7 0 208 180 C4350B
                JEQ     vcal_4_clear_ram235_bit4             ; 36BA 0 208 180 C903
                J       vcal_4_load_r0             ; 36BC 0 208 180 03CB41
vcal_4_clear_ram235_bit4:     RB      off(00235h).4          ; 36BF 0 208 180 C4350C
                JEQ     vcal_4_return             ; 36C2 0 208 180 C903
                J       vcal_4_load_r0_2             ; 36C4 0 208 180 03E042
vcal_4_return:     RT                             ; 36C7 0 208 180 01
vcal_4_load_dp:     MOV     DP, #00046h            ; 36C8 0 208 180 624600
                MOV     X1, #00318h            ; 36CB 0 208 180 601803
                CAL     learn_table2_check_sub_load_dp_ind             ; 36CE 0 208 180 327D43
                MOV     OS1, #0ffffh           ; 36D1 0 208 180 B54698FFFF
                CAL     learn_table2_check_sub_load_imm             ; 36D6 0 208 180 32B749
                MOVB    r0, #00ch              ; 36D9 0 208 180 980C
                MOV     DP, #001efh            ; 36DB 0 208 180 62EF01
                CAL     learn_table2_check_sub_clear_pswh_bit0             ; 36DE 0 208 180 32A949
                MOVB    r0, #00dh              ; 36E1 0 208 180 980D
                MOV     DP, #002f3h            ; 36E3 0 208 180 62F302
                CAL     learn_table2_check_sub_clear_pswh_bit0             ; 36E6 0 208 180 32A949
                MOVB    r0, #002h              ; 36E9 0 208 180 9802
                MOV     DP, #003b7h            ; 36EB 0 208 180 62B703
                CAL     learn_table2_check_sub_clear_pswh_bit0             ; 36EE 0 208 180 32A949
                MOV     DP, #000ach            ; 36F1 0 208 180 62AC00
                JBS     off(00212h).0, vcal_4_load_imm ; 36F4 0 208 180 E8127C
                RB      0a0h.1                 ; 36F7 0 208 180 C5A009
                JEQ     vcal_4_load_imm_2             ; 36FA 0 208 180 C97F
                JBR     off(00216h).1, vcal_4_cmp_ram0db ; 36FC 0 208 180 D91603
                J       vcal_4_clear_ram235_bit6             ; 36FF 0 208 180 038437
vcal_4_cmp_ram0db:     CMPB    0dbh, #044h            ; 3702 0 208 180 C5DBC044
                JLE     vcal_4_load_imm             ; 3706 0 208 180 CF6B
                RB      PSWH.0                 ; 3708 0 208 180 A208
                MOVB    r0, 0bah               ; 370A 0 208 180 C5BA48
                L       A, 0b8h                ; 370D 1 208 180 E5B8
                SUB     A, 0b6h                ; 370F 1 208 180 B5B6A2
                SB      PSWH.0                 ; 3712 1 208 180 A218
                SBCB    r0, #000h              ; 3714 1 208 180 20B000
                SRLB    r0                     ; 3717 1 208 180 20E7
                ROR     A                      ; 3719 1 208 180 43
                CMPB    r0, #000h              ; 371A 1 208 180 20C000
                JNE     vcal_4_clear_ram235_bit6             ; 371D 1 208 180 CE65
                RB      off(00235h).5          ; 371F 1 208 180 C4350D
                JNE     vss_clamp_common_clear_ram2bb             ; 3722 1 208 180 CE6D
                RB      off(00235h).6          ; 3724 1 208 180 C4350E
                JNE     vss_clamp_common_clear_ram2bb             ; 3727 1 208 180 CE68
                CMP     A, #002c2h             ; 3729 1 208 180 C6C202
                MB      off(00235h).6, C       ; 372C 1 208 180 C4353E
                JLT     vss_clamp_common_clear_ram2bb             ; 372F 1 208 180 CA60
                CMP     A, #02dfeh             ; 3731 1 208 180 C6FE2D
                JGE     vss_result_store             ; 3734 1 208 180 CD10
                MOV     er0, #01000h           ; 3736 1 208 180 44980010
                CMP     A, #00499h             ; 373A 1 208 180 C69904
                JLT     vss_scale_apply             ; 373D 1 208 180 CA04
                MOV     er0, #04000h           ; 373F 1 208 180 44980040
vss_scale_apply:     CAL     vss_scale_apply_sub_mul_acc             ; 3743 1 208 180 32DD44
vss_result_store:     ST      A, [DP]                ; 3746 1 208 180 D2
                ST      A, er2                 ; 3747 1 208 180 8A
vssSpeedNumerator    equ 0b1e1h ; VSS: speed = (2 * 10000h + vssSpeedNumerator) / pulse period (MOV er0,#2 / L A,# / DIV).
                                ; A number, not a table: it used to be bound to whatever label sat at this address.
                MOV     er0, #00002h           ; 3748 1 208 180 44980200
                L       A, #vssSpeedNumerator  ; 374C 1 208 180 67E1B1
                DIV                            ; 374F 1 208 180 9037
                ST      A, er1                 ; 3751 1 208 180 89
                L       A, er0                 ; 3752 1 208 180 34
                JNE     vss_clamp_max             ; 3753 1 208 180 CE03
                LB      A, r3                  ; 3755 0 208 180 7B
                JEQ     vss_clamp_common             ; 3756 0 208 180 C902
vss_clamp_max:     MOVB    r2, #0ffh              ; 3758 0 208 180 9AFF
vss_clamp_common:     LB      A, r2                  ; 375A 0 208 180 7A
vss_clamp_common_clear_pswh_bit0:     RB      PSWH.0                 ; 375B 0 208 180 A208
                XCHGB   A, 0dfh                ; 375D 0 208 180 C5DF10
                STB     A, 0ebh                ; 3760 0 208 180 D5EB
                SB      PSWH.0                 ; 3762 0 208 180 A218
                LB      A, #004h               ; 3764 0 208 180 7704
                JBS     off(00216h).5, vss_clamp_common_cmp_acc ; 3766 0 208 180 ED1602
                LB      A, #005h               ; 3769 0 208 180 7705
vss_clamp_common_cmp_acc:     CMPB    A, 0dfh                ; 376B 0 208 180 C5DFC2
                MB      off(00216h).5, C       ; 376E 0 208 180 C4163D
                SJ      vss_clamp_common_clear_ram2bb             ; 3771 0 208 180 CB1E
vcal_4_load_imm:     L       A, #vcal_4_tbl           ; 3773 1 208 180 67FB72
                RB      off(00235h).5          ; 3776 1 208 180 C4350D
                SJ      vss_result_store             ; 3779 1 208 180 CBCB
vcal_4_load_imm_2:     LB      A, #003h               ; 377B 0 208 180 7703
                CMPB    0f6h, A                ; 377D 0 208 180 C5F6C1
                JLT     vss_clamp_common_clear_ram2bb             ; 3780 0 208 180 CA0F
                STB     A, 0f6h                ; 3782 0 208 180 D5F6
vcal_4_clear_ram235_bit6:     RB      off(00235h).6          ; 3784 0 208 180 C4350E
                L       A, #0ffffh             ; 3787 1 208 180 67FFFF
                ST      A, [DP]                ; 378A 1 208 180 D2
                SB      off(00235h).5          ; 378B 1 208 180 C4351D
                CLRB    A                      ; 378E 0 208 180 FA
                SJ      vss_clamp_common_clear_pswh_bit0             ; 378F 0 208 180 CBCA
vss_clamp_common_clear_ram2bb:     CLRB    off(002bbh)            ; 3791 0 208 180 C4BB15
                CAL     vss_clamp_common_sub_load_dp_2             ; 3794 0 208 180 32724A
                CAL     vss_clamp_common_sub_load_dp_ind             ; 3797 0 208 180 32754A
                CAL     vss_clamp_common_sub_clear_pswh_bit0             ; 379A 0 208 180 32984A
                CAL     vss_clamp_common_sub_load_dp             ; 379D 0 208 180 32C849
                CAL     vss_clamp_common_sub_load_dp_2             ; 37A0 0 208 180 32724A
                CAL     vss_clamp_common_sub_load_dp_ind             ; 37A3 0 208 180 32754A
                LB      A, off(002bbh)         ; 37A6 0 208 180 F4BB
                JEQ     vss_clamp_common_load_carry_ram229_bit0             ; 37A8 0 208 180 C90E
                CMPB    A, #0ffh               ; 37AA 0 208 180 C6FF
                JEQ     vss_clamp_common_load_carry_ram229_bit0             ; 37AC 0 208 180 C90A
                CMPB    A, #0aah               ; 37AE 0 208 180 C6AA
                JEQ     vss_clamp_common_load_carry_ram229_bit0             ; 37B0 0 208 180 C906
                CMPB    A, #055h               ; 37B2 0 208 180 C655
                JEQ     vss_clamp_common_load_carry_ram229_bit0             ; 37B4 0 208 180 C902
                SJ      vss_clamp_common_if_ram220_bit0_clr             ; 37B6 0 208 180 CB14
vss_clamp_common_load_carry_ram229_bit0:     MB      C, off(00229h).0       ; 37B8 0 208 180 C42928
                MB      off(00229h).1, C       ; 37BB 0 208 180 C42939
                MB      C, off(00229h).2       ; 37BE 0 208 180 C4292A
                MB      off(00229h).3, C       ; 37C1 0 208 180 C4293B
                RORB    A                      ; 37C4 0 208 180 43
                MB      off(00229h).0, C       ; 37C5 0 208 180 C42938
                RORB    A                      ; 37C8 0 208 180 43
                MB      off(00229h).2, C       ; 37C9 0 208 180 C4293A
vss_clamp_common_if_ram220_bit0_clr:     JBR     off(00220h).0, vss_clamp_common_clear_ram2ba ; 37CC 0 208 180 D8202D
                JBS     off(00229h).4, vss_clamp_common_if_ram229_bit2_clr ; 37CF 0 208 180 EC2944
                J       vss_clamp_common_load_ram210             ; 37D2 0 208 180 03606F
vss_clamp_common_clear_ram229_bit4:     RB      off(00229h).4          ; 37D5 1 208 180 C4290C
                JBS     off(00213h).5, vss_clamp_common_clear_ram226_bit2 ; 37D8 1 208 180 ED131A
                JBS     off(00213h).6, vss_clamp_common_clear_ram226_bit2 ; 37DB 1 208 180 EE1317
                LB      A, off(002e5h)         ; 37DE 0 208 180 F4E5
                JNE     vss_clamp_common_load_ram2fa             ; 37E0 0 208 180 CE0F
                LB      A, off(002fah)         ; 37E2 0 208 180 F4FA
                JEQ     vss_clamp_common_load_ram2e5             ; 37E4 0 208 180 C905
                SB      off(00226h).2          ; 37E6 0 208 180 C4261A
                SJ      vss_clamp_common_load_ram2fb             ; 37E9 0 208 180 CB0D
vss_clamp_common_load_ram2e5:     MOVB    off(002e5h), #023h     ; 37EB 0 208 180 C4E59823
                SJ      vss_clamp_common_clear_ram226_bit2             ; 37EF 0 208 180 CB04
vss_clamp_common_load_ram2fa:     MOVB    off(002fah), #006h     ; 37F1 0 208 180 C4FA9806
vss_clamp_common_clear_ram226_bit2:     RB      off(00226h).2          ; 37F5 1 208 180 C4260A
vss_clamp_common_load_ram2fb:     MOVB    off(002fbh), #0a0h     ; 37F8 1 208 180 C4FB98A0
vss_clamp_common_clear_ram2ba:     CLRB    off(002bah)            ; 37FC 0 208 180 C4BA15
                J       vss_clamp_common_if_ram220_bit0_clr_2             ; 37FF 0 208 180 038638
vss_clamp_common_cmp_ram0d9:     CMPB    0d9h, #02eh            ; 3802 1 208 180 C5D9C02E
                JGE     vss_clamp_common_load_ram2fb_2             ; 3806 1 208 180 CD50
                LB      A, #053h               ; 3808 0 208 180 7753
                JBS     off(00229h).5, vss_clamp_common_cmp_acc_2 ; 380A 0 208 180 ED2902
                LB      A, #060h               ; 380D 0 208 180 7760
vss_clamp_common_cmp_acc_2:     CMPB    A, off(00289h)         ; 380F 0 208 180 C789
                MB      off(00229h).5, C       ; 3811 0 208 180 C4293D
                JGE     vss_clamp_common_load_ram2fb_2             ; 3814 0 208 180 CD42
vss_clamp_common_if_ram229_bit2_clr:     JBR     off(00229h).2, vss_clamp_common_if_ram229_bit0_clr ; 3816 0 208 180 DA2905
                JBR     off(00229h).0, vss_clamp_common_if_ram229_bit4_clr ; 3819 0 208 180 D8291A
                SJ      vss_clamp_common_if_ram229_bit4_clr_2             ; 381C 0 208 180 CB25
vss_clamp_common_if_ram229_bit0_clr:     JBR     off(00229h).0, vss_clamp_common_load_ram2ba_2 ; 381E 0 208 180 D82943
                JBR     off(00229h).4, vss_clamp_common_load_ram2fb_2 ; 3821 0 208 180 DC2934
                LB      A, 0dfh                ; 3824 0 208 180 F5DF
                MOV     X1, #050fah            ; 3826 0 208 180 60FA50
                VCAL    0                      ; 3829 0 208 180 10
                STB     A, off(002bah)         ; 382A 0 208 180 D4BA
                LB      A, 0dfh                ; 382C 0 208 180 F5DF
                MOV     X1, #05102h            ; 382E 0 208 180 600251
                VCAL    0                      ; 3831 0 208 180 10
                STB     A, off(002bch)         ; 3832 0 208 180 D4BC
                SJ      vss_clamp_common_clear_ram226_bit2_2             ; 3834 0 208 180 CB46
vss_clamp_common_if_ram229_bit4_clr:     JBR     off(00229h).4, vss_clamp_common_load_ram2fb_2 ; 3836 0 208 180 DC291F
                MOVB    off(002bah), #050h     ; 3839 0 208 180 C4BA9850
                MOVB    off(002bch), #080h     ; 383D 0 208 180 C4BC9880
                SJ      vss_clamp_common_clear_ram226_bit2_2             ; 3841 0 208 180 CB39
vss_clamp_common_if_ram229_bit4_clr_2:     JBR     off(00229h).4, vss_clamp_common_load_ram2fb_2 ; 3843 0 208 180 DC2912
                SB      off(00226h).2          ; 3846 0 208 180 C4261A
vss_clamp_common_load_ram2ba:     LB      A, off(002bah)         ; 3849 0 208 180 F4BA
                ADDB    A, off(002bch)         ; 384B 0 208 180 87BC
                JGE     vss_clamp_common_store_ram2ba             ; 384D 0 208 180 CD05
vss_clamp_common_clear_ram229_bit4_2:     RB      off(00229h).4          ; 384F 0 208 180 C4290C
                SJ      vss_clamp_common_clear_ram2ba_2             ; 3852 0 208 180 CB0B
vss_clamp_common_store_ram2ba:     STB     A, off(002bah)         ; 3854 0 208 180 D4BA
                SJ      vss_clamp_common_load_ram2fb_3             ; 3856 0 208 180 CB27
vss_clamp_common_load_ram2fb_2:     MOVB    off(002fbh), #0a0h     ; 3858 0 208 180 C4FB98A0
                SB      off(00226h).2          ; 385C 0 208 180 C4261A
vss_clamp_common_clear_ram2ba_2:     CLRB    off(002bah)            ; 385F 0 208 180 C4BA15
                SJ      vss_clamp_common_if_ram220_bit0_clr_2             ; 3862 0 208 180 CB22
vss_clamp_common_load_ram2ba_2:     LB      A, off(002bah)         ; 3864 0 208 180 F4BA
                JEQ     vss_clamp_common_load_ram2ba_3             ; 3866 0 208 180 C909
                CMPB    A, #0f4h               ; 3868 0 208 180 C6F4
                JGE     vss_clamp_common_load_ram2ba_3             ; 386A 0 208 180 CD05
                RB      off(00226h).2          ; 386C 0 208 180 C4260A
                SJ      vss_clamp_common_load_ram2ba             ; 386F 0 208 180 CBD8
vss_clamp_common_load_ram2ba_3:     MOVB    off(002bah), #0f4h     ; 3871 0 208 180 C4BA98F4
                MOVB    off(002bch), #004h     ; 3875 0 208 180 C4BC9804
                SB      off(00229h).4          ; 3879 0 208 180 C4291C
vss_clamp_common_clear_ram226_bit2_2:     RB      off(00226h).2          ; 387C 0 208 180 C4260A
vss_clamp_common_load_ram2fb_3:     LB      A, off(002fbh)         ; 387F 0 208 180 F4FB
                JEQ     vss_clamp_common_clear_ram229_bit4_2             ; 3881 0 208 180 C9CC
                JBS     off(0021dh).2, vss_clamp_common_clear_ram2ba_2 ; 3883 0 208 180 EA1DD9
vss_clamp_common_if_ram220_bit0_clr_2:     JBR     off(00220h).0, vss_clamp_common_load_stk ; 3886 0 208 180 D82034
                JBS     off(00213h).5, vss_clamp_common_load_stk ; 3889 0 208 180 ED1331
                JBS     off(00213h).6, vss_clamp_common_load_stk ; 388C 0 208 180 EE132E
                JBS     off(00216h).1, vss_clamp_common_load_stk ; 388F 0 208 180 E9162B
                CMPB    0dbh, #07dh            ; 3892 0 208 180 C5DBC07D
                JLT     vss_clamp_common_load_stk             ; 3896 0 208 180 CA25
                JBS     off(00229h).0, vss_clamp_common_clear_ram09a_bit4 ; 3898 0 208 180 E82911
                JBR     off(00229h).2, vss_clamp_common_load_stk ; 389B 0 208 180 DA291F
dtc30_at_signal_a_latch: SB      09ah.4                 ; 389E 0 208 180 C59A1C
                RB      09ah.5                 ; 38A1 0 208 180 C59A0D
                JBR     off(00229h).1, vss_clamp_common_if_ram221_bit1_clr ; 38A4 0 208 180 D92924
dtc31_at_signal_b_latch_2: SB      09ch.5                 ; 38A7 0 208 180 C59C1D
                SJ      vss_clamp_common_if_ram221_bit1_clr             ; 38AA 0 208 180 CB1F
vss_clamp_common_clear_ram09a_bit4:     RB      09ah.4                 ; 38AC 0 208 180 C59A0C
                JBS     off(00229h).2, vss_clamp_common_clear_ram09a_bit5 ; 38AF 0 208 180 EA2916
dtc31_at_signal_b_latch: SB      09ah.5                 ; 38B2 0 208 180 C59A1D
                JBR     off(00229h).3, vss_clamp_common_if_ram221_bit1_clr ; 38B5 0 208 180 DB2913
dtc30_at_signal_a_latch_2: SB      09ch.4                 ; 38B8 0 208 180 C59C1C
                SJ      vss_clamp_common_if_ram221_bit1_clr             ; 38BB 0 208 180 CB0E
vss_clamp_common_load_stk:     MOVB    (001a4h-00180h)[USP], #006h ; 38BD 0 208 180 C3249806
                MOVB    (001a5h-00180h)[USP], #006h ; 38C1 0 208 180 C3259806
                RB      09ah.4                 ; 38C5 0 208 180 C59A0C
vss_clamp_common_clear_ram09a_bit5:     RB      09ah.5                 ; 38C8 0 208 180 C59A0D
vss_clamp_common_if_ram221_bit1_clr:     JBR     off(00221h).1, idle_gate1_clear ; 38CB 0 208 180 D92122
                JBS     off(00212h).7, idle_gate1_clear ; 38CE 0 208 180 EF121F
                MB      C, off(00237h).0       ; 38D1 0 208 180 C43728
                MB      PSWH.6, C              ; 38D4 0 208 180 A23E
                MB      C, P4.3                ; 38D6 0 208 180 C5212B
                MB      off(00237h).0, C       ; 38D9 0 208 180 C43738
                JGE     vss_clamp_common_if_ne_goto_idle_gate1_timer_check             ; 38DC 0 208 180 CD03
                XORB    PSWH, #040h            ; 38DE 0 208 180 A2F040
vss_clamp_common_if_ne_goto_idle_gate1_timer_check:     JNE     idle_gate1_timer_check             ; 38E1 0 208 180 CE10
                CMPB    off(00289h), #00dh     ; 38E3 0 208 180 C489C00D
                JLT     idle_gate1_trigger             ; 38E7 0 208 180 CA03
                JBS     off(00238h).1, idle_gate1_timer_check ; 38E9 0 208 180 E93807
idle_gate1_trigger:     MOVB    off(002fdh), #00ah     ; 38EC 0 208 180 C4FD980A
idle_gate1_clear:     RC                             ; 38F0 0 208 180 95
                SJ      dtc24_code24_latch             ; 38F1 0 208 180 CB05
idle_gate1_timer_check:     LB      A, off(002fdh)         ; 38F3 0 208 180 F4FD
                JNE     idle_gate1_clear             ; 38F5 0 208 180 CEF9
                SC                             ; 38F7 0 208 180 85
dtc24_code24_latch:     MB      09ah.3, C              ; 38F8 0 208 180 C59A3B
                RB      0a0h.3                 ; 38FB 0 208 180 C5A00B
                JNE     idle_init_start_load_ram2f3             ; 38FE 0 208 180 CE04
                MOVB    off(002f3h), #010h     ; 3900 0 208 180 C4F39810
idle_init_start_load_ram2f3:     LB      A, off(002f3h)         ; 3904 0 208 180 F4F3
                MB      C, PSWH.6              ; 3906 0 208 180 A22E
                MB      off(0022ah).5, C       ; 3908 0 208 180 C42A3D
                SB      PSWL.4                 ; 390B 0 208 180 A31C
                MOV     X1, #003f1h            ; 390D 0 208 180 60F103
                LB      A, 00000h[X1]          ; 3910 0 208 180 F00000
                CMPB    A, 00008h[X1]          ; 3913 0 208 180 C00800C2
                JEQ     idle_init_start_inc_x1             ; 3917 0 208 180 C905
                STB     A, 00008h[X1]          ; 3919 0 208 180 D00800
                RB      PSWL.4                 ; 391C 0 208 180 A30C
idle_init_start_inc_x1:     INC     X1                     ; 391E 0 208 180 70
idle_init_start_load_tbl_x1:     L       A, 00000h[X1]          ; 391F 1 208 180 E00000
                CMP     A, 00008h[X1]          ; 3922 1 208 180 B00800C2
                JEQ     idle_init_start_inc_x1_2             ; 3926 1 208 180 C905
                ST      A, 00008h[X1]          ; 3928 1 208 180 D00800
                RB      PSWL.4                 ; 392B 1 208 180 A30C
idle_init_start_inc_x1_2:     INC     X1                     ; 392D 1 208 180 70
                INC     X1                     ; 392E 1 208 180 70
                CMP     X1, #003f7h            ; 392F 1 208 180 90C0F703
                JLT     idle_init_start_load_tbl_x1             ; 3933 1 208 180 CAEA
                MB      C, PSWL.4              ; 3935 1 208 180 A32C
                JLT     idle_init_start_load_ram2f4             ; 3937 1 208 180 CA04
                MOVB    off(002f4h), #005h     ; 3939 1 208 180 C4F49805
idle_init_start_load_ram2f4:     LB      A, off(002f4h)         ; 393D 0 208 180 F4F4
                MB      C, PSWH.6              ; 393F 0 208 180 A22E
                MB      off(0022ah).6, C       ; 3941 0 208 180 C42A3E
                L       A, TIMER               ; 3944 1 208 180 E556
                XCHG    A, 0d2h                ; 3946 1 208 180 B5D210
                ST      A, er0                 ; 3949 1 208 180 88
                SUB     A, 0d2h                ; 394A 1 208 180 B5D2A2
                NOP                            ; 394D 1 208 180 00
                CMP     A, #0ec78h             ; 394E 1 208 180 C678EC
                JGE     idle_init_start_load_dp             ; 3951 1 208 180 CD11
                MOV     DP, #0035eh            ; 3953 1 208 180 625E03
                L       A, er0                 ; 3956 1 208 180 34
                ST      A, [DP]                ; 3957 1 208 180 D2
                INC     DP                     ; 3958 1 208 180 72
                INC     DP                     ; 3959 1 208 180 72
                L       A, 0d2h                ; 395A 1 208 180 E5D2
                ST      A, [DP]                ; 395C 1 208 180 D2
                MOVB    0d4h, #057h            ; 395D 1 208 180 C5D49857
                J       fault_retry_check             ; 3961 1 208 180 034C07
idle_init_start_load_dp:     MOV     DP, #003b8h            ; 3964 1 208 180 62B803
                LB      A, [DP]                ; 3967 0 208 180 F2
                JNE     idle_init_start_load_ram0f8             ; 3968 0 208 180 CE03
                CLRB    0f8h                   ; 396A 0 208 180 C5F815
idle_init_start_load_ram0f8:     LB      A, 0f8h                ; 396D 0 208 180 F5F8
                CLRB    r0                     ; 396F 0 208 180 2015
                SBR     r0                     ; 3971 0 208 180 2011
                LB      A, r0                  ; 3973 0 208 180 78
                RB      PSWH.0                 ; 3974 0 208 180 A208
                STB     A, off(0021eh)         ; 3976 0 208 180 D41E
                STB     A, (0011eh-00180h)[USP] ; 3978 0 208 180 D39E
                SB      PSWH.0                 ; 397A 0 208 180 A218
                MOV     X1, #idle_init_start_tbl          ; 397C 0 208 180 604F6C
                CAL     idle_init_start_sub_load_r3             ; 397F 0 208 180 32464D
                MOV     DP, #003c4h            ; 3982 0 208 180 62C403
                STB     A, [DP]                ; 3985 0 208 180 D2
                MOV     X1, #idle_init_start_tbl_2          ; 3986 0 208 180 605F6C
                CAL     idle_init_start_sub_load_r3             ; 3989 0 208 180 32464D
                MOV     DP, #003c5h            ; 398C 0 208 180 62C503
                STB     A, [DP]                ; 398F 0 208 180 D2
                MOV     X1, #idle_init_start_tbl_3          ; 3990 0 208 180 606F6C
                CAL     idle_init_start_sub_load_r3             ; 3993 0 208 180 32464D
                MOV     DP, #003c6h            ; 3996 0 208 180 62C603
                STB     A, [DP]                ; 3999 0 208 180 D2
                MOV     X1, #idle_init_start_tbl_4          ; 399A 0 208 180 607F6C
                CAL     idle_init_start_sub_load_r3             ; 399D 0 208 180 32464D
                MOV     DP, #003c7h            ; 39A0 0 208 180 62C703
                STB     A, [DP]                ; 39A3 0 208 180 D2
                MOV     X1, #idle_init_start_tbl_5          ; 39A4 0 208 180 608F6C
                CAL     idle_init_start_sub_load_r3             ; 39A7 0 208 180 32464D
                MOV     DP, #003c8h            ; 39AA 0 208 180 62C803
                STB     A, [DP]                ; 39AD 0 208 180 D2
                MOV     X1, #idle_init_start_tbl_6          ; 39AE 0 208 180 609F6C
                CAL     idle_init_start_sub_load_r3             ; 39B1 0 208 180 32464D
                MOV     DP, #003c9h            ; 39B4 0 208 180 62C903
                STB     A, [DP]                ; 39B7 0 208 180 D2
                JBS     off(0022eh).2, idle_init_start_clear_acc ; 39B8 0 208 180 EA2E09
                MB      C, IRQH.1              ; 39BB 0 208 180 C51929
                JLT     idle_init_start_set_ram22e_bit2             ; 39BE 0 208 180 CA01
                RT                             ; 39C0 0 208 180 01
idle_init_start_set_ram22e_bit2:     SB      off(0022eh).2          ; 39C1 0 208 180 C42E1A
idle_init_start_clear_acc:     CLR     A                      ; 39C4 1 208 180 F9
                LB      A, off(002f9h)         ; 39C5 0 208 180 F4F9
                JNE     idle_init_start_load_r0             ; 39C7 0 208 180 CE07
                SB      off(00235h).4          ; 39C9 0 208 180 C4351C
                LB      A, #0c8h               ; 39CC 0 208 180 77C8
                STB     A, off(002f9h)         ; 39CE 0 208 180 D4F9
idle_init_start_load_r0:     MOVB    r0, #00ah              ; 39D0 0 208 180 980A
                DIVB                           ; 39D2 0 208 180 A236
                LB      A, r1                  ; 39D4 0 208 180 79
                JNE     idle_init_start_if_ram2f9_bit0_clr             ; 39D5 0 208 180 CE03
                SB      off(00235h).3          ; 39D7 0 208 180 C4351B
idle_init_start_if_ram2f9_bit0_clr:     JBR     off(002f9h).0, idle_init_start_load_er3 ; 39DA 0 208 180 D8F903
                J       idle_init_start_load_dp_2             ; 39DD 0 208 180 034D3A
idle_init_start_load_er3:     MOV     er3, off(00270h)       ; 39E0 0 208 180 B4704B
                L       A, ADCR4               ; 39E3 1 208 180 E570
                SUB     A, off(0026eh)         ; 39E5 1 208 180 A76E
                MB      off(00239h).5, C       ; 39E7 1 208 180 C4393D
                MB      PSWL.4, C              ; 39EA 1 208 180 A33C
                MOV     X1, #000a0h            ; 39EC 1 208 180 60A000
                MOV     X2, #00800h            ; 39EF 1 208 180 610008
                JGE     idle_init_start_load_er0             ; 39F2 1 208 180 CD01
                VCAL    7                      ; 39F4 1 208 180 17
idle_init_start_load_er0:     MOV     er0, #0b000h           ; 39F5 1 208 180 449800B0
                CMP     A, er0                 ; 39F9 1 208 180 48
                JGE     idle_init_start_load_imm             ; 39FA 1 208 180 CD01
                ST      A, er0                 ; 39FC 1 208 180 88
idle_init_start_load_imm:     L       A, #00550h             ; 39FD 1 208 180 675005
                CAL     idle_helper2             ; 3A00 1 208 180 321D4A
                MOV     DP, A                  ; 3A03 1 208 180 52
                L       A, #00120h             ; 3A04 1 208 180 672001
                CAL     idle_helper2             ; 3A07 1 208 180 321D4A
                ST      A, off(00272h)         ; 3A0A 1 208 180 D472
                ST      A, PWM0CMP                ; 3A0C 1 208 180 D52E
                CLRB    A                      ; 3A0E 0 208 180 FA
                JLT     idle_init_start_store_ram2e3             ; 3A0F 0 208 180 CA05
                L       A, DP                  ; 3A11 1 208 180 42
                ST      A, off(00270h)         ; 3A12 1 208 180 D470
                LB      A, #0ffh               ; 3A14 0 208 180 77FF
idle_init_start_store_ram2e3:     STB     A, off(002e3h)         ; 3A16 0 208 180 D4E3
                LB      A, #010h               ; 3A18 0 208 180 7710
                MOV     DP, #003dbh            ; 3A1A 0 208 180 62DB03
                CMPB    [DP], #0ffh            ; 3A1D 0 208 180 C2C0FF
                JGT     transit_flag_common             ; 3A20 0 208 180 C80C
                RB      TRNSIT.5                 ; 3A22 0 208 180 C5290D
                JNE     transit_flag_common             ; 3A25 0 208 180 CE07
                SC                             ; 3A27 0 208 180 85
                LB      A, off(002c6h)         ; 3A28 0 208 180 F4C6
                JEQ     transit_flag_common_store_carry_ram233_bit7             ; 3A2A 0 208 180 C903
                SUBB    A, #001h               ; 3A2C 0 208 180 A601
transit_flag_common:     RC                             ; 3A2E 0 208 180 95
transit_flag_common_store_carry_ram233_bit7:     MB      off(00233h).7, C       ; 3A2F 0 208 180 C4333F
                STB     A, off(002c6h)         ; 3A32 0 208 180 D4C6
                JBS     off(00212h).7, transit_flag_common_goto_6ed7 ; 3A34 0 208 180 EF1213
                CAL     transit_flag_common_sub_load_dp             ; 3A37 0 208 180 32D06E
                JLT     transit_flag_common_set_dp_ind             ; 3A3A 0 208 180 CA06
                RB      [DP].0                 ; 3A3C 0 208 180 C208
                JNE     transit_flag_common_call_4afe             ; 3A3E 0 208 180 CE06
                SJ      transit_flag_common_goto_6ed7             ; 3A40 0 208 180 CB08
transit_flag_common_set_dp_ind:     SB      [DP].0                 ; 3A42 0 208 180 C218
                JNE     transit_flag_common_goto_6ed7             ; 3A44 0 208 180 CE04
transit_flag_common_call_4afe:     CAL     cfgvariant_checksum_loop_load_dp             ; 3A46 0 208 180 32FE4A
                STB     A, [DP]                ; 3A49 0 208 180 D2
transit_flag_common_goto_6ed7:     J       transit_flag_common_clear_ram232_bit6             ; 3A4A 0 208 180 03D76E
idle_init_start_load_dp_2:     MOV     DP, #0c000h            ; 3A4D 0 208 180 6200C0
                RB      PSWH.0                 ; 3A50 0 208 180 A208
                LB      A, off(00226h)         ; 3A52 0 208 180 F426
                XORB    A, #024h               ; 3A54 0 208 180 F624
                STB     A, [DP]                ; 3A56 0 208 180 D2
                CMPB    A, [DP]                ; 3A57 0 208 180 C2C2
                MB      C, PSWH.6              ; 3A59 0 208 180 A22E
                SB      PSWH.0                 ; 3A5B 0 208 180 A218
                JLT     idle_init_start_if_ram2f9_bit1_clr             ; 3A5D 0 208 180 CA10
                MB      C, 09eh.0              ; 3A5F 0 208 180 C59E28
                JLT     idle_init_start_if_ram2f9_bit1_clr             ; 3A62 0 208 180 CA0B
                JBR     off(00232h).7, idle_init_start_call_4aca ; 3A64 0 208 180 DF3205
                LB      A, #051h               ; 3A67 0 208 180 7751
                CAL     idle_init_start_sub_cmp_ram0d7             ; 3A69 0 208 180 32F849
idle_init_start_call_4aca:     CAL     calchecksum_loop_sub_load_dp             ; 3A6C 0 208 180 32CA4A
idle_init_start_if_ram2f9_bit1_clr:     JBR     off(002f9h).1, idle_init_start_clear_carry ; 3A6F 0 208 180 D9F903
                J       transit_flag_common_return             ; 3A72 0 208 180 032C3B
idle_init_start_clear_carry:     RC                             ; 3A75 0 208 180 95
                JBS     off(00211h).3, dtc12_egr_latch ; 3A76 0 208 180 EB110E
                CMPB    off(00289h), #0c0h     ; 3A79 0 208 180 C489C0C0
                MB      off(0022eh).0, C       ; 3A7D 0 208 180 C42E38
                JGE     dtc12_egr_latch             ; 3A80 0 208 180 CD05
                LB      A, #0fah               ; 3A82 0 208 180 77FA
                CMPB    A, ADCR3H              ; 3A84 0 208 180 C56FC2
dtc12_egr_latch:     MB      099h.0, C              ; 3A87 0 208 180 C59938
                JGE     idle_init_start_load_adcr3h             ; 3A8A 0 208 180 CD06
                MOVB    off(002ebh), #01eh     ; 3A8C 0 208 180 C4EB981E
                SJ      idle_init_start_load_ram2ec             ; 3A90 0 208 180 CB4D
idle_init_start_load_adcr3h:     LB      A, ADCR3H              ; 3A92 0 208 180 F56F
                STB     A, off(00292h)         ; 3A94 0 208 180 D492
                SUBB    A, off(00293h)         ; 3A96 0 208 180 A793
                JGE     idle_init_start_if_ram219_bit6_set             ; 3A98 0 208 180 CD01
                CLRB    A                      ; 3A9A 0 208 180 FA
idle_init_start_if_ram219_bit6_set:     JBS     off(00219h).6, idle_init_start_load_ram2ec ; 3A9B 0 208 180 EE1941
                RC                             ; 3A9E 0 208 180 95
                JBR     off(00211h).3, idle_init_start_store_carry_ram219_bit6 ; 3A9F 0 208 180 DB110A
                STB     A, r0                  ; 3AA2 0 208 180 88
                LB      A, #070h               ; 3AA3 0 208 180 7770
                CMPB    A, r0                  ; 3AA5 0 208 180 48
                JLT     idle_init_start_store_carry_ram219_bit6             ; 3AA6 0 208 180 CA04
                CMPB    r0, #002h              ; 3AA8 0 208 180 20C002
                LB      A, r0                  ; 3AAB 0 208 180 78
idle_init_start_store_carry_ram219_bit6:     MB      off(00219h).6, C       ; 3AAC 0 208 180 C4193E
                JLT     idle_init_start_load_ram2ec             ; 3AAF 0 208 180 CA2E
                STB     A, off(00291h)         ; 3AB1 0 208 180 D491
                JBR     off(0022eh).0, idle_init_start_load_ram2ec ; 3AB3 0 208 180 D82E29
                CMPB    0dbh, #068h            ; 3AB6 0 208 180 C5DBC068
                JLT     idle_init_start_load_ram2ec             ; 3ABA 0 208 180 CA23
                CMPB    0e2h, #030h            ; 3ABC 0 208 180 C5E2C030
                JLT     idle_init_start_load_ram2ec             ; 3AC0 0 208 180 CA1D
                CMPB    off(00294h), #018h     ; 3AC2 0 208 180 C494C018
                JLT     idle_init_start_load_ram2ec             ; 3AC6 0 208 180 CA17
                SUBB    A, off(00294h)         ; 3AC8 0 208 180 A794
                RB      off(0022eh).1          ; 3ACA 0 208 180 C42E09
                MB      off(0022eh).1, C       ; 3ACD 0 208 180 C42E39
                JEQ     idle_init_start_if_ram22e_bit1_clr             ; 3AD0 0 208 180 C905
                XORB    PSWH, #080h            ; 3AD2 0 208 180 A2F080
                JLT     idle_init_start_load_ram2ec             ; 3AD5 0 208 180 CA08
idle_init_start_if_ram22e_bit1_clr:     JBR     off(0022eh).1, idle_init_start_cmp_acc ; 3AD7 0 208 180 D92E01
                VCAL    7                      ; 3ADA 0 208 180 17
idle_init_start_cmp_acc:     CMPB    A, #006h               ; 3ADB 0 208 180 C606
                JGT     idle_init_start_load_ram2ec_2             ; 3ADD 0 208 180 C804
idle_init_start_load_ram2ec:     MOVB    off(002ech), #005h     ; 3ADF 0 208 180 C4EC9805
idle_init_start_load_ram2ec_2:     LB      A, off(002ech)         ; 3AE3 0 208 180 F4EC
                MB      C, PSWH.6              ; 3AE5 0 208 180 A22E
dtc12_egr_latch_2: MB      099h.1, C              ; 3AE7 0 208 180 C59939
                CLR     A                      ; 3AEA 1 208 180 F9
                CLR     DP                     ; 3AEB 1 208 180 9215
                RC                             ; 3AED 1 208 180 95
                LB      A, off(00294h)         ; 3AEE 0 208 180 F494
                JEQ     idle_init_start_load_ram276             ; 3AF0 0 208 180 C928
                L       A, off(00274h)         ; 3AF2 1 208 180 E474
                JNE     idle_init_start_store_er3             ; 3AF4 1 208 180 CE03
                L       A, #04e20h             ; 3AF6 1 208 180 67204E
idle_init_start_store_er3:     ST      A, er3                 ; 3AF9 1 208 180 8B
                LB      A, off(00291h)         ; 3AFA 0 208 180 F491
                SUBB    A, off(00294h)         ; 3AFC 0 208 180 A794
                MB      PSWL.4, C              ; 3AFE 0 208 180 A33C
                JGE     idle_init_start_store_r0             ; 3B00 0 208 180 CD01
                VCAL    7                      ; 3B02 0 208 180 17
idle_init_start_store_r0:     STB     A, r0                  ; 3B03 0 208 180 88
                CLRB    r1                     ; 3B04 0 208 180 2115
                L       A, #000a0h             ; 3B06 1 208 180 67A000
                MOV     X1, #00000h            ; 3B09 1 208 180 600000
                MOV     X2, #09fffh            ; 3B0C 1 208 180 61FF9F
                CAL     mul_then_clamp_x1x2_2             ; 3B0F 1 208 180 32224A
                MOV     DP, A                  ; 3B12 1 208 180 52
                ST      A, er3                 ; 3B13 1 208 180 8B
                L       A, #00200h             ; 3B14 1 208 180 670002
                CAL     mul_then_clamp_x1x2_2             ; 3B17 1 208 180 32224A
idle_init_start_load_ram276:     MOV     off(00276h), A         ; 3B1A 1 208 180 B4768A
                JLT     idle_init_start_load_imm_2             ; 3B1D 1 208 180 CA03
                L       A, DP                  ; 3B1F 1 208 180 42
                ST      A, off(00274h)         ; 3B20 1 208 180 D474
idle_init_start_load_imm_2:     L       A, #0a000h             ; 3B22 1 208 180 6700A0
                SUB     A, off(00276h)         ; 3B25 1 208 180 A776
                ST      A, PWM1CMP                ; 3B27 1 208 180 D53E
                SB      off(00235h).2          ; 3B29 1 208 180 C4351A
transit_flag_common_return:     RT                             ; 3B2C 0 208 180 01
vcal_4_load_ram22c:     LB      A, off(0022ch)         ; 3B2D 0 208 180 F42C
                MB      C, off(00224h).5       ; 3B2F 0 208 180 C4242D
                MB      ACC.0, C               ; 3B32 0 208 180 C50638
                MB      C, off(00224h).0       ; 3B35 0 208 180 C42428
                MB      ACC.1, C               ; 3B38 0 208 180 C50639
                MB      C, off(00216h).7       ; 3B3B 0 208 180 C4162F
                MB      ACC.3, C               ; 3B3E 0 208 180 C5063B
                MB      C, off(00216h).6       ; 3B41 0 208 180 C4162E
                MB      ACC.7, C               ; 3B44 0 208 180 C5063F
                STB     A, r0                  ; 3B47 0 208 180 88
                LB      A, off(0022dh)         ; 3B48 0 208 180 F42D
                XORB    A, r0                  ; 3B4A 0 208 180 20F2
                XNBL    A, off(00239h)         ; 3B4C 0 208 180 8439
                MOVB    off(0022dh), r0        ; 3B4E 0 208 180 207C2D
                LB      A, off(0029eh)         ; 3B51 0 208 180 F49E
                SUBB    A, 0ddh                ; 3B53 0 208 180 C5DDA2
                JGE     vcal_4_store_ram29d             ; 3B56 0 208 180 CD03
                STB     A, r0                  ; 3B58 0 208 180 88
                CLRB    A                      ; 3B59 0 208 180 FA
                SUBB    A, r0                  ; 3B5A 0 208 180 28
vcal_4_store_ram29d:     STB     A, off(0029dh)         ; 3B5B 0 208 180 D49D
                MB      off(0022ch).7, C       ; 3B5D 0 208 180 C42C3F
                MOVB    off(0029eh), 0ddh      ; 3B60 0 208 180 C5DD7C9E
                LB      A, #0ddh               ; 3B64 0 208 180 77DD
                JBS     off(0022fh).2, idle_temp_hyst2 ; 3B66 0 208 180 EA2F02
                LB      A, #0e0h               ; 3B69 0 208 180 77E0
idle_temp_hyst2:     CMPB    A, off(00289h)         ; 3B6B 0 208 180 C789
                MB      off(0022fh).2, C       ; 3B6D 0 208 180 C42F3A
                LB      A, #060h               ; 3B70 0 208 180 7760
                JBS     off(00239h).7, idle_temp_hyst3 ; 3B72 0 208 180 EF3902
                LB      A, #06dh               ; 3B75 0 208 180 776D
idle_temp_hyst3:     CMPB    A, off(00289h)         ; 3B77 0 208 180 C789
                MB      off(00239h).7, C       ; 3B79 0 208 180 C4393F
                LB      A, off(0021eh)         ; 3B7C 0 208 180 F41E
                ANDB    A, #078h               ; 3B7E 0 208 180 D678
                JEQ     idle_temp_hyst3_load_adcr2h             ; 3B80 0 208 180 C91E
                RB      off(00232h).3          ; 3B82 0 208 180 C4320B
                RB      off(00216h).6          ; 3B85 0 208 180 C4160E
                L       A, #01000h             ; 3B88 1 208 180 670010
                JBS     off(0021eh).3, idle_temp_hyst3_goto_4192 ; 3B8B 1 208 180 EB1E0F
                L       A, #01c00h             ; 3B8E 1 208 180 67001C
                JBS     off(0021eh).4, idle_temp_hyst3_goto_4192 ; 3B91 1 208 180 EC1E09
                L       A, #02b00h             ; 3B94 1 208 180 67002B
                JBS     off(0021eh).5, idle_temp_hyst3_goto_4192 ; 3B97 1 208 180 ED1E03
                L       A, #03fffh             ; 3B9A 1 208 180 67FF3F
idle_temp_hyst3_goto_4192:     J       idle_temp_hyst3_if_eq_goto_41a6             ; 3B9D 1 208 180 039241
idle_temp_hyst3_load_adcr2h:     LB      A, ADCR2H              ; 3BA0 0 208 180 F56D
                STB     A, 0dch                ; 3BA2 0 208 180 D5DC
                LB      A, #0e0h               ; 3BA4 0 208 180 77E0
                JBS     off(0022fh).1, idle_temp_hyst3_cmp_acc ; 3BA6 0 208 180 E92F02
                LB      A, #0f0h               ; 3BA9 0 208 180 77F0
idle_temp_hyst3_cmp_acc:     CMPB    A, 0dch                ; 3BAB 0 208 180 C5DCC2
                MB      off(0022fh).1, C       ; 3BAE 0 208 180 C42F39
                MOV     X1, #055a5h            ; 3BB1 0 208 180 60A555
                LB      A, off(00289h)         ; 3BB4 0 208 180 F489
                VCAL    0                      ; 3BB6 0 208 180 10
                MOVB    r0, 0dch               ; 3BB7 0 208 180 C5DC48
                MULB                           ; 3BBA 0 208 180 A234
                L       A, ACC                 ; 3BBC 1 208 180 E506
                SLL     A                      ; 3BBE 1 208 180 53
                JLT     idle_temp_hyst3_load_imm             ; 3BBF 1 208 180 CA05
                SLL     A                      ; 3BC1 1 208 180 53
                LB      A, ACCH                ; 3BC2 0 208 180 F507
                JGE     idle_temp_hyst3_load_x1             ; 3BC4 0 208 180 CD02
idle_temp_hyst3_load_imm:     LB      A, #0ffh               ; 3BC6 0 208 180 77FF
idle_temp_hyst3_load_x1:     MOV     X1, #055afh            ; 3BC8 0 208 180 60AF55
                VCAL    1                      ; 3BCB 0 208 180 11
                MOV     X2, A                  ; 3BCC 0 208 180 51
                MOV     X1, #0559bh            ; 3BCD 0 208 180 609B55
                LB      A, off(00289h)         ; 3BD0 0 208 180 F489
                VCAL    0                      ; 3BD2 0 208 180 10
                STB     A, ACCH                ; 3BD3 0 208 180 D507
                CLRB    A                      ; 3BD5 0 208 180 FA
                MOV     er0, X2                ; 3BD6 0 208 180 9148
                MUL                            ; 3BD8 0 208 180 9035
                L       A, ACC                 ; 3BDA 1 208 180 E506
                SLL     A                      ; 3BDC 1 208 180 53
                ROL     er1                    ; 3BDD 1 208 180 45B7
                JLT     idle_temp_hyst3_load_imm_2             ; 3BDF 1 208 180 CA05
                SLL     A                      ; 3BE1 1 208 180 53
                L       A, er1                 ; 3BE2 1 208 180 35
                ROL     A                      ; 3BE3 1 208 180 33
                JGE     idle_temp_hyst3_if_ram225_bit3_set             ; 3BE4 1 208 180 CD03
idle_temp_hyst3_load_imm_2:     L       A, #0ffffh             ; 3BE6 1 208 180 67FFFF
idle_temp_hyst3_if_ram225_bit3_set:     JBS     off(00225h).3, idle_temp_hyst3_store_er3 ; 3BE9 1 208 180 EB2507
                MOVB    r1, #0e6h              ; 3BEC 1 208 180 99E6
                CLRB    r0                     ; 3BEE 1 208 180 2015
                MUL                            ; 3BF0 1 208 180 9035
                L       A, er1                 ; 3BF2 1 208 180 35
idle_temp_hyst3_store_er3:     ST      A, er3                 ; 3BF3 1 208 180 8B
                SB      off(00232h).3          ; 3BF4 1 208 180 C4321B
                JEQ     idle_temp_hyst3_clear_r5             ; 3BF7 1 208 180 C957
                JBS     off(00234h).0, idle_temp_hyst3_clear_acc ; 3BF9 1 208 180 E8340A
                L       A, off(00210h)         ; 3BFC 1 208 180 E410
                AND     A, #02054h             ; 3BFE 1 208 180 D65420
                JNE     idle_temp_hyst3_clear_acc             ; 3C01 1 208 180 CE03
                JBR     off(00212h).0, idle_temp_hyst3_load_r2 ; 3C03 1 208 180 D81211
idle_temp_hyst3_clear_acc:     CLRB    A                      ; 3C06 0 208 180 FA
                STB     A, r0                  ; 3C07 0 208 180 88
                STB     A, r4                  ; 3C08 0 208 180 8C
                MOVB    r1, #018h              ; 3C09 0 208 180 9918
                MOVB    r5, off(002c3h)        ; 3C0B 0 208 180 C4C34D
                L       A, er3                 ; 3C0E 1 208 180 37
                MOV     er3, off(00258h)       ; 3C0F 1 208 180 B4584B
                CAL     o2trim_add_clamp_sub_sub_acc             ; 3C12 1 208 180 32FA44
                SJ      idle_temp_hyst3_load_er3             ; 3C15 1 208 180 CB3B
idle_temp_hyst3_load_r2:     MOVB    r2, #008h              ; 3C17 1 208 180 9A08
                JBR     off(00220h).2, idle_temp_hyst3_if_ram224_bit0_set ; 3C19 1 208 180 DA201B
                JBS     off(0022ch).1, idle_temp_hyst3_if_ram22f_bit1_set ; 3C1C 1 208 180 E92C03
                JBS     off(00235h).1, idle_temp_hyst3_goto_3c4d ; 3C1F 1 208 180 E93513
idle_temp_hyst3_if_ram22f_bit1_set:     JBS     off(0022fh).1, idle_temp_hyst3_clear_acc ; 3C22 1 208 180 E92FE1
                JBS     off(00224h).0, idle_temp_hyst3_clear_acc ; 3C25 1 208 180 E824DE
                LB      A, #038h               ; 3C28 0 208 180 7738
                JBR     off(0022ch).7, idle_temp_hyst3_cmp_acc_2 ; 3C2A 0 208 180 DF2C04
                LB      A, #038h               ; 3C2D 0 208 180 7738
                CLRB    r2                     ; 3C2F 0 208 180 2215
idle_temp_hyst3_cmp_acc_2:     CMPB    A, off(0029dh)         ; 3C31 0 208 180 C79D
                JGE     idle_temp_hyst3_clear_acc             ; 3C33 0 208 180 CDD1
idle_temp_hyst3_goto_3c4d:     SJ      idle_temp_hyst3_load_ram298             ; 3C35 0 208 180 CB16
idle_temp_hyst3_if_ram224_bit0_set:     JBS     off(00224h).0, idle_temp_hyst3_clear_acc ; 3C37 1 208 180 E824CC
                L       A, er3                 ; 3C3A 1 208 180 37
                SUB     A, off(00258h)         ; 3C3B 1 208 180 A758
                MOV     er0, #0ffffh           ; 3C3D 1 208 180 4498FFFF
                JGE     idle_temp_hyst3_cmp_acc_3             ; 3C41 1 208 180 CD07
                VCAL    7                      ; 3C43 1 208 180 17
                MOV     er0, #0ffffh           ; 3C44 1 208 180 4498FFFF
                CLRB    r2                     ; 3C48 1 208 180 2215
idle_temp_hyst3_cmp_acc_3:     CMP     A, er0                 ; 3C4A 1 208 180 48
                JLT     idle_temp_hyst3_clear_acc             ; 3C4B 1 208 180 CAB9
idle_temp_hyst3_load_ram298:     MOVB    off(00298h), r2        ; 3C4D 1 208 180 227C98
idle_temp_hyst3_clear_r5:     CLRB    r5                     ; 3C50 1 208 180 2515
idle_temp_hyst3_load_er3:     L       A, er3                 ; 3C52 1 208 180 37
                ST      A, off(00258h)         ; 3C53 1 208 180 D458
                MOVB    off(002c3h), r5        ; 3C55 1 208 180 257CC3
                J       idle_temp_hyst3_cmp_ram298             ; 3C58 1 208 180 033070
                DB  000h,000h,000h ; 3C5B
idle_temp_hyst3_add_acc:     ADD     A, #00500h             ; 3C5E 1 208 180 860005
                J       idle_temp_hyst3_decb_ram298             ; 3C61 1 208 180 033970
idle_temp_hyst3_store_ram284:     ST      A, off(00284h)         ; 3C64 1 208 180 D484
                MB      C, off(00235h).1       ; 3C66 1 208 180 C43529
                MB      off(0022ch).1, C       ; 3C69 1 208 180 C42C39
                RB      09eh.3                 ; 3C6C 1 208 180 C59E0B
                JEQ     idle_temp_hyst3_if_ram22e_bit5_clr             ; 3C6F 1 208 180 C903
                CAL     vcal_4_load_dp             ; 3C71 1 208 180 32C836
idle_temp_hyst3_if_ram22e_bit5_clr:     JBR     off(0022eh).5, idle_temp_hyst3_load_ram248 ; 3C74 1 208 180 DD2E2A
                MOV     off(00246h), #00380h   ; 3C77 1 208 180 B446988003
                MOV     X1, #055d0h            ; 3C7C 1 208 180 60D055
                LB      A, off(00289h)         ; 3C7F 0 208 180 F489
                VCAL    0                      ; 3C81 0 208 180 10
                L       A, ACC                 ; 3C82 1 208 180 E506
                SWAP                           ; 3C84 1 208 180 83
                CLRB    A                      ; 3C85 0 208 180 FA
                MOV     er0, off(00242h)       ; 3C86 0 208 180 B44248
                MUL                            ; 3C89 0 208 180 9035
                L       A, ACC                 ; 3C8B 1 208 180 E506
                SLL     A                      ; 3C8D 1 208 180 53
                L       A, er1                 ; 3C8E 1 208 180 35
                ROL     A                      ; 3C8F 1 208 180 33
                CAL     idle_temp_hyst3_sub_add_acc             ; 3C90 1 208 180 32A070
                L       A, off(00248h)         ; 3C93 1 208 180 E448
                JEQ     idle_temp_hyst3_load_ram244             ; 3C95 1 208 180 C924
                SUB     A, #00300h             ; 3C97 1 208 180 A60003
                JGE     idle_temp_hyst3_store_ram248             ; 3C9A 1 208 180 CD01
                CLR     A                      ; 3C9C 1 208 180 F9
idle_temp_hyst3_store_ram248:     ST      A, off(00248h)         ; 3C9D 1 208 180 D448
                SJ      idle_temp_hyst3_load_ram244             ; 3C9F 1 208 180 CB1A
idle_temp_hyst3_load_ram248:     MOV     off(00248h), #00c00h   ; 3CA1 1 208 180 B44898000C
                L       A, off(00244h)         ; 3CA6 1 208 180 E444
                JEQ     idle_temp_hyst3_clear_pswl_bit5             ; 3CA8 1 208 180 C914
                L       A, off(00246h)         ; 3CAA 1 208 180 E446
                ST      A, er2                 ; 3CAC 1 208 180 8A
                SUB     A, #00030h             ; 3CAD 1 208 180 A63000
                JGE     idle_temp_hyst3_store_ram246             ; 3CB0 1 208 180 CD01
                CLR     A                      ; 3CB2 1 208 180 F9
idle_temp_hyst3_store_ram246:     ST      A, off(00246h)         ; 3CB3 1 208 180 D446
                L       A, er2                 ; 3CB5 1 208 180 36
                SRA     A                      ; 3CB6 1 208 180 73
                ROL     A                      ; 3CB7 1 208 180 33
                J       idle_temp_hyst3_if_ge_goto_70b0             ; 3CB8 1 208 180 03AB70
idle_temp_hyst3_load_ram244:     MOV     off(00244h), er2       ; 3CBB 1 208 180 467C44
idle_temp_hyst3_clear_pswl_bit5:     RB      PSWL.5                 ; 3CBE 1 208 180 A30D
                JBR     off(00220h).0, idle_temp_hyst3_clear_acc_2 ; 3CC0 1 208 180 D82038
                JBS     off(00224h).5, idle_temp_hyst3_clear_acc_2 ; 3CC3 1 208 180 ED2435
                CMPB    0d9h, #03bh            ; 3CC6 1 208 180 C5D9C03B
                JLT     idle_temp_hyst3_cmp_ram0d9             ; 3CCA 1 208 180 CA19
                LB      A, off(002e4h)         ; 3CCC 0 208 180 F4E4
                JEQ     idle_temp_hyst3_set_pswl_bit5             ; 3CCE 0 208 180 C913
                SC                             ; 3CD0 0 208 180 85
                RB      PSWH.0                 ; 3CD1 0 208 180 A208
                JBS     off(00219h).4, idle_temp_hyst3_set_pswh_bit0 ; 3CD3 0 208 180 EC1905
                CMP     0b0h, #00011h          ; 3CD6 0 208 180 B5B0C01100
idle_temp_hyst3_set_pswh_bit0:     SB      PSWH.0                 ; 3CDB 0 208 180 A218
                JGE     idle_temp_hyst3_set_pswl_bit5             ; 3CDD 0 208 180 CD04
                L       A, off(00240h)         ; 3CDF 1 208 180 E440
                JEQ     idle_temp_hyst3_store_ram240             ; 3CE1 1 208 180 C91D
idle_temp_hyst3_set_pswl_bit5:     SB      PSWL.5                 ; 3CE3 1 208 180 A31D
idle_temp_hyst3_cmp_ram0d9:     CMPB    0d9h, #038h            ; 3CE5 1 208 180 C5D9C038
                JGE     idle_temp_hyst3_load_ram23e             ; 3CE9 1 208 180 CD0C
                MOV     X1, #055f5h            ; 3CEB 1 208 180 60F555
                L       A, off(00286h)         ; 3CEE 1 208 180 E486
                CAL     idleign_table_lookup_sub_load_acc             ; 3CF0 1 208 180 324644
                CMP     A, off(0023eh)         ; 3CF3 1 208 180 C73E
                JGE     idle_temp_hyst3_store_ram240             ; 3CF5 1 208 180 CD09
idle_temp_hyst3_load_ram23e:     L       A, off(0023eh)         ; 3CF7 1 208 180 E43E
                SJ      idle_temp_hyst3_store_ram240             ; 3CF9 1 208 180 CB05
idle_temp_hyst3_clear_acc_2:     CLR     A                      ; 3CFB 1 208 180 F9
                MOVB    off(002e4h), #032h     ; 3CFC 1 208 180 C4E49832
idle_temp_hyst3_store_ram240:     ST      A, off(00240h)         ; 3D00 1 208 180 D440
                MB      C, PSWL.5              ; 3D02 1 208 180 A32D
                MB      off(0022ch).0, C       ; 3D04 1 208 180 C42C38
                JBS     off(00216h).1, idle_temp_hyst3_clear_ram22c_bit4 ; 3D07 1 208 180 E91606
                CMPB    0d9h, #0d1h            ; 3D0A 1 208 180 C5D9C0D1
                JLT     idle_temp_hyst3_if_ram22c_bit4_clr             ; 3D0E 1 208 180 CA08
idle_temp_hyst3_clear_ram22c_bit4:     RB      off(0022ch).4          ; 3D10 1 208 180 C42C0C
                CLRB    off(00296h)            ; 3D13 1 208 180 C49615
                SJ      idle_temp_hyst3_clear_acc_3             ; 3D16 1 208 180 CB21
idle_temp_hyst3_if_ram22c_bit4_clr:     JBR     off(0022ch).4, idle_temp_hyst3_if_ram22c_bit2_set ; 3D18 1 208 180 DC2C14
                JBR     off(0022ch).2, idle_temp_hyst3_goto_4f70 ; 3D1B 1 208 180 DA2C17
                L       A, #00200h             ; 3D1E 1 208 180 670002
                CMPB    off(00296h), #000h     ; 3D21 1 208 180 C496C000
                JEQ     idle_temp_hyst3_store_ram24a             ; 3D25 1 208 180 C913
                J       idle_temp_hyst3_decb_ram296             ; 3D27 1 208 180 03604F
                DB  067h,000h,004h,0CBh,00Bh ; 3D2A
idle_temp_hyst3_if_ram22c_bit2_set:     JBS     off(0022ch).2, idle_temp_hyst3_clear_acc_3 ; 3D2F 1 208 180 EA2C07
                SB      off(0022ch).4          ; 3D32 1 208 180 C42C1C
idle_temp_hyst3_goto_4f70:     J       idle_temp_hyst3_load_imm_4             ; 3D35 1 208 180 03704F
                DB  004h ; 3D38
idle_temp_hyst3_clear_acc_3:     CLR     A                      ; 3D39 1 208 180 F9
idle_temp_hyst3_store_ram24a:     ST      A, off(0024ah)         ; 3D3A 1 208 180 D44A
                LB      A, #0d0h               ; 3D3C 0 208 180 77D0
                JBS     off(0022ah).4, idle_temp_hyst3_cmp_acc_4 ; 3D3E 0 208 180 EC2A02
                LB      A, #0e0h               ; 3D41 0 208 180 77E0
idle_temp_hyst3_cmp_acc_4:     CMPB    A, off(00289h)         ; 3D43 0 208 180 C789
                MB      off(0022ah).4, C       ; 3D45 0 208 180 C42A3C
                CLR     er3                    ; 3D48 0 208 180 4715
                RC                             ; 3D4A 0 208 180 95
                JBS     off(0022ah).4, idle_temp_hyst3_load_r0 ; 3D4B 0 208 180 EC2A45
                JBR     off(00216h).5, idle_temp_hyst3_load_r0 ; 3D4E 0 208 180 DD1642
                JBS     off(00210h).6, idle_temp_hyst3_load_r0 ; 3D51 0 208 180 EE103F
                MB      C, 098h.2              ; 3D54 0 208 180 C5982A
                XORB    PSWH, #080h            ; 3D57 0 208 180 A2F080
                JGE     idle_temp_hyst3_load_r0             ; 3D5A 0 208 180 CD37
                LB      A, off(00289h)         ; 3D5C 0 208 180 F489
                MOV     X1, #idle_temp_hyst3_tbl_4          ; 3D5E 0 208 180 600269
                VCAL    1                      ; 3D61 0 208 180 11
                CLR     A                      ; 3D62 1 208 180 F9
                MOV     DP, #0032fh            ; 3D63 1 208 180 622F03
                LB      A, [DP]                ; 3D66 0 208 180 F2
                ADDB    A, #003h               ; 3D67 0 208 180 8603
                MOV     er0, A                 ; 3D69 0 208 180 448A
                L       A, 0aah                ; 3D6B 1 208 180 E5AA
                SRL     A                      ; 3D6D 1 208 180 63
                SRL     A                      ; 3D6E 1 208 180 63
                SRL     A                      ; 3D6F 1 208 180 63
                SRL     A                      ; 3D70 1 208 180 63
                SRL     A                      ; 3D71 1 208 180 63
                SRL     A                      ; 3D72 1 208 180 63
                SUB     A, er0                 ; 3D73 1 208 180 28
                JGE     idle_temp_hyst3_load_er0             ; 3D74 1 208 180 CD01
                CLR     A                      ; 3D76 1 208 180 F9
idle_temp_hyst3_load_er0:     MOV     er0, #idle_temp_hyst3_tbl_3         ; 3D77 1 208 180 44989959
                MUL                            ; 3D7B 1 208 180 9035
                LB      A, r2                  ; 3D7D 0 208 180 7A
                L       A, ACC                 ; 3D7E 1 208 180 E506
                SWAP                           ; 3D80 1 208 180 83
                CMPB    r3, #000h              ; 3D81 1 208 180 23C000
                JEQ     idle_temp_hyst3_cmp_acc_5             ; 3D84 1 208 180 C903
                L       A, #0ffffh             ; 3D86 1 208 180 67FFFF
idle_temp_hyst3_cmp_acc_5:     CMP     A, er3                 ; 3D89 1 208 180 4B
                JLT     idle_temp_hyst3_store_er3_2             ; 3D8A 1 208 180 CA01
                L       A, er3                 ; 3D8C 1 208 180 37
idle_temp_hyst3_store_er3_2:     ST      A, er3                 ; 3D8D 1 208 180 8B
                ADD     A, #00100h             ; 3D8E 1 208 180 860001
                CMP     A, off(0025ch)         ; 3D91 1 208 180 C75C
idle_temp_hyst3_load_r0:     MOVB    r0, #0ffh              ; 3D93 1 208 180 98FF
                JGE     idle_temp_hyst3_load_er3_2             ; 3D95 1 208 180 CD1F
                LB      A, off(002fch)         ; 3D97 0 208 180 F4FC
                JNE     idle_temp_hyst3_clear_ram09e_bit3             ; 3D99 0 208 180 CE25
                L       A, off(0025ch)         ; 3D9B 1 208 180 E45C
                CLR     er0                    ; 3D9D 1 208 180 4415
                MOVB    r1, off(002c8h)        ; 3D9F 1 208 180 C4C849
                MUL                            ; 3DA2 1 208 180 9035
                LB      A, #018h               ; 3DA4 0 208 180 7718
                JBS     off(00220h).0, idle_temp_hyst3_xchgb_acc ; 3DA6 0 208 180 E82002
                LB      A, #018h               ; 3DA9 0 208 180 7718
idle_temp_hyst3_xchgb_acc:     XCHGB   A, r1                  ; 3DAB 0 208 180 2110
                SUBB    A, r1                  ; 3DAD 0 208 180 29
                JGE     idle_temp_hyst3_store_r0             ; 3DAE 0 208 180 CD01
                CLRB    A                      ; 3DB0 0 208 180 FA
idle_temp_hyst3_store_r0:     STB     A, r0                  ; 3DB1 0 208 180 88
                L       A, er1                 ; 3DB2 1 208 180 35
                CMP     A, er3                 ; 3DB3 1 208 180 4B
                JGE     idle_temp_hyst3_store_ram25c             ; 3DB4 1 208 180 CD01
idle_temp_hyst3_load_er3_2:     L       A, er3                 ; 3DB6 1 208 180 37
idle_temp_hyst3_store_ram25c:     ST      A, off(0025ch)         ; 3DB7 1 208 180 D45C
                MOVB    off(002c8h), r0        ; 3DB9 1 208 180 207CC8
                MOVB    off(002fch), #00fh     ; 3DBC 1 208 180 C4FC980F
idle_temp_hyst3_clear_ram09e_bit3:     RB      09eh.3                 ; 3DC0 1 208 180 C59E0B
                JEQ     idle_temp_hyst3_if_ram216_bit1_clr             ; 3DC3 1 208 180 C903
                CAL     vcal_4_load_dp             ; 3DC5 1 208 180 32C836
idle_temp_hyst3_if_ram216_bit1_clr:     JBR     off(00216h).1, idle_temp_hyst3_clear_ram22c_bit5 ; 3DC8 1 208 180 D9160F
                CLR     off(0025ch)            ; 3DCB 1 208 180 B45C15
                SB      off(0022ch).5          ; 3DCE 1 208 180 C42C1D
                RB      off(00216h).6          ; 3DD1 1 208 180 C4160E
                RB      off(0022ch).6          ; 3DD4 1 208 180 C42C0E
                J       idle_temp_hyst3_load_er3_4             ; 3DD7 1 208 180 030941
idle_temp_hyst3_clear_ram22c_bit5:     RB      off(0022ch).5          ; 3DDA 1 208 180 C42C0D
                JBR     off(00217h).2, idle_temp_hyst3_load_carry_ram098_bit1 ; 3DDD 1 208 180 DA1703
                J       idle_temp_hyst3_clear_ram216_bit6_2             ; 3DE0 1 208 180 03B13E
idle_temp_hyst3_load_carry_ram098_bit1:     MB      C, 098h.1              ; 3DE3 1 208 180 C59829
                JLT     idle_temp_hyst3_goto_3ee3             ; 3DE6 1 208 180 CA0F
                JBS     off(00210h).5, idle_temp_hyst3_goto_3ee3 ; 3DE8 1 208 180 ED100C
                L       A, off(00210h)         ; 3DEB 1 208 180 E410
                AND     A, #02054h             ; 3DED 1 208 180 D65420
                JNE     idle_temp_hyst3_goto_3eef             ; 3DF0 1 208 180 CE08
                JBS     off(00212h).0, idle_temp_hyst3_goto_3eef ; 3DF2 1 208 180 E81205
                SJ      idle_temp_hyst3_load_ram210             ; 3DF5 1 208 180 CB06
idle_temp_hyst3_goto_3ee3:     J       idle_temp_hyst3_call_4a61_3             ; 3DF7 1 208 180 03E33E
idle_temp_hyst3_goto_3eef:     J       idle_temp_hyst3_call_4a61_4             ; 3DFA 1 208 180 03EF3E
idle_temp_hyst3_load_ram210:     L       A, off(00210h)         ; 3DFD 1 208 180 E410
                JNE     idle_temp_hyst3_call_4a61             ; 3DFF 1 208 180 CE07
                L       A, off(00212h)         ; 3E01 1 208 180 E412
                AND     A, #09cffh             ; 3E03 1 208 180 D6FF9C
                JEQ     idle_temp_hyst3_if_ram216_bit4_set             ; 3E06 1 208 180 C903
idle_temp_hyst3_call_4a61:     CAL     idle_temp_hyst3_sub_load_dp             ; 3E08 1 208 180 32614A
idle_temp_hyst3_if_ram216_bit4_set:     JBS     off(00216h).4, idle_temp_hyst3_clear_ram216_bit6 ; 3E0B 1 208 180 EC166E
                CLR     off(0025ch)            ; 3E0E 1 208 180 B45C15
                MOV     X1, #0555ch            ; 3E11 1 208 180 605C55
                LB      A, 0d9h                ; 3E14 0 208 180 F5D9
                VCAL    0                      ; 3E16 0 208 180 10
                CMPB    A, off(00289h)         ; 3E17 0 208 180 C789
                JLT     idle_temp_hyst3_clear_ram2f6             ; 3E19 0 208 180 CA3E
                JBR     off(00216h).2, idle_temp_hyst3_clear_ram2f6 ; 3E1B 0 208 180 DA163B
                MOV     er0, off(0025ah)       ; 3E1E 0 208 180 B45A48
                CMPB    A, 0eah                ; 3E21 0 208 180 C5EAC2
                JGE     idle_temp_hyst3_load_ram2f6             ; 3E24 0 208 180 CD2F
                L       A, 0b2h                ; 3E26 1 208 180 E5B2
                MOV     DP, A                  ; 3E28 1 208 180 52
                MOV     X1, #0556ah            ; 3E29 1 208 180 606A55
                LB      A, 0d9h                ; 3E2C 0 208 180 F5D9
                VCAL    1                      ; 3E2E 0 208 180 11
                ; warning: had to flip DD
                CMP     A, DP                  ; 3E2F 1 208 180 92C2
                JGT     idle_temp_hyst3_clear_ram2f6             ; 3E31 1 208 180 C826
                MOV     X1, #0557fh            ; 3E33 1 208 180 607F55
                LB      A, 0d9h                ; 3E36 0 208 180 F5D9
                VCAL    0                      ; 3E38 0 208 180 10
                STB     A, off(002f6h)         ; 3E39 0 208 180 D4F6
                MOV     X1, #0558dh            ; 3E3B 0 208 180 608D55
                LB      A, 0d9h                ; 3E3E 0 208 180 F5D9
                VCAL    0                      ; 3E40 0 208 180 10
                CLR     er0                    ; 3E41 0 208 180 4415
                STB     A, r0                  ; 3E43 0 208 180 88
                L       A, DP                  ; 3E44 1 208 180 42
                MUL                            ; 3E45 1 208 180 9035
                MOV     er0, #02000h           ; 3E47 1 208 180 44980020
                CMP     er1, #00000h           ; 3E4B 1 208 180 45C00000
                JNE     idle_temp_hyst3_load_ram2f6             ; 3E4F 1 208 180 CE04
                CMP     A, er0                 ; 3E51 1 208 180 48
                JGE     idle_temp_hyst3_load_ram2f6             ; 3E52 1 208 180 CD01
                ST      A, er0                 ; 3E54 1 208 180 88
idle_temp_hyst3_load_ram2f6:     LB      A, off(002f6h)         ; 3E55 0 208 180 F4F6
                JNE     idle_temp_hyst3_load_ram25a             ; 3E57 0 208 180 CE05
idle_temp_hyst3_clear_ram2f6:     CLRB    off(002f6h)            ; 3E59 0 208 180 C4F615
                CLR     er0                    ; 3E5C 0 208 180 4415
idle_temp_hyst3_load_ram25a:     MOV     off(0025ah), er0       ; 3E5E 0 208 180 447C5A
                JBR     off(00220h).0, idle_temp_hyst3_set_ram216_bit6 ; 3E61 0 208 180 D8200F
                JBS     off(00224h).5, idle_temp_hyst3_set_ram216_bit6 ; 3E64 0 208 180 ED240C
                JBR     off(0022ch).0, idle_temp_hyst3_set_ram216_bit6 ; 3E67 0 208 180 D82C09
                RB      off(00216h).6          ; 3E6A 0 208 180 C4160E
                SB      off(0022ch).6          ; 3E6D 0 208 180 C42C1E
                J       idle_temp_hyst3_load_er3_6             ; 3E70 0 208 180 031841
idle_temp_hyst3_set_ram216_bit6:     SB      off(00216h).6          ; 3E73 0 208 180 C4161E
idle_temp_hyst3_clear_ram22c_bit6:     RB      off(0022ch).6          ; 3E76 0 208 180 C42C0E
                J       idle_temp_hyst3_clear_ram09e_bit3_2             ; 3E79 0 208 180 03FB3E
idle_temp_hyst3_clear_ram216_bit6:     RB      off(00216h).6          ; 3E7C 1 208 180 C4160E
                CLR     er3                    ; 3E7F 1 208 180 4715
                JBR     off(00239h).7, idle_temp_hyst3_load_er3_3 ; 3E81 1 208 180 DF391F
                JBR     off(0021ah).0, idle_temp_hyst3_load_er3_3 ; 3E84 1 208 180 D81A1C
                CMPB    0d9h, #02eh            ; 3E87 1 208 180 C5D9C02E
                JGE     idle_temp_hyst3_load_er3_3             ; 3E8B 1 208 180 CD16
                CMPB    0dfh, #005h            ; 3E8D 1 208 180 C5DFC005
                JLT     idle_temp_hyst3_load_er3_3             ; 3E91 1 208 180 CA10
                L       A, off(0025ch)         ; 3E93 1 208 180 E45C
                JNE     idle_temp_hyst3_load_er3_3             ; 3E95 1 208 180 CE0C
                LB      A, off(00289h)         ; 3E97 0 208 180 F489
                MOV     X1, #idle_temp_hyst3_tbl_2          ; 3E99 0 208 180 603C56
                JBS     off(0021dh).1, idle_temp_hyst3_vcal_1 ; 3E9C 0 208 180 E91D03
                MOV     X1, #idle_temp_hyst3_tbl          ; 3E9F 0 208 180 602456
idle_temp_hyst3_vcal_1:     VCAL    1                      ; 3EA2 0 208 180 11
idle_temp_hyst3_load_er3_3:     L       A, er3                 ; 3EA3 1 208 180 37
                ST      A, off(0025eh)         ; 3EA4 1 208 180 D45E
                JEQ     idle_temp_hyst3_goto_3e76             ; 3EA6 1 208 180 C906
                RB      off(0022ch).6          ; 3EA8 1 208 180 C42C0E
                J       idle_temp_hyst3_load_er3_7             ; 3EAB 1 208 180 035441
idle_temp_hyst3_goto_3e76:     J       idle_temp_hyst3_clear_ram22c_bit6             ; 3EAE 1 208 180 03763E
idle_temp_hyst3_clear_ram216_bit6_2:     RB      off(00216h).6          ; 3EB1 1 208 180 C4160E
                JBR     off(0022fh).2, idle_temp_hyst3_load_carry_ram098_bit1_2 ; 3EB4 1 208 180 DA2F09
                RB      off(0022ch).6          ; 3EB7 1 208 180 C42C0E
                L       A, #02000h             ; 3EBA 1 208 180 670020
                J       idle_gear_target_final             ; 3EBD 1 208 180 03BA41
idle_temp_hyst3_load_carry_ram098_bit1_2:     MB      C, 098h.1              ; 3EC0 1 208 180 C59829
                JLT     idle_temp_hyst3_call_4a61_3             ; 3EC3 1 208 180 CA1E
                JBS     off(00210h).5, idle_temp_hyst3_call_4a61_3 ; 3EC5 1 208 180 ED101B
                L       A, off(00210h)         ; 3EC8 1 208 180 E410
                AND     A, #02054h             ; 3ECA 1 208 180 D65420
                JNE     idle_temp_hyst3_call_4a61_4             ; 3ECD 1 208 180 CE20
                JBS     off(00212h).0, idle_temp_hyst3_call_4a61_4 ; 3ECF 1 208 180 E8121D
                L       A, off(00210h)         ; 3ED2 1 208 180 E410
                JNE     idle_temp_hyst3_call_4a61_2             ; 3ED4 1 208 180 CE07
                L       A, off(00212h)         ; 3ED6 1 208 180 E412
                AND     A, #09cffh             ; 3ED8 1 208 180 D6FF9C
                JEQ     idle_temp_hyst3_goto_3eae             ; 3EDB 1 208 180 C903
idle_temp_hyst3_call_4a61_2:     CAL     idle_temp_hyst3_sub_load_dp             ; 3EDD 1 208 180 32614A
idle_temp_hyst3_goto_3eae:     J       idle_temp_hyst3_goto_3e76             ; 3EE0 1 208 180 03AE3E
idle_temp_hyst3_call_4a61_3:     CAL     idle_temp_hyst3_sub_load_dp             ; 3EE3 1 208 180 32614A
                RB      off(00216h).6          ; 3EE6 1 208 180 C4160E
                RB      off(0022ch).6          ; 3EE9 1 208 180 C42C0E
                J       idle_temp_hyst3_load_er3_5             ; 3EEC 1 208 180 030E41
idle_temp_hyst3_call_4a61_4:     CAL     idle_temp_hyst3_sub_load_dp             ; 3EEF 1 208 180 32614A
                RB      off(00216h).6          ; 3EF2 1 208 180 C4160E
                RB      off(0022ch).6          ; 3EF5 1 208 180 C42C0E
                J       idle_temp_hyst3_clear_er3             ; 3EF8 1 208 180 031441
idle_temp_hyst3_clear_ram09e_bit3_2:     RB      09eh.3                 ; 3EFB 0 208 180 C59E0B
                JEQ     idle_temp_hyst3_load_ram256             ; 3EFE 0 208 180 C903
                CAL     vcal_4_load_dp             ; 3F00 0 208 180 32C836
idle_temp_hyst3_load_ram256:     MOV     off(00256h), off(00254h) ; 3F03 0 208 180 B4547C56
                MOVB    off(002a0h), off(0029fh) ; 3F07 0 208 180 C49F7CA0
                JBS     off(00216h).6, idle_temp_hyst3_if_ram22d_bit7_set ; 3F0B 0 208 180 EE160B
                JBS     off(0022dh).7, idle_temp_hyst3_if_ram216_bit2_set ; 3F0E 0 208 180 EF2D21
                JBS     off(00216h).3, idle_temp_hyst3_load_imm_3 ; 3F11 0 208 180 EB1647
                JBR     off(00216h).2, idle_temp_hyst3_load_imm_3 ; 3F14 0 208 180 DA1644
                SJ      idle_temp_hyst3_load_ram260             ; 3F17 0 208 180 CB32
idle_temp_hyst3_if_ram22d_bit7_set:     JBS     off(0022dh).7, idle_temp_hyst3_if_ram220_bit0_clr ; 3F19 0 208 180 EF2D07
                JBR     off(0022dh).5, idle_temp_hyst3_if_ram216_bit2_set ; 3F1C 0 208 180 DD2D13
                L       A, off(00268h)         ; 3F1F 1 208 180 E468
                SJ      idle_temp_hyst3_load_dp             ; 3F21 1 208 180 CB2A
idle_temp_hyst3_if_ram220_bit0_clr:     JBR     off(00220h).0, idle_temp_hyst3_if_ram239_bit1_set ; 3F23 0 208 180 D82003
                JBS     off(00239h).0, idle_temp_hyst3_if_ram216_bit2_set ; 3F26 0 208 180 E83909
idle_temp_hyst3_if_ram239_bit1_set:     JBS     off(00239h).1, idle_temp_hyst3_if_ram216_bit2_set ; 3F29 0 208 180 E93906
                JBR     off(0022dh).4, idle_temp_hyst3_load_imm_3 ; 3F2C 0 208 180 DC2D2C
                JBR     off(00239h).2, idle_temp_hyst3_load_imm_3 ; 3F2F 0 208 180 DA3929
idle_temp_hyst3_if_ram216_bit2_set:     JBS     off(00216h).2, idle_temp_hyst3_if_ram220_bit0_clr_2 ; 3F32 0 208 180 EA1604
                L       A, off(00262h)         ; 3F35 1 208 180 E462
                SJ      idle_temp_hyst3_load_dp             ; 3F37 1 208 180 CB14
idle_temp_hyst3_if_ram220_bit0_clr_2:     JBR     off(00220h).0, idle_temp_hyst3_load_ram260 ; 3F39 0 208 180 D8200F
                JBS     off(00224h).5, idle_temp_hyst3_load_ram260 ; 3F3C 0 208 180 ED240C
                JBR     off(0022dh).6, idle_temp_hyst3_load_ram260 ; 3F3F 0 208 180 DE2D09
                CLR     A                      ; 3F42 1 208 180 F9
                LC      A, 05558h              ; 3F43 1 208 180 909C5855
                ADD     A, off(00260h)         ; 3F47 1 208 180 8760
                SJ      idle_temp_hyst3_store_ram254             ; 3F49 1 208 180 CB07
idle_temp_hyst3_load_ram260:     L       A, off(00260h)         ; 3F4B 1 208 180 E460
idle_temp_hyst3_load_dp:     MOV     DP, #0030eh            ; 3F4D 1 208 180 620E03
                ADD     A, [DP]                ; 3F50 1 208 180 B282
idle_temp_hyst3_store_ram254:     ST      A, off(00254h)         ; 3F52 1 208 180 D454
                ST      A, off(00256h)         ; 3F54 1 208 180 D456
                CLRB    A                      ; 3F56 0 208 180 FA
                STB     A, off(0029fh)         ; 3F57 0 208 180 D49F
                STB     A, off(002a0h)         ; 3F59 0 208 180 D4A0
idle_temp_hyst3_load_imm_3:     LB      A, #043h               ; 3F5B 0 208 180 7743
                STB     A, r2                  ; 3F5D 0 208 180 8A
                JBS     off(00216h).6, idle_temp_hyst3_if_ram216_bit5_clr ; 3F5E 0 208 180 EE160A
                STB     A, off(00297h)         ; 3F61 0 208 180 D497
                JBS     off(00216h).7, idle_temp_hyst3_load_x1_3 ; 3F63 0 208 180 EF160A
idle_temp_hyst3_load_x1_2:     MOV     X1, #05550h            ; 3F66 0 208 180 605055
                SJ      idle_temp_hyst3_clear_pswh_bit0             ; 3F69 0 208 180 CB39
idle_temp_hyst3_if_ram216_bit5_clr:     JBR     off(00216h).5, idle_temp_hyst3_if_ram216_bit2_set_2 ; 3F6B 0 208 180 DD1607
                STB     A, off(00297h)         ; 3F6E 0 208 180 D497
idle_temp_hyst3_load_x1_3:     MOV     X1, #0554dh            ; 3F70 0 208 180 604D55
                SJ      idle_temp_hyst3_clear_pswh_bit0             ; 3F73 0 208 180 CB2F
idle_temp_hyst3_if_ram216_bit2_set_2:     JBS     off(00216h).2, idle_temp_hyst3_load_ram0d9 ; 3F75 0 208 180 EA1606
                CMPB    0ffh, #096h            ; 3F78 0 208 180 C5FFC096
                JLT     idle_temp_hyst3_if_ram216_bit7_clr             ; 3F7C 0 208 180 CA20
idle_temp_hyst3_load_ram0d9:     LB      A, 0d9h                ; 3F7E 0 208 180 F5D9
                MOV     X1, #idle_temp_hyst3_tbl_5          ; 3F80 0 208 180 60F469
                VCAL    0                      ; 3F83 0 208 180 10
                LB      A, off(00295h)         ; 3F84 0 208 180 F495
                SUBB    A, r6                  ; 3F86 0 208 180 2E
                JLT     idle_temp_hyst3_load_ram297             ; 3F87 0 208 180 CA04
                CMPB    A, off(00289h)         ; 3F89 0 208 180 C789
                JGE     idle_temp_hyst3_load_r2_2             ; 3F8B 0 208 180 CD09
idle_temp_hyst3_load_ram297:     LB      A, off(00297h)         ; 3F8D 0 208 180 F497
                JEQ     idle_temp_hyst3_load_x1_4             ; 3F8F 0 208 180 C908
                DECB    off(00297h)            ; 3F91 0 208 180 C49717
                SJ      idle_temp_hyst3_load_x1_3             ; 3F94 0 208 180 CBDA
idle_temp_hyst3_load_r2_2:     LB      A, r2                  ; 3F96 0 208 180 7A
                STB     A, off(00297h)         ; 3F97 0 208 180 D497
idle_temp_hyst3_load_x1_4:     MOV     X1, #05547h            ; 3F99 0 208 180 604755
                SJ      idle_temp_hyst3_clear_pswh_bit0             ; 3F9C 0 208 180 CB06
idle_temp_hyst3_if_ram216_bit7_clr:     JBR     off(00216h).7, idle_temp_hyst3_load_x1_2 ; 3F9E 0 208 180 DF16C5
                MOV     X1, #0554ah            ; 3FA1 0 208 180 604A55
idle_temp_hyst3_clear_pswh_bit0:     RB      PSWH.0                 ; 3FA4 0 208 180 A208
                MOV     er0, 0b4h              ; 3FA6 0 208 180 B5B448
                MB      C, off(00216h).7       ; 3FA9 0 208 180 C4162F
                SB      PSWH.0                 ; 3FAC 0 208 180 A218
                MB      PSWL.4, C              ; 3FAE 0 208 180 A33C
                MOV     er2, er0               ; 3FB0 0 208 180 444A
                CLR     A                      ; 3FB2 1 208 180 F9
                LCB     A, [X1]                ; 3FB3 1 208 180 90AA
                SWAP                           ; 3FB5 1 208 180 83
                MUL                            ; 3FB6 1 208 180 9035
                L       A, er1                 ; 3FB8 1 208 180 35
                MB      C, PSWL.4              ; 3FB9 1 208 180 A32C
                JGE     idle_temp_hyst3_store_ram24c             ; 3FBB 1 208 180 CD01
                VCAL    7                      ; 3FBD 1 208 180 17
idle_temp_hyst3_store_ram24c:     ST      A, off(0024ch)         ; 3FBE 1 208 180 D44C
                INC     X1                     ; 3FC0 1 208 180 70
                MOV     er0, er2               ; 3FC1 1 208 180 4648
                CLR     A                      ; 3FC3 1 208 180 F9
                LCB     A, [X1]                ; 3FC4 1 208 180 90AA
                SWAP                           ; 3FC6 1 208 180 83
                MUL                            ; 3FC7 1 208 180 9035
                ST      A, er0                 ; 3FC9 1 208 180 88
                L       A, er1                 ; 3FCA 1 208 180 35
                MB      C, PSWL.4              ; 3FCB 1 208 180 A32C
                JGE     idle_temp_hyst3_store_ram24e             ; 3FCD 1 208 180 CD05
                CLRB    A                      ; 3FCF 0 208 180 FA
                SUBB    A, r1                  ; 3FD0 0 208 180 29
                STB     A, r1                  ; 3FD1 0 208 180 89
                CLR     A                      ; 3FD2 1 208 180 F9
                SBC     A, er1                 ; 3FD3 1 208 180 39
idle_temp_hyst3_store_ram24e:     ST      A, off(0024eh)         ; 3FD4 1 208 180 D44E
                MOVB    off(002a1h), r1        ; 3FD6 1 208 180 217CA1
                INC     X1                     ; 3FD9 1 208 180 70
                MOV     er0, 0b2h              ; 3FDA 1 208 180 B5B248
                CLR     A                      ; 3FDD 1 208 180 F9
                LCB     A, [X1]                ; 3FDE 1 208 180 90AA
                SWAP                           ; 3FE0 1 208 180 83
                MUL                            ; 3FE1 1 208 180 9035
                L       A, er1                 ; 3FE3 1 208 180 35
                JBR     off(00219h).5, idle_temp_hyst3_store_ram250 ; 3FE4 1 208 180 DD1901
                VCAL    7                      ; 3FE7 1 208 180 17
idle_temp_hyst3_store_ram250:     ST      A, off(00250h)         ; 3FE8 1 208 180 D450
                MOV     DP, #0030eh            ; 3FEA 1 208 180 620E03
                CLR     A                      ; 3FED 1 208 180 F9
                MOV     er0, off(00262h)       ; 3FEE 1 208 180 B46248
                MOVB    ACCH, #025h            ; 3FF1 1 208 180 C5079825
                JBR     off(00216h).2, idle_temp_hyst3_mul_acc ; 3FF5 1 208 180 DA1617
                MOV     er0, off(00260h)       ; 3FF8 1 208 180 B46048
                MOVB    ACCH, #052h            ; 3FFB 1 208 180 C5079852
                JBR     off(00216h).6, idle_temp_hyst3_mul_acc ; 3FFF 1 208 180 DE160D
                JBR     off(00216h).5, idle_temp_hyst3_mul_acc ; 4002 1 208 180 DD160A
                CMPB    0d9h, #07ah            ; 4005 1 208 180 C5D9C07A
                JGE     idle_temp_hyst3_mul_acc             ; 4009 1 208 180 CD04
                MOV     er2, [DP]              ; 400B 1 208 180 B24A
                SJ      idle_temp_hyst3_clear_acc_4             ; 400D 1 208 180 CB0F
idle_temp_hyst3_mul_acc:     MUL                            ; 400F 1 208 180 9035
                SLL     A                      ; 4011 1 208 180 53
                ROL     er1                    ; 4012 1 208 180 45B7
                L       A, er1                 ; 4014 1 208 180 35
                ADD     A, [DP]                ; 4015 1 208 180 B282
                SUB     A, #00600h             ; 4017 1 208 180 A60006
                JGE     idle_temp_hyst3_store_er2             ; 401A 1 208 180 CD01
                CLR     A                      ; 401C 1 208 180 F9
idle_temp_hyst3_store_er2:     ST      A, er2                 ; 401D 1 208 180 8A
idle_temp_hyst3_clear_acc_4:     CLR     A                      ; 401E 1 208 180 F9
                MOVB    ACCH, #080h            ; 401F 1 208 180 C5079880
                JBS     off(00216h).2, idle_temp_hyst3_mul_acc_2 ; 4023 1 208 180 EA1604
                MOVB    ACCH, #099h            ; 4026 1 208 180 C5079899
idle_temp_hyst3_mul_acc_2:     MUL                            ; 402A 1 208 180 9035
                SLL     A                      ; 402C 1 208 180 53
                ROL     er1                    ; 402D 1 208 180 45B7
                J       idle_temp_hyst3_load_er1             ; 402F 1 208 180 035370
idle_temp_hyst3_add_acc_2:     ADD     A, #01800h             ; 4032 1 208 180 860018
                NOP                            ; 4035 1 208 180 00
                NOP                            ; 4036 1 208 180 00
                J       idle_temp_hyst3_if_lt_goto_705f             ; 4037 1 208 180 035970
idle_temp_hyst3_load_x1_5:     MOV     X1, A                  ; 403A 1 208 180 50
                L       A, off(0024eh)         ; 403B 1 208 180 E44E
                ST      A, er3                 ; 403D 1 208 180 8B
                SLL     A                      ; 403E 1 208 180 53
                MB      PSWL.4, C              ; 403F 1 208 180 A33C
                LB      A, off(002a1h)         ; 4041 0 208 180 F4A1
                ADDB    A, off(0029fh)         ; 4043 0 208 180 879F
                STB     A, r1                  ; 4045 0 208 180 89
                L       A, off(00254h)         ; 4046 1 208 180 E454
                ADC     A, er3                 ; 4048 1 208 180 1B
                RB      PSWL.4                 ; 4049 1 208 180 A30C
                JNE     idle_temp_hyst3_if_ge_goto_4056             ; 404B 1 208 180 CE04
                JLT     idle_temp_hyst3_load_x1_6             ; 404D 1 208 180 CA0E
                SJ      idle_temp_hyst3_cmp_acc_6             ; 404F 1 208 180 CB02
idle_temp_hyst3_if_ge_goto_4056:     JGE     idle_temp_hyst3_load_er2             ; 4051 1 208 180 CD03
idle_temp_hyst3_cmp_acc_6:     CMP     A, er2                 ; 4053 1 208 180 4A
                JGE     idle_temp_hyst3_cmp_acc_7             ; 4054 1 208 180 CD03
idle_temp_hyst3_load_er2:     L       A, er2                 ; 4056 1 208 180 36
                CLRB    r1                     ; 4057 1 208 180 2115
idle_temp_hyst3_cmp_acc_7:     CMP     A, X1                  ; 4059 1 208 180 90C2
                JLE     idle_temp_hyst3_store_er1             ; 405B 1 208 180 CF03
idle_temp_hyst3_load_x1_6:     L       A, X1                  ; 405D 1 208 180 40
                CLRB    r1                     ; 405E 1 208 180 2115
idle_temp_hyst3_store_er1:     ST      A, er1                 ; 4060 1 208 180 89
                ST      A, er3                 ; 4061 1 208 180 8B
                L       A, off(0024ch)         ; 4062 1 208 180 E44C
                VCAL    5                      ; 4064 1 208 180 15
                L       A, off(00250h)         ; 4065 1 208 180 E450
                VCAL    5                      ; 4067 1 208 180 15
                CMP     A, X1                  ; 4068 1 208 180 90C2
                JLE     idle_temp_hyst3_cmp_acc_8             ; 406A 1 208 180 CF03
                L       A, X1                  ; 406C 1 208 180 40
                SJ      idle_temp_hyst3_store_ram252             ; 406D 1 208 180 CB0C
idle_temp_hyst3_cmp_acc_8:     CMP     A, er2                 ; 406F 1 208 180 4A
                JGE     idle_temp_hyst3_load_ram254             ; 4070 1 208 180 CD03
                L       A, er2                 ; 4072 1 208 180 36
                SJ      idle_temp_hyst3_store_ram252             ; 4073 1 208 180 CB06
idle_temp_hyst3_load_ram254:     MOV     off(00254h), er1       ; 4075 1 208 180 457C54
                MOVB    off(0029fh), r1        ; 4078 1 208 180 217C9F
idle_temp_hyst3_store_ram252:     ST      A, off(00252h)         ; 407B 1 208 180 D452
                L       A, off(00210h)         ; 407D 1 208 180 E410
                JEQ     idle_temp_hyst3_load_ram212             ; 407F 1 208 180 C903
                J       idle_temp_hyst3_load_ram25a_2             ; 4081 1 208 180 03FD40
idle_temp_hyst3_load_ram212:     L       A, off(00212h)         ; 4084 1 208 180 E412
                AND     A, #09cffh             ; 4086 1 208 180 D6FF9C
                JNE     idle_temp_hyst3_load_ram25a_2             ; 4089 1 208 180 CE72
                JBR     off(00216h).6, idle_temp_hyst3_load_ram25a_2 ; 408B 1 208 180 DE166F
                JBS     off(00216h).5, idle_temp_hyst3_load_ram25a_2 ; 408E 1 208 180 ED166C
                JBR     off(00216h).2, idle_temp_hyst3_load_ram25a_2 ; 4091 1 208 180 DA1669
                L       A, off(0024ah)         ; 4094 1 208 180 E44A
                JNE     idle_temp_hyst3_load_ram25a_2             ; 4096 1 208 180 CE65
                JBS     off(00224h).0, idle_temp_hyst3_load_ram25a_2 ; 4098 1 208 180 E82462
                CMPB    0e2h, #047h            ; 409B 1 208 180 C5E2C047
                JLT     idle_temp_hyst3_load_ram25a_2             ; 409F 1 208 180 CA5C
                JBR     off(00239h).3, idle_temp_hyst3_load_ram25a_2 ; 40A1 1 208 180 DB3959
                CMP     0b4h, #00095h          ; 40A4 1 208 180 B5B4C09500
                JGE     idle_temp_hyst3_load_ram25a_2             ; 40A9 1 208 180 CD52
                CMPB    0d9h, #057h            ; 40AB 1 208 180 C5D9C057
                JGE     idle_temp_hyst3_load_ram25a_2             ; 40AF 1 208 180 CD4C
                JBR     off(0021bh).1, idle_temp_hyst3_load_ram25a_2 ; 40B1 1 208 180 D91B49
                MOV     X1, #0030eh            ; 40B4 1 208 180 600E03
                MOV     er3, 00000h[X1]        ; 40B7 1 208 180 B000004B
                MOV     er2, 00002h[X1]        ; 40BB 1 208 180 B002004A
                L       A, off(00254h)         ; 40BF 1 208 180 E454
                SUB     A, er3                 ; 40C1 1 208 180 2B
                MB      PSWL.4, C              ; 40C2 1 208 180 A33C
                JGE     idle_temp_hyst3_clear_r1             ; 40C4 1 208 180 CD03
                ST      A, er0                 ; 40C6 1 208 180 88
                CLR     A                      ; 40C7 1 208 180 F9
                SUB     A, er0                 ; 40C8 1 208 180 28
idle_temp_hyst3_clear_r1:     CLRB    r1                     ; 40C9 1 208 180 2115
                MOVB    r0, #0ffh              ; 40CB 1 208 180 98FF
                CMPB    0d9h, #028h            ; 40CD 1 208 180 C5D9C028
                JLT     idle_temp_hyst3_mul_acc_3             ; 40D1 1 208 180 CA02
                MOVB    r0, #001h              ; 40D3 1 208 180 9801
idle_temp_hyst3_mul_acc_3:     MUL                            ; 40D5 1 208 180 9035
                MB      C, PSWL.4              ; 40D7 1 208 180 A32C
                JLT     idle_temp_hyst3_sub_er2             ; 40D9 1 208 180 CA06
                ADD     er2, A                 ; 40DB 1 208 180 4681
                L       A, er3                 ; 40DD 1 208 180 37
                ADC     A, er1                 ; 40DE 1 208 180 19
                SJ      idle_temp_hyst3_load_dp_2             ; 40DF 1 208 180 CB04
idle_temp_hyst3_sub_er2:     SUB     er2, A                 ; 40E1 1 208 180 46A1
                L       A, er3                 ; 40E3 1 208 180 37
                SBC     A, er1                 ; 40E4 1 208 180 39
idle_temp_hyst3_load_dp_2:     MOV     DP, #05554h            ; 40E5 1 208 180 625455
                CMPC    A, [DP]                ; 40E8 1 208 180 92AC
                JLT     idle_temp_hyst3_rom_load_dp_ind             ; 40EA 1 208 180 CA06
                INC     DP                     ; 40EC 1 208 180 72
                INC     DP                     ; 40ED 1 208 180 72
                CMPC    A, [DP]                ; 40EE 1 208 180 92AC
                JLT     idle_temp_hyst3_store_tbl_x1             ; 40F0 1 208 180 CA04
idle_temp_hyst3_rom_load_dp_ind:     LC      A, [DP]                ; 40F2 1 208 180 92A8
                CLR     er2                    ; 40F4 1 208 180 4615
idle_temp_hyst3_store_tbl_x1:     ST      A, 00000h[X1]          ; 40F6 1 208 180 D00000
                L       A, er2                 ; 40F9 1 208 180 36
                ST      A, 00002h[X1]          ; 40FA 1 208 180 D00200
idle_temp_hyst3_load_ram25a_2:     L       A, off(0025ah)         ; 40FD 1 208 180 E45A
                JBS     off(00216h).6, idle_temp_hyst3_store_er3_3 ; 40FF 1 208 180 EE1602
                L       A, off(0025ch)         ; 4102 1 208 180 E45C
idle_temp_hyst3_store_er3_3:     ST      A, er3                 ; 4104 1 208 180 8B
                L       A, off(00252h)         ; 4105 1 208 180 E452
                SJ      idle_temp_hyst3_clear_ram09e_bit3_3             ; 4107 1 208 180 CB22
idle_temp_hyst3_load_er3_4:     MOV     er3, off(00268h)       ; 4109 1 208 180 B4684B
                SJ      idle_temp_hyst3_rom_load_ram5558             ; 410C 1 208 180 CB12
idle_temp_hyst3_load_er3_5:     MOV     er3, #00900h           ; 410E 1 208 180 47980009
                SJ      idle_temp_hyst3_rom_load_ram5558             ; 4112 1 208 180 CB0C
idle_temp_hyst3_clear_er3:     CLR     er3                    ; 4114 1 208 180 4715
                SJ      idle_temp_hyst3_load_ram260_2             ; 4116 1 208 180 CB03
idle_temp_hyst3_load_er3_6:     MOV     er3, off(0025ah)       ; 4118 0 208 180 B45A4B
idle_temp_hyst3_load_ram260_2:     L       A, off(00260h)         ; 411B 1 208 180 E460
                CAL     tipin_time_finalize_sub_load_acc             ; 411D 1 208 180 32B544
idle_temp_hyst3_rom_load_ram5558:     LC      A, 05558h              ; 4120 1 208 180 909C5855
                JBS     off(00220h).0, idle_temp_hyst3_clear_ram09e_bit3_3 ; 4124 1 208 180 E82004
                LC      A, 0555ah              ; 4127 1 208 180 909C5A55
idle_temp_hyst3_clear_ram09e_bit3_3:     RB      09eh.3                 ; 412B 1 208 180 C59E0B
                JEQ     idle_temp_hyst3_call_44b5             ; 412E 1 208 180 C909
                PUSHS   A                      ; 4130 1 208 180 55
                L       A, er3                 ; 4131 1 208 180 37
                PUSHS   A                      ; 4132 1 208 180 55
                CAL     vcal_4_load_dp             ; 4133 1 208 180 32C836
                POPS    A                      ; 4136 1 208 180 65
                ST      A, er3                 ; 4137 1 208 180 8B
                POPS    A                      ; 4138 1 208 180 65
idle_temp_hyst3_call_44b5:     CAL     tipin_time_finalize_sub_load_acc             ; 4139 1 208 180 32B544
                L       A, off(00240h)         ; 413C 1 208 180 E440
                CAL     tipin_time_finalize_sub_load_acc             ; 413E 1 208 180 32B544
                L       A, off(00244h)         ; 4141 1 208 180 E444
                CAL     tipin_time_finalize_sub_load_acc             ; 4143 1 208 180 32B544
                L       A, off(00284h)         ; 4146 1 208 180 E484
                CAL     tipin_time_finalize_sub_load_acc             ; 4148 1 208 180 32B544
                L       A, off(0026ah)         ; 414B 1 208 180 E46A
                CAL     tipin_time_finalize_sub_load_acc             ; 414D 1 208 180 32B544
                L       A, off(0024ah)         ; 4150 1 208 180 E44A
                SJ      idle_temp_hyst3_clear_ram09e_bit3_4             ; 4152 1 208 180 CB07
idle_temp_hyst3_load_er3_7:     MOV     er3, off(0025eh)       ; 4154 1 208 180 B45E4B
                MOV     DP, #0030eh            ; 4157 1 208 180 620E03
                L       A, [DP]                ; 415A 1 208 180 E2
idle_temp_hyst3_clear_ram09e_bit3_4:     RB      09eh.3                 ; 415B 1 208 180 C59E0B
                JEQ     idle_temp_hyst3_call_44b5_2             ; 415E 1 208 180 C909
                PUSHS   A                      ; 4160 1 208 180 55
                L       A, er3                 ; 4161 1 208 180 37
                PUSHS   A                      ; 4162 1 208 180 55
                CAL     vcal_4_load_dp             ; 4163 1 208 180 32C836
                POPS    A                      ; 4166 1 208 180 65
                ST      A, er3                 ; 4167 1 208 180 8B
                POPS    A                      ; 4168 1 208 180 65
idle_temp_hyst3_call_44b5_2:     CAL     tipin_time_finalize_sub_load_acc             ; 4169 1 208 180 32B544
                MB      C, ACCH.7              ; 416C 1 208 180 C5072F
                JLT     idle_temp_hyst3_clear_acc_5             ; 416F 1 208 180 CA35
                CLR     A                      ; 4171 1 208 180 F9
                LB      A, off(00299h)         ; 4172 0 208 180 F499
                L       A, ACC                 ; 4174 1 208 180 E506
                SWAP                           ; 4176 1 208 180 83
                MOV     er0, er3               ; 4177 1 208 180 4748
                MUL                            ; 4179 1 208 180 9035
                SLL     A                      ; 417B 1 208 180 53
                L       A, er1                 ; 417C 1 208 180 35
                ROL     A                      ; 417D 1 208 180 33
                MB      C, ACCH.7              ; 417E 1 208 180 C5072F
                JGE     idle_temp_hyst3_store_er3_4             ; 4181 1 208 180 CD03
                L       A, #07fffh             ; 4183 1 208 180 67FF7F
idle_temp_hyst3_store_er3_4:     ST      A, er3                 ; 4186 1 208 180 8B
                L       A, off(00266h)         ; 4187 1 208 180 E466
                CAL     tipin_time_finalize_sub_load_acc             ; 4189 1 208 180 32B544
                L       A, off(0026ch)         ; 418C 1 208 180 E46C
                CAL     tipin_time_finalize_sub_load_acc             ; 418E 1 208 180 32B544
                L       A, er3                 ; 4191 1 208 180 37
idle_temp_hyst3_if_eq_goto_41a6:     JEQ     idle_temp_hyst3_clear_acc_5             ; 4192 1 208 180 C912
                MB      C, ACCH.7              ; 4194 1 208 180 C5072F
                JLT     idle_temp_hyst3_clear_acc_5             ; 4197 1 208 180 CA0D
                MOV     er3, #04000h           ; 4199 1 208 180 47980040
                CMP     A, er3                 ; 419D 1 208 180 4B
                JLT     idle_gear_target_store             ; 419E 1 208 180 CA12
                L       A, er3                 ; 41A0 1 208 180 37
                JBS     off(00216h).7, idle_gear_target_store ; 41A1 1 208 180 EF160E
                SJ      idle_gear_target_reset             ; 41A4 1 208 180 CB04
idle_temp_hyst3_clear_acc_5:     CLR     A                      ; 41A6 1 208 180 F9
                JBR     off(00216h).7, idle_gear_target_store ; 41A7 1 208 180 DF1608
idle_gear_target_reset:     MOV     off(00254h), off(00256h) ; 41AA 1 208 180 B4567C54
                MOVB    off(0029fh), off(002a0h) ; 41AE 1 208 180 C4A07C9F
idle_gear_target_store:     ST      A, off(0023ch)         ; 41B2 1 208 180 D43C
                MOV     X1, #idle_gear_target_store_tbl          ; 41B4 1 208 180 608E56
                CAL     idleign_table_lookup_sub_load_acc             ; 41B7 1 208 180 324644
idle_gear_target_final:     ST      A, off(0026eh)         ; 41BA 1 208 180 D46E
                MB      C, off(00216h).2       ; 41BC 1 208 180 C4162A
                MB      off(00216h).3, C       ; 41BF 1 208 180 C4163B
                RB      09eh.3                 ; 41C2 1 208 180 C59E0B
                JEQ     idle_gear_target_final_return             ; 41C5 1 208 180 C903
                CAL     vcal_4_load_dp             ; 41C7 1 208 180 32C836
idle_gear_target_final_return:     RT                             ; 41CA 1 208 180 01
vcal_4_load_r0:     MOVB    r0, #00eh              ; 41CB 0 208 180 980E
                MOV     DP, #001e1h            ; 41CD 0 208 180 62E101
                CAL     learn_table2_check_sub_clear_pswh_bit0             ; 41D0 0 208 180 32A949
                MOVB    r0, #01eh              ; 41D3 0 208 180 981E
                MOV     DP, #002d5h            ; 41D5 0 208 180 62D502
                CAL     learn_table2_check_sub_clear_pswh_bit0             ; 41D8 0 208 180 32A949
                LB      A, 0ffh                ; 41DB 0 208 180 F5FF
                ADDB    A, #001h               ; 41DD 0 208 180 8601
                JEQ     vcal_4_load_ram2c0             ; 41DF 0 208 180 C902
                STB     A, 0ffh                ; 41E1 0 208 180 D5FF
vcal_4_load_ram2c0:     LB      A, off(002c0h)         ; 41E3 0 208 180 F4C0
                JEQ     percyl_counter_gate             ; 41E5 0 208 180 C914
                CMPB    off(002e0h), #000h     ; 41E7 0 208 180 C4E0C000
                JNE     percyl_alt_check             ; 41EB 0 208 180 CE7A
                MOVB    r2, #010h              ; 41ED 0 208 180 9A10
                CMPB    A, r2                  ; 41EF 0 208 180 4A
                JGE     percyl_counter_check2             ; 41F0 0 208 180 CD02
                MOVB    r2, #001h              ; 41F2 0 208 180 9A01
percyl_counter_check2:     SUBB    A, r2                  ; 41F4 0 208 180 2A
                MOV     er1, #01107h           ; 41F5 0 208 180 45980711
                JNE     percyl_store_result             ; 41F9 0 208 180 CE61
percyl_counter_gate:     SC                             ; 41FB 0 208 180 85
                JBR     off(00212h).7, percyl_counter_gate_clear_acc ; 41FC 0 208 180 DF1203
                J       percyl_counter_gate_store_carry_ram226_bit4             ; 41FF 0 208 180 037942
percyl_counter_gate_clear_acc:     CLR     A                      ; 4202 1 208 180 F9
percyl_counter_gate_load_ram2c1:     LB      A, off(002c1h)         ; 4203 0 208 180 F4C1
                CMPB    A, #020h               ; 4205 0 208 180 C620
                JLT     percyl_counter_dp_select             ; 4207 0 208 180 CA0F
                CLRB    off(002c1h)            ; 4209 0 208 180 C4C115
                LCB     A, 07ff1h              ; 420C 0 208 180 909DF17F
                JNE     percyl_counter_gate_store_carry_ram226_bit4             ; 4210 0 208 180 CE67
                LB      A, 0d5h                ; 4212 0 208 180 F5D5
                JEQ     percyl_counter_gate_store_carry_ram226_bit4             ; 4214 0 208 180 C963
                SJ      percyl_bcd_convert             ; 4216 0 208 180 CB3A
percyl_counter_dp_select:     MOV     DP, #00333h            ; 4218 0 208 180 623303
                CMPB    A, #018h               ; 421B 0 208 180 C618
                JGE     percyl_counter_increment             ; 421D 0 208 180 CD09
                DEC     DP                     ; 421F 0 208 180 82
                JBS     off(002c1h).4, percyl_counter_increment ; 4220 0 208 180 ECC105
                DEC     DP                     ; 4223 0 208 180 82
                JBS     off(002c1h).3, percyl_counter_increment ; 4224 0 208 180 EBC101
                DEC     DP                     ; 4227 0 208 180 82
percyl_counter_increment:     INCB    off(002c1h)            ; 4228 0 208 180 C4C116
                TRB     [DP]                   ; 422B 0 208 180 C213 ; [H] ;mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C213
                JNE     percyl_wrap_check1             ; 422D 0 208 180 CE09
                LB      A, off(002c1h)         ; 422F 0 208 180 F4C1
                ANDB    A, #007h               ; 4231 0 208 180 D607
                JNE     percyl_counter_gate_load_ram2c1             ; 4233 0 208 180 CECE
                RC                             ; 4235 0 208 180 95
                SJ      percyl_counter_gate_store_carry_ram226_bit4             ; 4236 0 208 180 CB41
percyl_wrap_check1:     ADDB    A, #001h               ; 4238 0 208 180 8601
                CMPB    A, #01dh               ; 423A 0 208 180 C61D
                JNE     percyl_wrap_check2             ; 423C 0 208 180 CE02
                LB      A, #02bh               ; 423E 0 208 180 772B
percyl_wrap_check2:     CMPB    A, #01bh               ; 4240 0 208 180 C61B
                JNE     percyl_wrap_check3             ; 4242 0 208 180 CE02
                LB      A, #029h               ; 4244 0 208 180 7729
percyl_wrap_check3:     CMPB    A, #01ah               ; 4246 0 208 180 C61A
                JNE     percyl_wrap_check4             ; 4248 0 208 180 CE02
                LB      A, #024h               ; 424A 0 208 180 7724
percyl_wrap_check4:     CMPB    A, #019h               ; 424C 0 208 180 C619
                JNE     percyl_bcd_convert             ; 424E 0 208 180 CE02
                LB      A, #023h               ; 4250 0 208 180 7723
percyl_bcd_convert:     MOVB    r0, #00ah              ; 4252 0 208 180 980A
                DIVB                           ; 4254 0 208 180 A236
                SWAPB                          ; 4256 0 208 180 83
                ORB     A, r1                  ; 4257 0 208 180 69
                MOV     er1, #02b20h           ; 4258 0 208 180 4598202B
percyl_store_result:     STB     A, off(002c0h)         ; 425C 0 208 180 D4C0
                CMPB    A, #010h               ; 425E 0 208 180 C610
                JLT     percyl_result_final             ; 4260 0 208 180 CA02
                MOVB    r2, r3                 ; 4262 0 208 180 234A
percyl_result_final:     MOVB    off(002e0h), r2        ; 4264 0 208 180 227CE0
percyl_alt_check:     CMPB    A, #010h               ; 4267 0 208 180 C610
                L       A, #00206h             ; 4269 1 208 180 670602
                JLT     percyl_alt_store             ; 426C 1 208 180 CA03
                L       A, #00311h             ; 426E 1 208 180 671103
percyl_alt_store:     ST      A, er1                 ; 4271 1 208 180 89
                LB      A, off(002e0h)         ; 4272 0 208 180 F4E0
                CMPB    A, r2                  ; 4274 0 208 180 4A
                JGE     percyl_counter_gate_store_carry_ram226_bit4             ; 4275 0 208 180 CD02
                CMPB    r3, A                  ; 4277 0 208 180 23C1
percyl_counter_gate_store_carry_ram226_bit4:     MB      off(00226h).4, C       ; 4279 0 208 180 C4263C
                JBR     off(00224h).2, percyl_counter_gate_clear_pswl_bit4 ; 427C 0 208 180 DA2419
                MOV     DP, #00330h            ; 427F 0 208 180 623003
                L       A, [DP]                ; 4282 1 208 180 E2
                JNE     percyl_counter_gate_store_carry_ram226_bit3             ; 4283 1 208 180 CE10
                INC     DP                     ; 4285 1 208 180 72
                INC     DP                     ; 4286 1 208 180 72
                L       A, [DP]                ; 4287 1 208 180 E2
                JNE     percyl_counter_gate_store_carry_ram226_bit3             ; 4288 1 208 180 CE0B
                LCB     A, 07ff1h              ; 428A 1 208 180 909DF17F
                JNE     percyl_counter_gate_set_carry             ; 428E 1 208 180 CE04
                LB      A, 0d5h                ; 4290 0 208 180 F5D5
                JNE     percyl_counter_gate_store_carry_ram226_bit3             ; 4292 0 208 180 CE01
percyl_counter_gate_set_carry:     SC                             ; 4294 0 208 180 85
percyl_counter_gate_store_carry_ram226_bit3:     MB      off(00226h).3, C       ; 4295 0 208 180 C4263B
percyl_counter_gate_clear_pswl_bit4:     RB      PSWL.4                 ; 4298 0 208 180 A30C
                SB      PSWL.5                 ; 429A 0 208 180 A31D
                JBR     off(00220h).4, percyl_counter_gate_load_carry_pswl_bit4 ; 429C 0 208 180 DC202B
                JBS     off(00212h).5, percyl_counter_gate_load_carry_pswl_bit4 ; 429F 0 208 180 ED1228
                JBS     off(00213h).1, percyl_counter_gate_load_carry_pswl_bit4 ; 42A2 0 208 180 E91325
                JBS     off(00213h).0, percyl_counter_gate_load_carry_pswl_bit4 ; 42A5 0 208 180 E81322
                L       A, off(00210h)         ; 42A8 1 208 180 E410
                AND     A, #001bch             ; 42AA 1 208 180 D6BC01
                JNE     percyl_counter_gate_load_carry_pswl_bit4             ; 42AD 1 208 180 CE1B
                JBR     off(00215h).0, percyl_counter_gate_load_carry_pswl_bit4 ; 42AF 1 208 180 D81518
                JBS     off(00215h).1, percyl_counter_gate_load_carry_pswl_bit4 ; 42B2 1 208 180 E91515
                SB      PSWL.4                 ; 42B5 1 208 180 A31C
                RB      PSWL.5                 ; 42B7 1 208 180 A30D
                LB      A, 0d9h                ; 42B9 0 208 180 F5D9
                CMPB    A, #0ffh               ; 42BB 0 208 180 C6FF
                JLE     percyl_counter_gate_load_carry_pswl_bit4             ; 42BD 0 208 180 CF0B
                CMPB    A, #0ffh               ; 42BF 0 208 180 C6FF
                JGE     percyl_counter_gate_load_carry_pswl_bit4             ; 42C1 0 208 180 CD07
                SB      off(00226h).5          ; 42C3 0 208 180 C4261D
                JEQ     percyl_counter_gate_load_carry_pswl_bit4             ; 42C6 0 208 180 C902
                RB      PSWL.4                 ; 42C8 0 208 180 A30C
percyl_counter_gate_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 42CA 0 208 180 A32C
                MB      off(00226h).5, C       ; 42CC 0 208 180 C4263D
                MB      C, PSWL.5              ; 42CF 0 208 180 A32D
                MB      off(0022ah).3, C       ; 42D1 0 208 180 C42A3B
                CAL     percyl_counter_gate_sub_load_dp             ; 42D4 0 208 180 32304D
                RB      09eh.3                 ; 42D7 0 208 180 C59E0B
                JEQ     percyl_counter_gate_return             ; 42DA 0 208 180 C903
                CAL     vcal_4_load_dp             ; 42DC 0 208 180 32C836
percyl_counter_gate_return:     RT                             ; 42DF 0 208 180 01
vcal_4_load_r0_2:     MOVB    r0, #005h              ; 42E0 0 208 180 9805
                MOV     DP, #001dch            ; 42E2 0 208 180 62DC01
                CAL     learn_table2_check_sub_clear_pswh_bit0             ; 42E5 0 208 180 32A949
                MOVB    r0, #008h              ; 42E8 0 208 180 9808
                MOV     DP, #002cdh            ; 42EA 0 208 180 62CD02
                CAL     learn_table2_check_sub_clear_pswh_bit0             ; 42ED 0 208 180 32A949
                LB      A, 0feh                ; 42F0 0 208 180 F5FE
                ADDB    A, #001h               ; 42F2 0 208 180 8601
                JEQ     vcal_4_load_imm_3             ; 42F4 0 208 180 C902
                STB     A, 0feh                ; 42F6 0 208 180 D5FE
vcal_4_load_imm_3:     LB      A, #0ffh               ; 42F8 0 208 180 77FF
                CMPB    A, (001d9h-00180h)[USP] ; 42FA 0 208 180 C359C2
                JLE     vcal_4_cmp_acc             ; 42FD 0 208 180 CF03
                INCB    (001d9h-00180h)[USP]   ; 42FF 0 208 180 C35916
vcal_4_cmp_acc:     CMPB    A, (001d8h-00180h)[USP] ; 4302 0 208 180 C358C2
                JLE     vcal_4_load_ram29a             ; 4305 0 208 180 CF03
                INCB    (001d8h-00180h)[USP]   ; 4307 0 208 180 C35816
vcal_4_load_ram29a:     L       A, off(0029ah)         ; 430A 1 208 180 E49A
                JEQ     learn_table1_check             ; 430C 1 208 180 C903
                DEC     off(0029ah)            ; 430E 1 208 180 B49A17
learn_table1_check:     LB      A, off(002cfh)         ; 4311 0 208 180 F4CF
                JNE     learn_table2_check             ; 4313 0 208 180 CE27
                MOVB    off(002cfh), #005h     ; 4315 0 208 180 C4CF9805
                MOV     X1, #learn_table1_check_tbl          ; 4319 0 208 180 607557
                MOV     DP, #001a6h            ; 431C 0 208 180 62A601
                MOVB    r6, #027h              ; 431F 0 208 180 9E27
learn_table1_loop:     LB      A, [DP]                ; 4321 0 208 180 F2
                ADDB    A, #001h               ; 4322 0 208 180 8601
                CMPCB   A, [X1]                ; 4324 0 208 180 90AE
                JLT     learn_table1_store             ; 4326 0 208 180 CA02
                LCB     A, [X1]                ; 4328 0 208 180 90AA
learn_table1_store:     STB     A, [DP]                ; 432A 0 208 180 D2
                LB      A, r6                  ; 432B 0 208 180 7E
                SUBB    A, 0f1h                ; 432C 0 208 180 C5F1A2
                JNE     learn_table1_advance             ; 432F 0 208 180 CE02
                STB     A, 0f1h                ; 4331 0 208 180 D5F1
learn_table1_advance:     INC     X1                     ; 4333 0 208 180 70
                INC     DP                     ; 4334 0 208 180 72
                INCB    r6                     ; 4335 0 208 180 AE
                CMP     DP, #001aah            ; 4336 0 208 180 92C0AA01
                JLE     learn_table1_loop             ; 433A 0 208 180 CFE5
learn_table2_check:     LB      A, off(002d2h)         ; 433C 0 208 180 F4D2
                JNE     learn_table2_check_clear_ram09e_bit3             ; 433E 0 208 180 CE26
                MOVB    off(002d2h), #005h     ; 4340 0 208 180 C4D29805
                LB      A, #001h               ; 4344 0 208 180 7701
                MB      C, 09eh.0              ; 4346 0 208 180 C59E28
                JLT     learn_counter_store             ; 4349 0 208 180 CA0A
                LB      A, 0d7h                ; 434B 0 208 180 F5D7
                ADDB    A, #001h               ; 434D 0 208 180 8601
                CMPB    A, #010h               ; 434F 0 208 180 C610
                JLT     learn_counter_store             ; 4351 0 208 180 CA02
                LB      A, #010h               ; 4353 0 208 180 7710
learn_counter_store:     STB     A, 0d7h                ; 4355 0 208 180 D5D7
                LB      A, 0d6h                ; 4357 0 208 180 F5D6
                ADDB    A, #001h               ; 4359 0 208 180 8601
                CMPB    A, #010h               ; 435B 0 208 180 C610
                JLT     learn_counter_store_store_ram0d6             ; 435D 0 208 180 CA05
                RB      09eh.0                 ; 435F 0 208 180 C59E08
                LB      A, #010h               ; 4362 0 208 180 7710
learn_counter_store_store_ram0d6:     STB     A, 0d6h                ; 4364 0 208 180 D5D6
learn_table2_check_clear_ram09e_bit3:     RB      09eh.3                 ; 4366 0 208 180 C59E0B
                JEQ     learn_table2_check_return             ; 4369 0 208 180 C903
                CAL     vcal_4_load_dp             ; 436B 0 208 180 32C836
learn_table2_check_return:     RT                             ; 436E 0 208 180 01
calchecksum_loop_sub_load_x1:     MOV     X1, A                  ; 436F 1 208 180 50
                MOV     X2, A                  ; 4370 1 208 180 51
                MOV     DP, A                  ; 4371 1 208 180 52
                CMP     A, X1                  ; 4372 1 208 180 90C2
                JNE     calchecksum_loop_sub_return             ; 4374 1 208 180 CE06
                CMP     A, X2                  ; 4376 1 208 180 91C2
                JNE     calchecksum_loop_sub_return             ; 4378 1 208 180 CE02
                CMP     A, DP                  ; 437A 1 208 180 92C2
calchecksum_loop_sub_return:     RT                             ; 437C 1 208 180 01
learn_table2_check_sub_load_dp_ind:     L       A, [DP]                ; 437D 1 208 180 E2
                CMP     A, #0ffffh             ; 437E 1 208 180 C6FFFF
                JNE     learn_table2_check_sub_xor_acc             ; 4381 1 208 180 CE01
                CLR     A                      ; 4383 1 208 180 F9
learn_table2_check_sub_xor_acc:     XOR     A, #0ffffh             ; 4384 1 208 180 F6FFFF
                ST      A, 00000h[X1]          ; 4387 1 208 180 D00000
                CMP     A, 00002h[X1]          ; 438A 1 208 180 B00200C2
                JLT     learn_table2_check_sub_cmp_acc             ; 438E 1 208 180 CA04
                ST      A, 00002h[X1]          ; 4390 1 208 180 D00200
                RT                             ; 4393 1 208 180 01
learn_table2_check_sub_cmp_acc:     CMP     A, 00004h[X1]          ; 4394 1 208 180 B00400C2
                JGT     learn_table2_check_sub_return             ; 4398 1 208 180 C803
                ST      A, 00004h[X1]          ; 439A 1 208 180 D00400
learn_table2_check_sub_return:     RT                             ; 439D 1 208 180 01
vcal_0:         LB      A, ACC                 ; 439E 0 200 180 F506
vcal_0_cmp_acc:     CMPCB   A, 00002h[X1]          ; 43A0 0 200 180 90AF0200
; [H] --- Generic 1D linear-interpolation table lookup, used 50 times throughout the file (flex
; [H] fuel, boost/wastegate control, GIO trims, ignition/O2 corrections, etc). Given a table
; [H] pointer in X1 (entries are (X,Y) byte pairs) and an input value in A, walks the table to
; [H] find the bracketing X segment, then linearly interpolates the corresponding Y. This is the
; [H] same routine flex-fuel notes describe as "the shared interpolation helper".
                JGE     table_interp_bracket_found             ; 43A4 0 200 180 CD04
                INC     X1                     ; 43A6 0 200 180 70
                INC     X1                     ; 43A7 0 200 180 70
                SJ      vcal_0_cmp_acc             ; 43A8 0 200 180 CBF6
table_interp_bracket_found:     STB     A, r0                  ; 43AA 0 200 180 88
                LCB     A, 00003h[X1]          ; 43AB 0 200 180 90AB0300
                STB     A, r6                  ; 43AF 0 200 180 8E
                LCB     A, 00001h[X1]          ; 43B0 0 200 180 90AB0100
                STB     A, r7                  ; 43B4 0 200 180 8F
table_interp_delta_calc:     LCB     A, 00002h[X1]          ; 43B5 0 200 180 90AB0200
                STB     A, r1                  ; 43B9 0 200 180 89
                SUBB    r0, A                  ; 43BA 0 200 180 20A1
                LCB     A, [X1]                ; 43BC 0 200 180 90AA
                SUBB    A, r1                  ; 43BE 0 200 180 29
                STB     A, r1                  ; 43BF 0 200 180 89
                LB      A, r7                  ; 43C0 0 200 180 7F
                SUBB    A, r6                  ; 43C1 0 200 180 2E
                MB      PSWL.4, C              ; 43C2 0 200 180 A33C
                JGE     table_interp_delta_calc_mulb_acc             ; 43C4 0 200 180 CD03
                STB     A, r7                  ; 43C6 0 200 180 8F
                CLRB    A                      ; 43C7 0 200 180 FA
                SUBB    A, r7                  ; 43C8 0 200 180 2F
table_interp_delta_calc_mulb_acc:     MULB                           ; 43C9 0 200 180 A234
                MOVB    r0, r1                 ; 43CB 0 200 180 2148
                DIVB                           ; 43CD 0 200 180 A236
                MB      C, PSWL.4              ; 43CF 0 200 180 A32C
                JGE     table_interp_delta_calc_addb_acc             ; 43D1 0 200 180 CD04
                SUBB    r6, A                  ; 43D3 0 200 180 26A1
                LB      A, r6                  ; 43D5 0 200 180 7E
                RT                             ; 43D6 0 200 180 01
table_interp_delta_calc_addb_acc:     ADDB    A, r6                  ; 43D7 0 200 180 0E
                STB     A, r6                  ; 43D8 0 200 180 8E
                RT                             ; 43D9 0 200 180 01
vcal_2:         LB      A, ACC                 ; 43DA 0 200 180 F506
                CMPCB   A, [X1]                ; 43DC 0 200 180 90AE
                JLT     vcal1_bracket_check             ; 43DE 0 200 180 CA02
                LCB     A, [X1]                ; 43E0 0 200 180 90AA
vcal1_bracket_check:     CMPCB   A, 00002h[X1]          ; 43E2 0 200 180 90AF0200
                JGE     vcal1_bracket_check_goto_table_interp_bracket_found             ; 43E6 0 200 180 CD04
                LCB     A, 00002h[X1]          ; 43E8 0 200 180 90AB0200
vcal1_bracket_check_goto_table_interp_bracket_found:     SJ      table_interp_bracket_found             ; 43EC 0 200 180 CBBC
knockretard_table_gate_sub_load_acc:     LB      A, ACC                 ; 43EE 0 200 180 F506
                CMPCB   A, [X1]                ; 43F0 0 200 180 90AE
                JLT     knockretard_r1_store             ; 43F2 0 200 180 CA02
                LCB     A, [X1]                ; 43F4 0 200 180 90AA
knockretard_r1_store:     CMPCB   A, 00002h[X1]          ; 43F6 0 200 180 90AF0200
                JGE     knockretard_sub_result             ; 43FA 0 200 180 CD04
                LCB     A, 00002h[X1]          ; 43FC 0 200 180 90AB0200
knockretard_sub_result:     MOVB    r0, A                  ; 4400 0 200 180 208A
                J       table_interp_delta_calc             ; 4402 0 200 180 03B543
vcal_1:         LB      A, ACC                 ; 4405 0 208 180 F506
vcal_1_cmp_acc:     CMPCB   A, 00003h[X1]          ; 4407 0 208 180 90AF0300
                JGE     vcal_common_interp             ; 440B 0 208 180 CD06
                ADD     X1, #00003h            ; 440D 0 208 180 90800300
                SJ      vcal_1_cmp_acc             ; 4411 0 208 180 CBF4
vcal_common_interp:     STB     A, r0                  ; 4413 0 208 180 88
                LCB     A, 00003h[X1]          ; 4414 0 208 180 90AB0300
                STB     A, r4                  ; 4418 0 208 180 8C
                SUBB    r0, A                  ; 4419 0 208 180 20A1
                CLRB    r1                     ; 441B 0 208 180 2115
                LCB     A, [X1]                ; 441D 0 208 180 90AA
                SUBB    A, r4                  ; 441F 0 208 180 2C
                STB     A, r4                  ; 4420 0 208 180 8C
                CLRB    r5                     ; 4421 0 208 180 2515
                CLR     A                      ; 4423 1 208 180 F9
                LC      A, 00004h[X1]          ; 4424 1 208 180 90A90400
                ST      A, er3                 ; 4428 1 208 180 8B
                LC      A, 00001h[X1]          ; 4429 1 208 180 90A90100
injtimer_bank_calc3:     SUB     A, er3                 ; 442D 1 208 180 2B
                MB      PSWL.4, C              ; 442E 1 208 180 A33C
                JGE     injtimer_bank_calc3_mul_acc             ; 4430 1 208 180 CD03
                ST      A, er1                 ; 4432 1 208 180 89
                CLR     A                      ; 4433 1 208 180 F9
                SUB     A, er1                 ; 4434 1 208 180 29
injtimer_bank_calc3_mul_acc:     MUL                            ; 4435 1 208 180 9035
                MOV     er0, er1               ; 4437 1 208 180 4548
                DIV                            ; 4439 1 208 180 9037
                MB      C, PSWL.4              ; 443B 1 208 180 A32C
                JGE     injtimer_bank_calc3_add_acc             ; 443D 1 208 180 CD04
                SUB     er3, A                 ; 443F 1 208 180 47A1
                L       A, er3                 ; 4441 1 208 180 37
                RT                             ; 4442 1 208 180 01
injtimer_bank_calc3_add_acc:     ADD     A, er3                 ; 4443 1 208 180 0B
                ST      A, er3                 ; 4444 1 208 180 8B
                RT                             ; 4445 1 208 180 01
idleign_table_lookup_sub_load_acc:     L       A, ACC                 ; 4446 1 208 180 E506
table_interp_lookup_4byte:     CMPC    A, 00004h[X1]          ; 4448 1 208 180 90AD0400
                JGE     table_interp_4byte_bracket             ; 444C 1 208 180 CD06
                ADD     X1, #00004h            ; 444E 1 208 180 90800400
                SJ      table_interp_lookup_4byte             ; 4452 1 208 180 CBF4
table_interp_4byte_bracket:     ST      A, er0                 ; 4454 1 208 180 88
                LC      A, 00004h[X1]          ; 4455 1 208 180 90A90400
                ST      A, er2                 ; 4459 1 208 180 8A
                SUB     er0, A                 ; 445A 1 208 180 44A1 ; [HTS120] - the value you found in the label_4999 loop
                LC      A, [X1]                ; 445C 1 208 180 90A8
                SUB     A, er2                 ; 445E 1 208 180 2A
                ST      A, er2                 ; 445F 1 208 180 8A
                LC      A, 00006h[X1]          ; 4460 1 208 180 90A90600
                ST      A, er3                 ; 4464 1 208 180 8B
                LC      A, 00002h[X1]          ; 4465 1 208 180 90A90200
                SJ      injtimer_bank_calc3             ; 4469 1 208 180 CBC2
vcal_3:         LB      A, ACC                 ; 446B 0 208 180 F506
                CMPCB   A, [X1]                ; 446D 0 208 180 90AE
                JLT     vcal_3_cmp_acc             ; 446F 0 208 180 CA02
                LCB     A, [X1]                ; 4471 0 208 180 90AA
vcal_3_cmp_acc:     CMPCB   A, 00003h[X1]          ; 4473 0 208 180 90AF0300
                JGE     vcal_3_goto_vcal_common_interp             ; 4477 0 208 180 CD04
                LCB     A, 00003h[X1]          ; 4479 0 208 180 90AB0300
vcal_3_goto_vcal_common_interp:     SJ      vcal_common_interp             ; 447D 0 208 180 CB94
subtract24_clamp_byte:     SUBB    A, #018h               ; 447F 0 200 180 A618
                JGE     subtract24_clamp_byte_load_carry_ramacc_bit7             ; 4481 0 200 180 CD02
                CLRB    A                      ; 4483 0 200 180 FA
                RT                             ; 4484 0 200 180 01
subtract24_clamp_byte_load_carry_ramacc_bit7:     MB      C, ACCH.7              ; 4485 0 200 180 C5072F
                ROLB    A                      ; 4488 0 200 180 33
                JGE     subtract24_clamp_byte_return             ; 4489 0 200 180 CD02
                LB      A, #0ffh               ; 448B 0 200 180 77FF
subtract24_clamp_byte_return:     RT                             ; 448D 0 200 180 01
vcal_7:         MB      C, PSWH.4              ; 448E 1 200 180 A22C
                JGE     vcal_7_xor_acc             ; 4490 1 200 180 CD07
                XOR     A, #0ffffh             ; 4492 1 200 180 F6FFFF
                ADD     A, #00001h             ; 4495 1 200 180 860100
                RT                             ; 4498 1 200 180 01
vcal_7_xor_acc:     XOR     A, #086ffh             ; 4499 1 200 180 F6FF86
                RT                             ; 449C 1 200 180 01
                DB  001h ; 449D
vcal_6:         DB  0E2h ; 449E
vcal_5:         L       A, ACC                 ; 449F 1 208 180 E506
                MB      C, ACCH.7              ; 44A1 1 208 180 C5072F
                JLT     vcal_5_add_acc             ; 44A4 1 208 180 CA08
                ADD     A, er3                 ; 44A6 1 208 180 0B
                JGE     vcal4_store             ; 44A7 1 208 180 CD09
                L       A, #0ffffh             ; 44A9 1 208 180 67FFFF
                SJ      vcal4_store             ; 44AC 1 208 180 CB04
vcal_5_add_acc:     ADD     A, er3                 ; 44AE 1 208 180 0B
                JLT     vcal4_store             ; 44AF 1 208 180 CA01
                CLR     A                      ; 44B1 1 208 180 F9
vcal4_store:     ST      A, er3                 ; 44B2 1 208 180 8B
                RT                             ; 44B3 1 208 180 01
                DB  0E2h ; 44B4
tipin_time_finalize_sub_load_acc:     L       A, ACC                 ; 44B5 1 208 180 E506
                MB      C, ACCH.7              ; 44B7 1 208 180 C5072F
                JLT     tipin_time_finalize_sub_load_carry_r7_bit7             ; 44BA 1 208 180 CA0F
                MB      C, r7.7                ; 44BC 1 208 180 272F
                JLT     signext_common_add             ; 44BE 1 208 180 CA1A
                ADD     A, er3                 ; 44C0 1 208 180 0B
                MB      C, ACCH.7              ; 44C1 1 208 180 C5072F
                JGE     signext_common_add_store_er3             ; 44C4 1 208 180 CD15
                L       A, #07fffh             ; 44C6 1 208 180 67FF7F
                SJ      signext_common_add_store_er3             ; 44C9 1 208 180 CB10
tipin_time_finalize_sub_load_carry_r7_bit7:     MB      C, r7.7                ; 44CB 1 208 180 272F
                JGE     signext_common_add             ; 44CD 1 208 180 CD0B
                ADD     A, er3                 ; 44CF 1 208 180 0B
                MB      C, ACCH.7              ; 44D0 1 208 180 C5072F
                JLT     signext_common_add_store_er3             ; 44D3 1 208 180 CA06
                L       A, #08000h             ; 44D5 1 208 180 670080
                SJ      signext_common_add_store_er3             ; 44D8 1 208 180 CB01
signext_common_add:     ADD     A, er3                 ; 44DA 1 208 180 0B
signext_common_add_store_er3:     ST      A, er3                 ; 44DB 1 208 180 8B
                RT                             ; 44DC 1 208 180 01
vss_scale_apply_sub_mul_acc:     MUL                            ; 44DD 1 208 180 9035
                MOV     er2, er1               ; 44DF 1 208 180 454A
                L       A, [DP]                ; 44E1 1 208 180 E2
                MUL                            ; 44E2 1 208 180 9035
                L       A, [DP]                ; 44E4 1 208 180 E2
                SUB     A, er1                 ; 44E5 1 208 180 29
                ADD     A, er2                 ; 44E6 1 208 180 0A
                ST      A, [DP]                ; 44E7 1 208 180 D2
                RT                             ; 44E8 1 208 180 01
ect_smooth_helper:     MOVB    r0, #001h              ; 44E9 0 208 180 9801
                SUBB    A, [DP]                ; 44EB 0 208 180 C2A2
                JGE     ect_smooth_sub             ; 44ED 0 208 180 CD03
                ADDB    A, r0                  ; 44EF 0 208 180 08
                SJ      ect_smooth_store             ; 44F0 0 208 180 CB01
ect_smooth_sub:     SUBB    A, r0                  ; 44F2 0 208 180 28
ect_smooth_store:     JGE     ect_smooth_add_store             ; 44F3 0 208 180 CD01
                CLRB    A                      ; 44F5 0 208 180 FA
ect_smooth_add_store:     ADDB    A, [DP]                ; 44F6 0 208 180 C282
                STB     A, [DP]                ; 44F8 0 208 180 D2
                RT                             ; 44F9 0 208 180 01
o2trim_add_clamp_sub_sub_acc:     SUB     A, er3                 ; 44FA 1 208 180 2B
                JGE     o2trim_add_clamp_sub_mul_acc             ; 44FB 1 208 180 CD06
                XOR     A, #0ffffh             ; 44FD 1 208 180 F6FFFF
                INC     ACC                    ; 4500 1 208 180 B50616
o2trim_add_clamp_sub_mul_acc:     MUL                            ; 4503 1 208 180 9035
                JGE     o2trim_add_clamp_sub_add_er2             ; 4505 1 208 180 CD06
                SUB     er2, A                 ; 4507 1 208 180 46A1
                L       A, er1                 ; 4509 1 208 180 35
                SBC     er3, A                 ; 450A 1 208 180 47B1
                RT                             ; 450C 1 208 180 01
o2trim_add_clamp_sub_add_er2:     ADD     er2, A                 ; 450D 1 208 180 4681
                L       A, er1                 ; 450F 1 208 180 35
                ; invalid opcode encountered @4510; halting
                DB  047h,091h,001h ; 4510
scale_div32_loop_sub_clear_pswh_bit0:     RB      PSWH.0                 ; 4513 0 088 300 A208
                LB      A, P3                  ; 4515 0 088 300 F524
                ANDB    A, #0f8h               ; 4517 0 088 300 D6F8
                ORB     A, r0                  ; 4519 0 088 300 68
                XORB    A, #0ffh               ; 451A 0 088 300 F6FF
                ANDB    A, #00fh               ; 451C 0 088 300 D60F
                STB     A, P3                  ; 451E 0 088 300 D524
                SB      PSWH.0                 ; 4520 0 088 300 A218
                RT                             ; 4522 0 088 300 01
scale_result_common_sub_extnd_acc:     EXTND                          ; 4523 1 200 180 F8
                ADD     DP, A                  ; 4524 1 200 180 9281
                LC      A, [DP]                ; 4526 1 200 180 92A8
                SWAP                           ; 4528 1 200 180 83
                ST      A, er3                 ; 4529 1 200 180 8B
                J       scale_result_common_sub_load_er0             ; 452A 1 200 180 036745
scale_result_common_sub_clear_acc:     CLR     A                      ; 452D 1 200 180 F9
                LB      A, r7                  ; 452E 0 200 180 7F
                SUBB    A, r6                  ; 452F 0 200 180 2E
                MB      PSWL.4, C              ; 4530 0 200 180 A33C
                JGE     scale_result_common_sub_mul_acc             ; 4532 0 200 180 CD03
                STB     A, r7                  ; 4534 0 200 180 8F
                CLRB    A                      ; 4535 0 200 180 FA
                SUBB    A, r7                  ; 4536 0 200 180 2F
scale_result_common_sub_mul_acc:     MUL                            ; 4537 0 200 180 9035
                LB      A, r2                  ; 4539 0 200 180 7A
                RB      PSWL.4                 ; 453A 0 200 180 A30C
                JEQ     scale_result_common_sub_addb_acc             ; 453C 0 200 180 C904
                SUBB    r6, A                  ; 453E 0 200 180 26A1
                LB      A, r6                  ; 4540 0 200 180 7E
                RT                             ; 4541 0 200 180 01
scale_result_common_sub_addb_acc:     ADDB    A, r6                  ; 4542 0 200 180 0E
                STB     A, r6                  ; 4543 0 200 180 8E
                RT                             ; 4544 0 200 180 01
tipin_gate_common_sub_load_r0:     MOVB    r0, #00ah              ; 4545 0 200 180 980A
                MULB                           ; 4547 0 200 180 A234
                ADD     DP, A                  ; 4549 0 200 180 9281
                LB      A, r1                  ; 454B 0 200 180 79
                EXTND                          ; 454C 1 200 180 F8
                ADD     DP, A                  ; 454D 1 200 180 9281
                LC      A, [DP]                ; 454F 1 200 180 92A8
                ST      A, er3                 ; 4551 1 200 180 8B
                ADD     DP, #0000ah            ; 4552 1 200 180 92800A00
                MOV     er0, X2                ; 4556 1 200 180 9148
                CAL     scale_result_common_sub_clear_acc             ; 4558 1 200 180 322D45
                ; warning: had to flip DD
                STB     A, r4                  ; 455B 0 200 180 8C
                LC      A, [DP]                ; 455C 0 200 180 92A8
                MOV     er3, A                 ; 455E 0 200 180 478A
                MOV     er0, X2                ; 4560 0 200 180 9148
                CAL     scale_result_common_sub_clear_acc             ; 4562 0 200 180 322D45
                MOVB    r7, r4                 ; 4565 0 200 180 244F
scale_result_common_sub_load_er0:     MOV     er0, X1                ; 4567 0 200 180 9048
                CAL     scale_result_common_sub_clear_acc             ; 4569 0 200 180 322D45
                RT                             ; 456C 0 200 180 01
dtc_active_confirm_sub_clear_acc:     CLR     A                      ; 456D 1 208 ??? F9
                LB      A, r6                  ; 456E 0 208 ??? 7E
                SUBB    A, #001h               ; 456F 0 208 ??? A601
                STB     A, r2                  ; 4571 0 208 ??? 8A
                MOVB    r0, #008h              ; 4572 0 208 ??? 9808
                DIVB                           ; 4574 0 208 ??? A236
                MOV     X1, A                  ; 4576 0 208 ??? 50
                LB      A, r1                  ; 4577 0 208 ??? 79
                SBR     00110h[X1]             ; 4578 0 208 ??? C0100111
                SBR     00210h[X1]             ; 457C 0 208 ??? C0100211
                SBR     00330h[X1]             ; 4580 0 208 ??? C0300311
                CLR     A                      ; 4584 1 208 ??? F9
                LB      A, r2                  ; 4585 0 208 ??? 7A
                L       A, ACC                 ; 4586 1 208 ??? E506
                SLL     A                      ; 4588 1 208 ??? 53
                ADD     A, #dtc_active_confirm_tbl_2           ; 4589 1 208 ??? 86AF6C
                LC      A, [ACC]               ; 458C 1 208 ??? B506A8
                CLR     er0                    ; 458F 1 208 ??? 4415
                J       [ACC]                  ; 4591 1 208 ??? B50622
                DB  0C5h,0DAh,0C0h,01Ah,0CAh,001h,0A8h,003h ; 4594
                DB  041h,046h,062h,0E4h,003h,0F2h,053h,0CDh ; 459C
                DB  001h,0A8h,003h,041h,046h,027h,0C0h,021h ; 45A4
                DB  0C9h,001h,0A8h,003h,041h,046h,062h,0DAh ; 45AC
                DB  003h,0F2h,053h,0CDh,001h,0A8h,003h,041h ; 45B4
                DB  046h,062h,0E5h,003h,0F2h,053h,0CDh,001h ; 45BC
                DB  0A8h,0CBh,07Ah,07Fh,0C6h,022h,0C9h,006h ; 45C4
                DB  0A8h,0C6h,02Ah,0C9h,001h,0A8h,0CBh,06Dh ; 45CC
                DB  027h,0C0h,023h,0C9h,001h,0A8h,0CBh,065h ; 45D4
                DB  062h,0D2h,003h,0F2h,053h,0CDh,001h,0A8h ; 45DC
                DB  0CBh,05Bh,027h,0C0h,00Ah,0CEh,004h,098h ; 45E4
                DB  002h,0CBh,009h,062h,0E1h,003h,0C2h,0C0h ; 45EC
                DB  080h,0CAh,001h,0A8h,0CBh,047h,062h,0D3h ; 45F4
                DB  003h,0F2h,053h,0CDh,001h,0A8h,0CBh,03Dh ; 45FC
                DB  062h,0D8h,003h,0F2h,053h,0CDh,001h,0A8h ; 4604
                DB  0CBh,033h,0FAh,0CBh,031h,077h,023h,0CBh ; 460C
                DB  02Dh,062h,0E3h,003h,0F2h,053h,0CDh,001h ; 4614
                DB  0A8h,077h,024h,0CBh,021h,077h,029h,0CBh ; 461C
                DB  01Dh,0B3h,0E0h,0C0h,000h,080h,0CAh,001h ; 4624
                DB  0A8h,077h,02Bh,0CBh,011h,027h,0C0h,015h ; 462C
                DB  0CEh,001h,0A8h,0CBh,008h,027h,0C0h,016h ; 4634
                DB  0CEh,001h,0A8h,0CBh,000h,07Eh,089h,0F8h ; 463C
                DB  063h,050h,078h,0CDh,002h,086h,004h,0C0h ; 4644
                DB  048h,003h,011h,001h ; 464C
crank_tooth_count_store_sub_clear_ram0a0_bit6:     RB      0a0h.6                 ; 4650 0 108 280 C5A00E
                CLR     A                      ; 4653 1 108 280 F9
                ST      A, IGNA                ; 4654 1 108 280 D562
                RB      0a0h.5                 ; 4656 1 108 280 C5A00D
                L       A, #00001h             ; 4659 1 108 280 670100
                ST      A, IGNB                ; 465C 1 108 280 D564
                RT                             ; 465E 1 108 280 01
crankfuel_clamp_max_sub_cmp_acc:     CMP     A, 0004ch[X1]          ; 465F 1 108 280 B04C00C2
                JGE     crankfuel_clamp_max_sub_store_tbl_x1             ; 4663 1 108 280 CD08
                CMP     0004ch[X1], #0ffffh    ; 4665 1 108 280 B04C00C0FFFF
                JNE     crankfuel_clamp_max_sub_return             ; 466B 1 108 280 CE03
crankfuel_clamp_max_sub_store_tbl_x1:     ST      A, 0004ch[X1]          ; 466D 1 108 280 D04C00
crankfuel_clamp_max_sub_return:     RT                             ; 4670 1 108 280 01
tps_interp_exact_match_sub_rom_load_00026h_dp:     LC      A, 00026h[DP]          ; 4671 0 200 180 92A92600
                L       A, ACC                 ; 4675 1 200 180 E506
                MOV     er0, 0aeh              ; 4677 1 200 180 B5AE48
                CMP     er0, A                 ; 467A 1 200 180 44C1
                JGE     tps_interp_exact_match_sub_store_carry_pswl_bit5             ; 467C 1 200 180 CD01
                ST      A, er0                 ; 467E 1 200 180 88
tps_interp_exact_match_sub_store_carry_pswl_bit5:     MB      PSWL.5, C              ; 467F 1 200 180 A33D
                LC      A, [DP]                ; 4681 1 200 180 92A8
                SUB     A, #00001h             ; 4683 1 200 180 A60100
                CMP     A, er0                 ; 4686 1 200 180 48
                JGE     tps_interp_exact_match_sub_store_carry_pswl_bit4             ; 4687 1 200 180 CD01
                ST      A, er0                 ; 4689 1 200 180 88
tps_interp_exact_match_sub_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 468A 1 200 180 A33C
                CLR     A                      ; 468C 1 200 180 F9
                LB      A, #012h               ; 468D 0 200 180 7712
                CMPB    A, r6                  ; 468F 0 200 180 4E
                JLT     tps_interp_exact_match_sub_store_r6             ; 4690 0 200 180 CA01
                LB      A, r6                  ; 4692 0 200 180 7E
tps_interp_exact_match_sub_store_r6:     STB     A, r6                  ; 4693 0 200 180 8E
                ADDB    A, #001h               ; 4694 0 200 180 8601
                SLLB    A                      ; 4696 0 200 180 53
                ADD     DP, A                  ; 4697 0 200 180 9281
                L       A, er0                 ; 4699 1 200 180 34
tps_interp_exact_match_sub_dec_dp:     DEC     DP                     ; 469A 1 200 180 82
                DEC     DP                     ; 469B 1 200 180 82
                DECB    r6                     ; 469C 1 200 180 BE
                CMPC    A, [DP]                ; 469D 1 200 180 92AC
                JGE     tps_interp_exact_match_sub_dec_dp             ; 469F 1 200 180 CDF9
tps_interp_exact_match_sub_inc_dp:     INC     DP                     ; 46A1 1 200 180 72
                INC     DP                     ; 46A2 1 200 180 72
                INCB    r6                     ; 46A3 1 200 180 AE
                CMPC    A, [DP]                ; 46A4 1 200 180 92AC
                JLT     tps_interp_exact_match_sub_inc_dp             ; 46A6 1 200 180 CAF9
                LC      A, [DP]                ; 46A8 1 200 180 92A8
                SUB     er0, A                 ; 46AA 1 200 180 44A1
                ST      A, er2                 ; 46AC 1 200 180 8A
                LC      A, 0fffeh[DP]          ; 46AD 1 200 180 92A9FEFF
                SUB     A, er2                 ; 46B1 1 200 180 2A
                ST      A, er2                 ; 46B2 1 200 180 8A
                CLR     A                      ; 46B3 1 200 180 F9
                DIV                            ; 46B4 1 200 180 9037
                RT                             ; 46B6 1 200 180 01
tps_interp_exact_match_sub_clear_acc:     CLR     A                      ; 46B7 1 200 180 F9
                LB      A, #008h               ; 46B8 0 200 180 7708
                CMPB    A, r6                  ; 46BA 0 200 180 4E
                JLT     tps_interp_exact_match_sub_store_r6_2             ; 46BB 0 200 180 CA01
                LB      A, r6                  ; 46BD 0 200 180 7E
tps_interp_exact_match_sub_store_r6_2:     STB     A, r6                  ; 46BE 0 200 180 8E
                ADDB    A, #001h               ; 46BF 0 200 180 8601
                MOV     DP, #tbl_map_axis_mbar10          ; 46C1 0 200 180 625060
                ADD     DP, A                  ; 46C4 0 200 180 9281
                LB      A, r0                  ; 46C6 0 200 180 78
                ADDB    A, #001h               ; 46C7 0 200 180 8601
                MB      PSWL.4, C              ; 46C9 0 200 180 A33C
                SBCB    A, #001h               ; 46CB 0 200 180 B601
tps_interp_exact_match_sub_dec_dp_2:     DEC     DP                     ; 46CD 0 200 180 82
                DECB    r6                     ; 46CE 0 200 180 BE
                CMPCB   A, [DP]                ; 46CF 0 200 180 92AE
                JLT     tps_interp_exact_match_sub_dec_dp_2             ; 46D1 0 200 180 CAFA
tps_interp_exact_match_sub_inc_dp_2:     INC     DP                     ; 46D3 0 200 180 72
                INCB    r6                     ; 46D4 0 200 180 AE
                CMPCB   A, [DP]                ; 46D5 0 200 180 92AE
                JGE     tps_interp_exact_match_sub_inc_dp_2             ; 46D7 0 200 180 CDFA
                LCB     A, [DP]                ; 46D9 0 200 180 92AA
                STB     A, r4                  ; 46DB 0 200 180 8C
                DEC     DP                     ; 46DC 0 200 180 82
                LCB     A, [DP]                ; 46DD 0 200 180 92AA
                SUBB    r4, A                  ; 46DF 0 200 180 24A1
                CLRB    r5                     ; 46E1 0 200 180 2515
                CMPB    r6, #008h              ; 46E3 0 200 180 26C008
                JLT     tps_interp_exact_match_sub_subb_r0             ; 46E6 0 200 180 CA02
                INC     er2                    ; 46E8 0 200 180 4616
tps_interp_exact_match_sub_subb_r0:     SUBB    r0, A                  ; 46EA 0 200 180 20A1
                CLRB    r1                     ; 46EC 0 200 180 2115
                CLR     A                      ; 46EE 1 200 180 F9
                DIV                            ; 46EF 1 200 180 9037
                RT                             ; 46F1 1 200 180 01
scale_result_common_sub_extnd_acc_2:     EXTND                          ; 46F2 1 200 180 F8
                JEQ     scale_result_common_sub_add_er3             ; 46F3 1 200 180 C903
                OR      A, #0ff00h             ; 46F5 1 200 180 E600FF
scale_result_common_sub_add_er3:     ADD     er3, A                 ; 46F8 1 200 180 4781
                RT                             ; 46FA 1 200 180 01
ign_angle_to_timer_convert:     CLRB    A                      ; 46FB 0 200 180 FA
; [H] --- Converts a computed ignition angle/trim (r4) into a hardware timer-compare value
; [H] (scaling via MULB by 3 and combining with er1), used when programming the two ignition
; [H] coil-channel hardware timers (igntiming_output_coil1 and the DP=0x35D channel that follows).
; [H] Clamps the result if it would exceed 0xFE00 range (CMPB ACC,#0feh check).
                STB     A, r3                  ; 46FC 0 200 180 8B
                SUBB    A, r4                  ; 46FD 0 200 180 2C
                MOVB    r0, #003h              ; 46FE 0 200 180 9803
                MULB                           ; 4700 0 200 180 A234
                L       A, ACC                 ; 4702 1 200 180 E506
                SUB     A, er1                 ; 4704 1 200 180 29
                SLL     A                      ; 4705 1 200 180 53
                SWAP                           ; 4706 1 200 180 83
                CMPB    ACC, #0feh             ; 4707 1 200 180 C506C0FE
                JNE     ign_timer_clamp_store             ; 470B 1 200 180 CE03
                L       A, #000ffh             ; 470D 1 200 180 67FF00
ign_timer_clamp_store:     ST      A, er0                 ; 4710 1 200 180 88
                CLRB    A                      ; 4711 0 200 180 FA
                SUBB    A, r2                  ; 4712 0 200 180 2A
                SLLB    A                      ; 4713 0 200 180 53
                JNE     ign_timer_convert_return             ; 4714 0 200 180 CE03
                LB      A, #0ffh               ; 4716 0 200 180 77FF
                SC                             ; 4718 0 200 180 85
ign_timer_convert_return:     RT                             ; 4719 0 200 180 01
to_set_pswl4_flag_b_sub_clear_acc:     CLR     A                      ; 471A 1 100 280 F9
                LC      A, 05247h              ; 471B 1 100 280 909C4752
                SB      off(0011bh).0          ; 471F 1 100 280 C41B18
                JEQ     to_set_pswl4_flag_b_sub_goto_o2_trim_dp300_read             ; 4722 1 100 280 C906
                JBR     off(0012dh).1, to_set_pswl4_flag_b_sub_if_ram117_bit3_set ; 4724 1 100 280 D92D06
                JBS     off(00115h).3, to_set_pswl4_flag_b_sub_if_ram117_bit3_set ; 4727 1 100 280 EB1503
to_set_pswl4_flag_b_sub_goto_o2_trim_dp300_read:     J       o2_trim_dp300_read             ; 472A 1 100 280 03F247
to_set_pswl4_flag_b_sub_if_ram117_bit3_set:     JBS     off(00117h).3, to_set_pswl4_flag_b_sub_load_er1 ; 472D 1 100 280 EB1706
                JBR     off(00117h).2, to_set_pswl4_flag_b_sub_load_er1 ; 4730 1 100 280 DA1703
                J       to_set_pswl4_flag_b_sub_store_ram170_2             ; 4733 1 100 280 03E647
to_set_pswl4_flag_b_sub_load_er1:     MOV     er1, off(00160h)       ; 4736 1 100 280 B46049
                JBS     off(0012fh).2, to_set_pswl4_flag_b_sub_store_ram170 ; 4739 1 100 280 EA2F03
                J       o2_trim_dp300_read_rom_load_ram5247             ; 473C 1 100 280 031548
to_set_pswl4_flag_b_sub_store_ram170:     ST      A, off(00170h)         ; 473F 1 100 280 D470
                CAL     to_set_pswl4_flag_b_sub_call_4880             ; 4741 1 100 280 32706D
                JBS     off(00117h).0, to_set_pswl4_flag_b_sub_sll_x1 ; 4744 1 100 280 E81742
                JBS     off(0012fh).3, to_set_pswl4_flag_b_sub_sll_x1 ; 4747 1 100 280 EB2F3F
                LB      A, off(001f0h)         ; 474A 0 100 280 F4F0
                JNE     to_set_pswl4_flag_b_sub_sll_x1             ; 474C 0 100 280 CE3B
                MOVB    off(001f0h), #014h     ; 474E 0 100 280 C4F09814
                L       A, #0045ah             ; 4752 1 100 280 675A04
                JBS     off(00130h).4, o2trim_add_clamp ; 4755 1 100 280 EC3027
                MOVB    r0, #080h              ; 4758 1 100 280 9880
                MOV     er2, #006f7h           ; 475A 1 100 280 4698F706
                LB      A, #03fh               ; 475E 0 100 280 773F
                JBR     off(00120h).0, to_set_pswl4_flag_b_sub_goto_6d90 ; 4760 0 100 280 D82008
                MOVB    r0, #07dh              ; 4763 0 100 280 987D
                MOV     er2, #00767h           ; 4765 0 100 280 46986707
                LB      A, #046h               ; 4769 0 100 280 7746
to_set_pswl4_flag_b_sub_goto_6d90:     J       to_set_pswl4_flag_b_sub_if_ram11f_bit3_clr             ; 476B 0 100 280 03906D
                DB  000h ; 476E
to_set_pswl4_flag_b_sub_load_er2:     L       A, er2                 ; 476F 1 100 280 36
                J       to_set_pswl4_flag_b_sub_cmp_r0             ; 4770 1 100 280 03B06D
                DW  00acfh           ; 4773
to_set_pswl4_flag_b_sub_load_ram166:     L       A, off(00166h)         ; 4775 1 100 280 E466
                CMPB    off(00178h), #077h     ; 4777 1 100 280 C478C077
                JGE     o2trim_add_clamp             ; 477B 1 100 280 CD02
                L       A, off(00164h)         ; 477D 1 100 280 E464
o2trim_add_clamp:     ADD     er1, A                 ; 477F 1 100 280 4581
                JGE     o2trim_add_clamp_call_48c3             ; 4781 1 100 280 CD1E
                MOV     er1, #0ffffh           ; 4783 1 100 280 4598FFFF
                SJ      o2trim_add_clamp_call_48c3             ; 4787 1 100 280 CB18
to_set_pswl4_flag_b_sub_sll_x1:     SLL     X1                     ; 4789 1 100 280 90D7
                L       A, #05249h             ; 478B 1 100 280 674952
                JBR     off(00120h).0, to_set_pswl4_flag_b_sub_add_x1 ; 478E 1 100 280 D82003
                L       A, #05253h             ; 4791 1 100 280 675352
to_set_pswl4_flag_b_sub_add_x1:     ADD     X1, A                  ; 4794 1 100 280 9081
                LC      A, [X1]                ; 4796 1 100 280 90A8
                JBR     off(0012fh).3, o2trim_add_clamp ; 4798 1 100 280 DB2FE4
                SUB     er1, A                 ; 479B 1 100 280 45A1
                JGE     o2trim_add_clamp_call_48c3             ; 479D 1 100 280 CD02
                CLR     er1                    ; 479F 1 100 280 4515
o2trim_add_clamp_call_48c3:     CAL     o2trim_add_clamp_sub_load_imm_2             ; 47A1 1 100 280 32C348
                JBS     off(0011eh).1, o2trim_add_clamp_goto_487f ; 47A4 1 100 280 E91E3C
                JBS     off(0011bh).7, o2trim_add_clamp_goto_487f ; 47A7 1 100 280 EF1B39
                CMPB    0d8h, #01ah            ; 47AA 1 100 280 C5D8C01A
                JLT     o2trim_add_clamp_goto_487f             ; 47AE 1 100 280 CA33
                L       A, #00040h             ; 47B0 1 100 280 674000
                MOV     X1, #00306h            ; 47B3 1 100 280 600603
                JBR     off(00117h).0, o2trim_add_clamp_cmp_ram0d9 ; 47B6 1 100 280 D81706
                L       A, #00a00h             ; 47B9 1 100 280 67000A
                MOV     X1, #00302h            ; 47BC 1 100 280 600203
o2trim_add_clamp_cmp_ram0d9:     CMPB    0d9h, #02eh            ; 47BF 1 100 280 C5D9C02E
                JLT     o2trim_add_clamp_store_er0             ; 47C3 1 100 280 CA03
                L       A, #00001h             ; 47C5 1 100 280 670100
o2trim_add_clamp_store_er0:     ST      A, er0                 ; 47C8 1 100 280 88
                MOV     er2, 00000h[X1]        ; 47C9 1 100 280 B000004A
                MOV     er3, 00002h[X1]        ; 47CD 1 100 280 B002004B
                L       A, er1                 ; 47D1 1 100 280 35
                MOV     DP, A                  ; 47D2 1 100 280 52
                CAL     o2trim_add_clamp_sub_sub_acc             ; 47D3 1 100 280 32FA44
                CAL     o2trim_add_clamp_sub_load_imm             ; 47D6 1 100 280 32B548
                L       A, er2                 ; 47D9 1 100 280 36
                ST      A, 00000h[X1]          ; 47DA 1 100 280 D00000
                L       A, er3                 ; 47DD 1 100 280 37
                ST      A, 00002h[X1]          ; 47DE 1 100 280 D00200
                MOV     er1, DP                ; 47E1 1 100 280 9249
o2trim_add_clamp_goto_487f:     J       o2trim_add_clamp_return             ; 47E3 1 100 280 037F48
to_set_pswl4_flag_b_sub_store_ram170_2:     ST      A, off(00170h)         ; 47E6 1 100 280 D470
                JBR     off(00117h).1, o2_trim_dp304_calc ; 47E8 1 100 280 D91711
                MOV     DP, #0030ch            ; 47EB 1 100 280 620C03
                MOV     er1, [DP]              ; 47EE 1 100 280 B249
                SJ      o2_trim_dp300_read_rom_load_ram5247             ; 47F0 1 100 280 CB23
o2_trim_dp300_read:     ST      A, off(00170h)         ; 47F2 1 100 280 D470
                MOV     DP, #00304h            ; 47F4 1 100 280 620403
                MOV     er1, [DP]              ; 47F7 1 100 280 B249
                JBS     off(00117h).0, o2_trim_dp300_read_rom_load_ram5247 ; 47F9 1 100 280 E81719
o2_trim_dp304_calc:     MOV     DP, #00308h            ; 47FC 1 100 280 620803
                MOV     er0, [DP]              ; 47FF 1 100 280 B248
                L       A, #08000h             ; 4801 1 100 280 670080
                JBS     off(00120h).0, o2_trim_dp304_calc_mul_acc ; 4804 1 100 280 E82003
                L       A, #08000h             ; 4807 1 100 280 670080
o2_trim_dp304_calc_mul_acc:     MUL                            ; 480A 1 100 280 9035
                SLL     A                      ; 480C 1 100 280 53
                ROL     er1                    ; 480D 1 100 280 45B7
                JGE     o2_trim_dp300_read_rom_load_ram5247             ; 480F 1 100 280 CD04
                MOV     er1, #0ffffh           ; 4811 1 100 280 4598FFFF
o2_trim_dp300_read_rom_load_ram5247:     LC      A, 05247h              ; 4815 1 100 280 909C4752
                MOV     DP, #00170h            ; 4819 1 100 280 627001
                JBR     off(0012fh).3, o2_trim_dp300_read_decb_dp_ind ; 481C 1 100 280 DB2F02
                INC     DP                     ; 481F 1 100 280 72
                SWAP                           ; 4820 1 100 280 83
o2_trim_dp300_read_decb_dp_ind:     DECB    [DP]                   ; 4821 1 100 280 C217
                JNE     o2_trim_dp300_read_call_48c3             ; 4823 1 100 280 CE57
                LB      A, ACC                 ; 4825 0 100 280 F506
                STB     A, [DP]                ; 4827 0 100 280 D2
                CAL     o2_trim_dp300_read_sub_clear_x1             ; 4828 0 100 280 328048
                L       A, #0525dh             ; 482B 1 100 280 675D52
                JBR     off(00120h).0, o2_trim_dp300_read_add_x1 ; 482E 1 100 280 D82003
                L       A, #05262h             ; 4831 1 100 280 676252
o2_trim_dp300_read_add_x1:     ADD     X1, A                  ; 4834 1 100 280 9081
                CLR     A                      ; 4836 1 100 280 F9
                LCB     A, [X1]                ; 4837 1 100 280 90AA
                JBS     off(0012fh).3, o2_trim_dp300_read_sub_er1 ; 4839 1 100 280 EB2F04
                ADD     er1, A                 ; 483C 1 100 280 4581
                SJ      o2_trim_dp300_read_if_ram11e_bit1_set             ; 483E 1 100 280 CB02
o2_trim_dp300_read_sub_er1:     SUB     er1, A                 ; 4840 1 100 280 45A1
o2_trim_dp300_read_if_ram11e_bit1_set:     JBS     off(0011eh).1, o2_trim_dp300_read_call_48c3 ; 4842 1 100 280 E91E37
                CMPB    0d8h, #01ah            ; 4845 1 100 280 C5D8C01A
                JLT     o2_trim_dp300_read_call_48c3             ; 4849 1 100 280 CA31
                JBS     off(00117h).0, o2_trim_dp300_read_call_48c3 ; 484B 1 100 280 E8172E
                LB      A, off(001e1h)         ; 484E 0 100 280 F4E1
                JEQ     o2_trim_dp300_read_call_48c3             ; 4850 0 100 280 C92A
                MOV     X1, #0030ah            ; 4852 0 100 280 600A03
                L       A, #00020h             ; 4855 1 100 280 672000
                CMPB    0d9h, #02eh            ; 4858 1 100 280 C5D9C02E
                JLT     o2_trim_dp300_read_store_er0             ; 485C 1 100 280 CA03
                L       A, #00001h             ; 485E 1 100 280 670100
o2_trim_dp300_read_store_er0:     ST      A, er0                 ; 4861 1 100 280 88
                MOV     er2, 00000h[X1]        ; 4862 1 100 280 B000004A
                MOV     er3, 00002h[X1]        ; 4866 1 100 280 B002004B
                L       A, er1                 ; 486A 1 100 280 35
                MOV     DP, A                  ; 486B 1 100 280 52
                CAL     o2trim_add_clamp_sub_sub_acc             ; 486C 1 100 280 32FA44
                CAL     o2trim_add_clamp_sub_load_imm             ; 486F 1 100 280 32B548
                L       A, er2                 ; 4872 1 100 280 36
                ST      A, 00000h[X1]          ; 4873 1 100 280 D00000
                L       A, er3                 ; 4876 1 100 280 37
                ST      A, 00002h[X1]          ; 4877 1 100 280 D00200
                MOV     er1, DP                ; 487A 1 100 280 9249
o2_trim_dp300_read_call_48c3:     CAL     o2trim_add_clamp_sub_load_imm_2             ; 487C 1 100 280 32C348
o2trim_add_clamp_return:     RT                             ; 487F 1 100 280 01
o2_trim_dp300_read_sub_clear_x1:     CLR     X1                     ; 4880 0 100 280 9015
                JBR     off(00117h).0, o2_trim_dp300_read_sub_load_r5 ; 4882 0 100 280 D81712
                LB      A, off(00196h)         ; 4885 0 100 280 F496
                JEQ     o2_trim_dp300_read_sub_add_x1             ; 4887 0 100 280 C908
                JBR     off(0012fh).2, o2_trim_dp300_read_sub_load_ram179 ; 4889 0 100 280 DA2F18
                DECB    off(00196h)            ; 488C 0 100 280 C49617
                JNE     o2_trim_dp300_read_sub_load_ram179             ; 488F 0 100 280 CE13
o2_trim_dp300_read_sub_add_x1:     ADD     X1, #00004h            ; 4891 0 100 280 90800400
                SJ      o2_trim_dp300_read_sub_return             ; 4895 0 100 280 CB1D
o2_trim_dp300_read_sub_load_r5:     MOVB    r5, #00ah              ; 4897 0 100 280 9D0A
                LB      A, (00295h-00280h)[USP] ; 4899 0 100 280 F315
                CMPB    A, off(00179h)         ; 489B 0 100 280 C779
                JLT     o2_trim_dp300_read_sub_load_ram196             ; 489D 0 100 280 CA02
                CLRB    r5                     ; 489F 0 100 280 2515
o2_trim_dp300_read_sub_load_ram196:     MOVB    off(00196h), r5        ; 48A1 0 100 280 257C96
o2_trim_dp300_read_sub_load_ram179:     LB      A, off(00179h)         ; 48A4 0 100 280 F479
                JBS     off(00130h).4, o2_trim_dp300_read_sub_return ; 48A6 0 100 280 EC300B
                INC     X1                     ; 48A9 0 100 280 70
                CMPB    A, #0a0h               ; 48AA 0 100 280 C6A0
                JGE     o2_trim_dp300_read_sub_return             ; 48AC 0 100 280 CD06
                INC     X1                     ; 48AE 0 100 280 70
                CMPB    A, #040h               ; 48AF 0 100 280 C640
                JGE     o2_trim_dp300_read_sub_return             ; 48B1 0 100 280 CD01
                INC     X1                     ; 48B3 0 100 280 70
o2_trim_dp300_read_sub_return:     RT                             ; 48B4 0 100 280 01
o2trim_add_clamp_sub_load_imm:     L       A, #09999h             ; 48B5 1 100 280 679999
                CMP     A, er3                 ; 48B8 1 100 280 4B
                JLT     o2trim_add_clamp_sub_store_er3             ; 48B9 1 100 280 CA06
                L       A, #o2trim_add_clamp_tbl_2           ; 48BB 1 100 280 676666
                CMP     A, er3                 ; 48BE 1 100 280 4B
                JLE     o2trim_add_clamp_sub_return             ; 48BF 1 100 280 CF01
o2trim_add_clamp_sub_store_er3:     ST      A, er3                 ; 48C1 1 100 280 8B
o2trim_add_clamp_sub_return:     RT                             ; 48C2 1 100 280 01
o2trim_add_clamp_sub_load_imm_2:     L       A, #0bc44h             ; 48C3 1 100 280 6744BC
                CMP     A, er1                 ; 48C6 1 100 280 49
                JGE     o2trim_add_clamp_sub_load_imm_3             ; 48C7 1 100 280 CD01
                ST      A, er1                 ; 48C9 1 100 280 89
o2trim_add_clamp_sub_load_imm_3:     L       A, #o2trim_add_clamp_tbl           ; 48CA 1 100 280 67705D
                CMP     A, er1                 ; 48CD 1 100 280 49
                JLE     o2trim_add_clamp_sub_return_2             ; 48CE 1 100 280 CF01
                ST      A, er1                 ; 48D0 1 100 280 89
o2trim_add_clamp_sub_return_2:     RT                             ; 48D1 1 100 280 01
vtec_state_store_sub_clear_acch:     CLRB    ACCH                   ; 48D2 0 100 280 C50715
                ADD     DP, A                  ; 48D5 0 100 280 9281
                CAL     vtec_state_store_sub_rom_load_dp_ind             ; 48D7 0 100 280 320F49
                STB     A, r3                  ; 48DA 0 100 280 8B
                INC     DP                     ; 48DB 0 100 280 72
                CAL     vtec_state_store_sub_rom_load_dp_ind             ; 48DC 0 100 280 320F49
                ; warning: had to flip DD
                XCHG    A, er3                 ; 48DF 1 100 280 4710
                MOV     er0, X1                ; 48E1 1 100 280 9048
                SUB     A, er3                 ; 48E3 1 100 280 2B
                MB      PSWL.4, C              ; 48E4 1 100 280 A33C
                JGE     vtec_state_store_sub_mul_acc             ; 48E6 1 100 280 CD01
                VCAL    7                      ; 48E8 1 100 280 17
vtec_state_store_sub_mul_acc:     MUL                            ; 48E9 1 100 280 9035
                L       A, er1                 ; 48EB 1 100 280 35
                RB      PSWL.4                 ; 48EC 1 100 280 A30C
                JNE     vtec_state_store_sub_sub_er3             ; 48EE 1 100 280 CE03
                ADD     A, er3                 ; 48F0 1 100 280 0B
                SJ      map_result_postscale             ; 48F1 1 100 280 CB03
vtec_state_store_sub_sub_er3:     SUB     er3, A                 ; 48F3 1 100 280 47A1
                L       A, er3                 ; 48F5 1 100 280 37
map_result_postscale:     MOVB    r0, off(00184h)        ; 48F6 1 100 280 C48448
                MOVB    r1, #001h              ; 48F9 1 100 280 9901
                CMPB    r0, #080h              ; 48FB 1 100 280 20C080
                JGE     mul_scale_rotate             ; 48FE 1 100 280 CD01
                INCB    r1                     ; 4900 1 100 280 A9
mul_scale_rotate:     MUL                            ; 4901 1 100 280 9035
                SRL     er1                    ; 4903 1 100 280 45E7
                ROR     A                      ; 4905 1 100 280 43
                MOVB    r0, ACCH               ; 4906 1 100 280 C50748
                MOVB    r1, r2                 ; 4909 1 100 280 2249
                L       A, er0                 ; 490B 1 100 280 34
                ST      A, off(0013eh)         ; 490C 1 100 280 D43E
                RT                             ; 490E 1 100 280 01
vtec_state_store_sub_rom_load_dp_ind:     LCB     A, [DP]                ; 490F 0 100 280 92AA
                MOVB    r0, off(00135h)        ; 4911 0 100 280 C43548
                MULB                           ; 4914 0 100 280 A234
                L       A, ACC                 ; 4916 1 100 280 E506
                SRL     A                      ; 4918 1 100 280 63
                SRL     A                      ; 4919 1 100 280 63
                SRL     A                      ; 491A 1 100 280 63
                SRL     A                      ; 491B 1 100 280 63
                ST      A, er1                 ; 491C 1 100 280 89
                CLRB    A                      ; 491D 0 100 280 FA
                LCB     A, 00014h[DP]          ; 491E 0 100 280 92AB1400
                SUBB    A, #080h               ; 4922 0 100 280 A680
                EXTND                          ; 4924 1 100 280 F8
                SLL     A                      ; 4925 1 100 280 53
                ADD     er1, A                 ; 4926 1 100 280 4581
                RB      ACCH.7                 ; 4928 1 100 280 C5070F
                JEQ     vtec_state_store_sub_load_er1             ; 492B 1 100 280 C904
                JLT     vtec_state_store_sub_load_er1             ; 492D 1 100 280 CA02
                CLR     er1                    ; 492F 1 100 280 4515
vtec_state_store_sub_load_er1:     L       A, er1                 ; 4931 1 100 280 35
                RT                             ; 4932 1 100 280 01
accelenrich_clear_pulse_check_sub_load_x1:     MOV     X1, #0532eh            ; 4933 0 100 280 602E53
                LB      A, (002a4h-00280h)[USP] ; 4936 0 100 280 F324
                CMPB    A, #002h               ; 4938 0 100 280 C602
                JLE     accelenrich_clear_pulse_check_sub_cmp_ram179             ; 493A 0 100 280 CF04
                ADD     X1, #00006h            ; 493C 0 100 280 90800600
accelenrich_clear_pulse_check_sub_cmp_ram179:     CMPB    off(00179h), #08ah     ; 4940 0 100 280 C479C08A
                JLT     accelenrich_clear_pulse_check_sub_load_ram0e9             ; 4944 0 100 280 CA04
                ADD     X1, #0000ch            ; 4946 0 100 280 90800C00
accelenrich_clear_pulse_check_sub_load_ram0e9:     LB      A, 0e9h                ; 494A 0 100 280 F5E9
                VCAL    3                      ; 494C 0 100 280 13
                LB      A, ACC                 ; 494D 0 100 280 F506
                RT                             ; 494F 0 100 280 01
accelenrich_base_calc:     CLRB    A                      ; 4950 0 100 280 FA
                JBR     off(00117h).1, accelenrich_base_adjust ; 4951 0 100 280 D91706
                CMPB    0dfh, #005h            ; 4954 0 100 280 C5DFC005
                JLT     accelenrich_rpm_tier1_store_ram18e             ; 4958 0 100 280 CA0F
accelenrich_base_adjust:     ADDB    A, #006h               ; 495A 0 100 280 8606
                JBR     off(0011ah).3, accelenrich_rpm_tier1 ; 495C 0 100 280 DB1A02
                ADDB    A, #006h               ; 495F 0 100 280 8606
accelenrich_rpm_tier1:     CMPB    off(00179h), #066h     ; 4961 0 100 280 C479C066
                JLT     accelenrich_rpm_tier1_store_ram18e             ; 4965 0 100 280 CA02
                ADDB    A, #00ch               ; 4967 0 100 280 860C
accelenrich_rpm_tier1_store_ram18e:     STB     A, off(0018eh)         ; 4969 0 100 280 D48E
accelenrich_rpm_tier1_clear_acch:     CLRB    ACCH                   ; 496B 0 100 280 C50715
                MOV     X1, A                  ; 496E 0 100 280 50
                ADD     X1, #05310h            ; 496F 0 100 280 90801053
                LB      A, 0e9h                ; 4973 0 100 280 F5E9
                VCAL    3                      ; 4975 0 100 280 13
                RT                             ; 4976 0 100 280 01
vemapscalar_gate_sub_sub_acc:     SUB     A, #00043h             ; 4977 1 208 180 A64300
                JLT     vemapscalar_gate_sub_rom_load_tbl_x1             ; 497A 1 208 180 CA04
                CMPC    A, [X1]                ; 497C 1 208 180 90AC
                JGE     vemapscalar_gate_sub_return             ; 497E 1 208 180 CD02
vemapscalar_gate_sub_rom_load_tbl_x1:     LC      A, [X1]                ; 4980 1 208 180 90A8
vemapscalar_gate_sub_return:     RT                             ; 4982 1 208 180 01
add24_clamp_neg1:     ADD     A, #00001h             ; 4983 1 208 180 860100
                JGE     add24_clamp_neg1_store_er3             ; 4986 1 208 180 CD03
                L       A, #0ffffh             ; 4988 1 208 180 67FFFF
add24_clamp_neg1_store_er3:     ST      A, er3                 ; 498B 1 208 180 8B
                CLR     er1                    ; 498C 1 208 180 4515
                L       A, 0ach                ; 498E 1 208 180 E5AC
                SUB     A, #01140h             ; 4990 1 208 180 A64011
                JLT     add24_clamp_neg1_rom_load_tbl_x1             ; 4993 1 208 180 CA07
                ST      A, er0                 ; 4995 1 208 180 88
                LC      A, 00002h[X1]          ; 4996 1 208 180 90A90200
                MUL                            ; 499A 1 208 180 9035
add24_clamp_neg1_rom_load_tbl_x1:     LC      A, [X1]                ; 499C 1 208 180 90A8
                ADD     A, er1                 ; 499E 1 208 180 09
                JGE     add24_clamp_neg1_cmp_acc             ; 499F 1 208 180 CD03
                L       A, #0ffffh             ; 49A1 1 208 180 67FFFF
add24_clamp_neg1_cmp_acc:     CMP     A, er3                 ; 49A4 1 208 180 4B
                JLT     add24_clamp_neg1_return             ; 49A5 1 208 180 CA01
                L       A, er3                 ; 49A7 1 208 180 37
add24_clamp_neg1_return:     RT                             ; 49A8 1 208 180 01
learn_table2_check_sub_clear_pswh_bit0:     RB      PSWH.0                 ; 49A9 0 208 180 A208
                LB      A, [DP]                ; 49AB 0 208 180 F2
                JEQ     learn_table2_check_sub_set_pswh_bit0             ; 49AC 0 208 180 C902
                DECB    [DP]                   ; 49AE 0 208 180 C217
learn_table2_check_sub_set_pswh_bit0:     SB      PSWH.0                 ; 49B0 0 208 180 A218
                INC     DP                     ; 49B2 0 208 180 72
                DECB    r0                     ; 49B3 0 208 180 B8
                JNE     learn_table2_check_sub_clear_pswh_bit0             ; 49B4 0 208 180 CEF3
                RT                             ; 49B6 0 208 180 01
learn_table2_check_sub_load_imm:     LB      A, #03ch               ; 49B7 0 208 180 773C
                STB     A, WDT                 ; 49B9 0 208 180 D511
                SWAPB                          ; 49BB 0 208 180 83
                STB     A, WDT                 ; 49BC 0 208 180 D511
                MB      C, 09eh.0              ; 49BE 0 208 180 C59E28
                JLT     learn_table2_check_sub_return_2             ; 49C1 0 208 180 CA04
                XORB    P2A, #002h             ; 49C3 0 208 180 C525F002
learn_table2_check_sub_return_2:     RT                             ; 49C7 0 208 180 01
vss_clamp_common_sub_load_dp:     MOV     DP, #08000h            ; 49C8 0 208 180 620080
                RB      PSWH.0                 ; 49CB 0 208 180 A208
                LB      A, [DP]                ; 49CD 0 208 180 F2
                XORB    A, #0c2h               ; 49CE 0 208 180 F6C2
                STB     A, off(00224h)         ; 49D0 0 208 180 D424
                STB     A, (00124h-00180h)[USP] ; 49D2 0 208 180 D3A4
                SB      PSWH.0                 ; 49D4 0 208 180 A218
                MOV     DP, #01000h            ; 49D6 0 208 180 620010
                RB      PSWH.0                 ; 49D9 0 208 180 A208
                LB      A, [DP]                ; 49DB 0 208 180 F2
                XORB    A, #030h               ; 49DC 0 208 180 F630
                STB     A, off(00227h)         ; 49DE 0 208 180 D427
                STB     A, (00125h-00180h)[USP] ; 49E0 0 208 180 D3A5
                SB      PSWH.0                 ; 49E2 0 208 180 A218
                RB      PSWH.0                 ; 49E4 0 208 180 A208
                MB      C, P4.5                ; 49E6 0 208 180 C5212D
                MB      off(00214h).0, C       ; 49E9 0 208 180 C41438
                MB      C, P4.6                ; 49EC 0 208 180 C5212E
                XORB    PSWH, #080h            ; 49EF 0 208 180 A2F080
                MB      off(0022ch).2, C       ; 49F2 0 208 180 C42C3A
                SB      PSWH.0                 ; 49F5 0 208 180 A218
                RT                             ; 49F7 0 208 180 01
idle_init_start_sub_cmp_ram0d7:     CMPB    0d7h, #000h            ; 49F8 0 208 180 C5D7C000
                JEQ     idle_init_start_sub_store_ram0d4             ; 49FC 0 208 180 C906
                DECB    0d7h                   ; 49FE 0 208 180 C5D717
                JEQ     idle_init_start_sub_store_ram0d4             ; 4A01 0 208 180 C901
                RT                             ; 4A03 0 208 180 01
idle_init_start_sub_store_ram0d4:     STB     A, 0d4h                ; 4A04 0 208 180 D5D4
                CLRB    0d6h                   ; 4A06 0 208 180 C5D615
                J       fault_retry_check             ; 4A09 0 208 180 034C07
percyl_counter_gate_sub_cmp_ram0d7:     CMPB    0d7h, #000h            ; 4A0C 0 088 300 C5D7C000
                JEQ     percyl_counter_gate_sub_store_ram0d4             ; 4A10 0 088 300 C906
                DECB    0d7h                   ; 4A12 0 088 300 C5D717
                JEQ     percyl_counter_gate_sub_store_ram0d4             ; 4A15 0 088 300 C901
                RT                             ; 4A17 0 088 300 01
percyl_counter_gate_sub_store_ram0d4:     STB     A, 0d4h                ; 4A18 0 088 300 D5D4
                J       fault_retry_check_nop_acc             ; 4A1A 0 088 300 035807
idle_helper2:     MUL                            ; 4A1D 1 208 180 9035
                L       A, er1                 ; 4A1F 1 208 180 35
                SJ      mul_then_clamp_x1x2_2_load_carry_pswl_bit4             ; 4A20 1 208 180 CB0A
mul_then_clamp_x1x2_2:     MUL                            ; 4A22 1 208 180 9035
                CMPB    r2, #000h              ; 4A24 1 208 180 22C000
                JEQ     mul_then_clamp_x1x2_2_load_carry_pswl_bit4             ; 4A27 1 208 180 C903
                L       A, #0ffffh             ; 4A29 1 208 180 67FFFF
mul_then_clamp_x1x2_2_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 4A2C 1 208 180 A32C
                JGE     mul_then_clamp_x1x2_2_xchg_acc             ; 4A2E 1 208 180 CD0E
                ADD     A, er3                 ; 4A30 1 208 180 0B
                JLT     mul_then_clamp_x1x2_2_load_x2             ; 4A31 1 208 180 CA08
mul_then_clamp_x1x2_2_cmp_acc:     CMP     A, X1                  ; 4A33 1 208 180 90C2
                JLT     idle_pi_clamp_setcarry             ; 4A35 1 208 180 CA0C
                CMP     X2, A                  ; 4A37 1 208 180 91C1
                JGE     idle_pi_clamp_setcarry_store_er3             ; 4A39 1 208 180 CD09
mul_then_clamp_x1x2_2_load_x2:     L       A, X2                  ; 4A3B 1 208 180 41
                SJ      idle_pi_clamp_setcarry_store_er3             ; 4A3C 1 208 180 CB06
mul_then_clamp_x1x2_2_xchg_acc:     XCHG    A, er3                 ; 4A3E 1 208 180 4710
                SUB     A, er3                 ; 4A40 1 208 180 2B
                JGE     mul_then_clamp_x1x2_2_cmp_acc             ; 4A41 1 208 180 CDF0
idle_pi_clamp_setcarry:     L       A, X1                  ; 4A43 1 208 180 40
idle_pi_clamp_setcarry_store_er3:     ST      A, er3                 ; 4A44 1 208 180 8B
                RT                             ; 4A45 1 208 180 01
ect_fault_range_check_sub_load_dp:     MOV     DP, #003a5h            ; 4A46 0 208 180 62A503
                ADDB    A, #005h               ; 4A49 0 208 180 8605
                JGE     ect_fault_range_check_sub_if_ram216_bit0_set             ; 4A4B 0 208 180 CD02
                LB      A, #0ffh               ; 4A4D 0 208 180 77FF
ect_fault_range_check_sub_if_ram216_bit0_set:     JBS     off(00216h).0, ect_fault_range_check_sub_load_r0 ; 4A4F 0 208 180 E81607
                JBR     off(00233h).3, ect_fault_range_check_sub_load_r0 ; 4A52 0 208 180 DB3304
                CMPB    A, [DP]                ; 4A55 0 208 180 C2C2
                JGE     ect_fault_range_check_sub_return             ; 4A57 0 208 180 CD07
ect_fault_range_check_sub_load_r0:     MOVB    r0, #058h              ; 4A59 0 208 180 9858
                CMPB    A, r0                  ; 4A5B 0 208 180 48
                JGE     ect_fault_range_check_sub_store_dp_ind             ; 4A5C 0 208 180 CD01
                LB      A, r0                  ; 4A5E 0 208 180 78
ect_fault_range_check_sub_store_dp_ind:     STB     A, [DP]                ; 4A5F 0 208 180 D2
ect_fault_range_check_sub_return:     RT                             ; 4A60 0 208 180 01
idle_temp_hyst3_sub_load_dp:     MOV     DP, #0030eh            ; 4A61 1 208 180 620E03
                CLR     A                      ; 4A64 1 208 180 F9
                LC      A, 05558h              ; 4A65 1 208 180 909C5855
                JBS     off(00220h).0, idle_temp_hyst3_sub_store_dp_ind ; 4A69 1 208 180 E82004
                LC      A, 0555ah              ; 4A6C 1 208 180 909C5A55
idle_temp_hyst3_sub_store_dp_ind:     ST      A, [DP]                ; 4A70 1 208 180 D2
                RT                             ; 4A71 1 208 180 01
vss_clamp_common_sub_load_dp_2:     MOV     DP, #08000h            ; 4A72 0 208 180 620080
vss_clamp_common_sub_load_dp_ind:     LB      A, [DP]                ; 4A75 0 208 180 F2
                ROLB    A                      ; 4A76 0 208 180 33
                ROLB    off(002bbh)            ; 4A77 0 208 180 C4BBB7
                ROLB    A                      ; 4A7A 0 208 180 33
                ROLB    off(002bbh)            ; 4A7B 0 208 180 C4BBB7
                RT                             ; 4A7E 0 208 180 01
                DB  090h,09Dh,0F2h,07Fh,001h ; 4A7F
div_scale_mul_final_sub_subb_acc:     SUBB    A, #074h               ; 4A84 0 208 180 A674
div_scale_mul_final_sub_if_le_goto_4a8d:     JLE     div_scale_mul_final_sub_addb_acc             ; 4A86 0 208 180 CF05
                SUBB    A, #004h               ; 4A88 0 208 180 A604
                JGE     div_scale_mul_final_sub_addb_acc_2             ; 4A8A 0 208 180 CD05
                CLRB    A                      ; 4A8C 0 208 180 FA
div_scale_mul_final_sub_addb_acc:     ADDB    A, #080h               ; 4A8D 0 208 180 8680
                SJ      div_scale_mul_final_sub_return             ; 4A8F 0 208 180 CB06
div_scale_mul_final_sub_addb_acc_2:     ADDB    A, #080h               ; 4A91 0 208 180 8680
                JGE     div_scale_mul_final_sub_return             ; 4A93 0 208 180 CD02
                LB      A, #0ffh               ; 4A95 0 208 180 77FF
div_scale_mul_final_sub_return:     RT                             ; 4A97 0 208 180 01
vss_clamp_common_sub_clear_pswh_bit0:     RB      PSWH.0                 ; 4A98 1 088 300 A208
                RB      ADSCAN.5                ; 4A9A 1 088 300 C5660D
                MB      C, PSWH.6              ; 4A9D 1 088 300 A22E
                RB      09fh.4                 ; 4A9F 1 088 300 C59F0C
                JGE     vss_clamp_common_sub_set_pswh_bit0             ; 4AA2 1 088 300 CD09
                JNE     vss_clamp_common_sub_set_pswh_bit0             ; 4AA4 1 088 300 CE07
                CAL     vss_clamp_common_sub_set_pswh_bit0_2             ; 4AA6 1 088 300 32C04D
                NOP                            ; 4AA9 1 088 300 00
                NOP                            ; 4AAA 1 088 300 00
                SJ      vss_clamp_common_sub_return             ; 4AAB 1 088 300 CB1C
vss_clamp_common_sub_set_pswh_bit0:     SB      PSWH.0                 ; 4AAD 1 088 300 A218
                LB      A, 0bbh                ; 4AAF 0 088 300 F5BB
                EXTND                          ; 4AB1 1 088 300 F8
                MOV     X1, A                  ; 4AB2 1 088 300 50
                LB      A, ADCR0H              ; 4AB3 0 088 300 F569
                STB     A, 003d0h[X1]          ; 4AB5 0 088 300 D0D003
                LB      A, ADCR1H              ; 4AB8 0 088 300 F56B
                STB     A, 003d8h[X1]          ; 4ABA 0 088 300 D0D803
                LB      A, 0bbh                ; 4ABD 0 088 300 F5BB
                ADDB    A, #001h               ; 4ABF 0 088 300 8601
                ANDB    A, #007h               ; 4AC1 0 088 300 D607
                STB     A, 0bbh                ; 4AC3 0 088 300 D5BB
                STB     A, r0                  ; 4AC5 0 088 300 88
                CAL     scale_div32_loop_sub_clear_pswh_bit0             ; 4AC6 0 088 300 321345
vss_clamp_common_sub_return:     RT                             ; 4AC9 0 088 300 01
calchecksum_loop_sub_load_dp:     MOV     DP, #0e000h            ; 4ACA 0 208 180 6200E0
                MOVB    [DP], #090h            ; 4ACD 0 208 180 C29890
                MOV     DP, #0a000h            ; 4AD0 0 208 180 6200A0
                LB      A, off(00225h)         ; 4AD3 0 208 180 F425
                XORB    A, #0ffh               ; 4AD5 0 208 180 F6FF
                STB     A, [DP]                ; 4AD7 0 208 180 D2
                MOV     DP, #0c000h            ; 4AD8 0 208 180 6200C0
                RB      PSWH.0                 ; 4ADB 0 208 180 A208
                LB      A, off(00226h)         ; 4ADD 0 208 180 F426
                XORB    A, #024h               ; 4ADF 0 208 180 F624
                STB     A, [DP]                ; 4AE1 0 208 180 D2
                SB      PSWH.0                 ; 4AE2 0 208 180 A218
                SB      off(00232h).7          ; 4AE4 0 208 180 C4321F
                RT                             ; 4AE7 0 208 180 01
cfgvariant_checksum_calc:     MOV     DP, #00330h            ; 4AE8 1 208 ??? 623003
                CLR     er0                    ; 4AEB 1 208 ??? 4415
cfgvariant_checksum_loop:     LB      A, r0                  ; 4AED 0 208 ??? 78
                ADDB    A, [DP]                ; 4AEE 0 208 ??? C282
                STB     A, r0                  ; 4AF0 0 208 ??? 88
                LB      A, r1                  ; 4AF1 0 208 ??? 79
                XORB    A, [DP]                ; 4AF2 0 208 ??? C2F2
                STB     A, r1                  ; 4AF4 0 208 ??? 89
                INC     DP                     ; 4AF5 0 208 ??? 72
                CMP     DP, #00334h            ; 4AF6 0 208 ??? 92C03403
                JNE     cfgvariant_checksum_loop             ; 4AFA 0 208 ??? CEF1
                L       A, er0                 ; 4AFC 1 208 ??? 34
                ST      A, [DP]                ; 4AFD 1 208 ??? D2
cfgvariant_checksum_loop_load_dp:     MOV     DP, #00338h            ; 4AFE 1 208 ??? 623803
                CLR     er0                    ; 4B01 1 208 ??? 4415
cfgvariant_checksum_loop_load_r0:     LB      A, r0                  ; 4B03 0 208 ??? 78
                ADDB    A, [DP]                ; 4B04 0 208 ??? C282
                STB     A, r0                  ; 4B06 0 208 ??? 88
                LB      A, r1                  ; 4B07 0 208 ??? 79
                XORB    A, [DP]                ; 4B08 0 208 ??? C2F2
                STB     A, r1                  ; 4B0A 0 208 ??? 89
                INC     DP                     ; 4B0B 0 208 ??? 72
                CMP     DP, #0035dh            ; 4B0C 0 208 ??? 92C05D03
                JLE     cfgvariant_checksum_loop_load_r0             ; 4B10 0 208 ??? CFF1
                MOV     DP, #00362h            ; 4B12 0 208 ??? 626203
                L       A, er0                 ; 4B15 1 208 ??? 34
                RT                             ; 4B16 1 208 ??? 01
dtc_active_confirm_sub_load_dp:     MOV     DP, #00338h            ; 4B17 1 208 ??? 623803
                LB      A, [DP]                ; 4B1A 0 208 ??? F2
                JNE     dtc_active_confirm_sub_return             ; 4B1B 0 208 ??? CE62
                LB      A, r1                  ; 4B1D 0 208 ??? 79
                JEQ     dtc_active_confirm_sub_return             ; 4B1E 0 208 ??? C95F
                MB      C, off(0021bh).0       ; 4B20 0 208 ??? C41B28
                MB      ACC.7, C               ; 4B23 0 208 ??? C5063F
                STB     A, [DP]                ; 4B26 0 208 ??? D2
                INC     DP                     ; 4B27 0 208 ??? 72
                LB      A, 0dfh                ; 4B28 0 208 ??? F5DF
                STB     A, [DP]                ; 4B2A 0 208 ??? D2
                INC     DP                     ; 4B2B 0 208 ??? 72
                L       A, 0aeh                ; 4B2C 1 208 ??? E5AE
                SWAP                           ; 4B2E 1 208 ??? 83
                ST      A, [DP]                ; 4B2F 1 208 ??? D2
                INC     DP                     ; 4B30 1 208 ??? 72
                INC     DP                     ; 4B31 1 208 ??? 72
                MOV     X1, #003dah            ; 4B32 1 208 ??? 60DA03
                LB      A, 00000h[X1]          ; 4B35 0 208 ??? F00000
                STB     A, [DP]                ; 4B38 0 208 ??? D2
                INC     DP                     ; 4B39 0 208 ??? 72
                MOV     X1, #003d2h            ; 4B3A 0 208 ??? 60D203
                LB      A, 00000h[X1]          ; 4B3D 0 208 ??? F00000
                STB     A, [DP]                ; 4B40 0 208 ??? D2
                INC     DP                     ; 4B41 0 208 ??? 72
                MOV     X1, #003e4h            ; 4B42 0 208 ??? 60E403
                LB      A, 00000h[X1]          ; 4B45 0 208 ??? F00000
                STB     A, [DP]                ; 4B48 0 208 ??? D2
                INC     DP                     ; 4B49 0 208 ??? 72
                MOV     X1, #003d3h            ; 4B4A 0 208 ??? 60D303
                LB      A, 00000h[X1]          ; 4B4D 0 208 ??? F00000
                STB     A, [DP]                ; 4B50 0 208 ??? D2
                INC     DP                     ; 4B51 0 208 ??? 72
                MOV     X1, #003e5h            ; 4B52 0 208 ??? 60E503
                LB      A, 00000h[X1]          ; 4B55 0 208 ??? F00000
                STB     A, [DP]                ; 4B58 0 208 ??? D2
                INC     DP                     ; 4B59 0 208 ??? 72
                LB      A, 0dbh                ; 4B5A 0 208 ??? F5DB
                STB     A, [DP]                ; 4B5C 0 208 ??? D2
                INC     DP                     ; 4B5D 0 208 ??? 72
                MOV     X1, #00382h            ; 4B5E 0 208 ??? 608203
                L       A, 00000h[X1]          ; 4B61 1 208 ??? E00000
                SWAP                           ; 4B64 1 208 ??? 83
                ST      A, [DP]                ; 4B65 1 208 ??? D2
                INC     DP                     ; 4B66 1 208 ??? 72
                INC     DP                     ; 4B67 1 208 ??? 72
                LB      A, 0dah                ; 4B68 0 208 ??? F5DA
                STB     A, [DP]                ; 4B6A 0 208 ??? D2
                INC     DP                     ; 4B6B 0 208 ??? 72
                LB      A, (0ffe0h-0ffffh)[USP] ; 4B6C 0 208 ??? F3E1
                STB     A, [DP]                ; 4B6E 0 208 ??? D2
                INC     DP                     ; 4B6F 0 208 ??? 72
                MOV     X1, #003e2h            ; 4B70 0 208 ??? 60E203
                LB      A, 00000h[X1]          ; 4B73 0 208 ??? F00000
                STB     A, [DP]                ; 4B76 0 208 ??? D2
                INC     DP                     ; 4B77 0 208 ??? 72
                MOV     X1, #003e1h            ; 4B78 0 208 ??? 60E103
                LB      A, 00000h[X1]          ; 4B7B 0 208 ??? F00000
                STB     A, [DP]                ; 4B7E 0 208 ??? D2
dtc_active_confirm_sub_return:     RT                             ; 4B7F 0 208 ??? 01
vcal_4_sub_pushs_lrb:     PUSHS   LRB                    ; 4B80 0 208 180 54
                MOV     LRB, #00076h           ; 4B81 0 3B0 180 577600
                RB      off(003bch).2          ; 4B84 0 3B0 180 C4BC0A
                JEQ     vcal_4_sub_pops_lrb             ; 4B87 0 3B0 180 C969
                LB      A, r1                  ; 4B89 0 3B0 180 79
                CMPB    A, #020h               ; 4B8A 0 3B0 180 C620
                JNE     vcal_4_sub_cmp_acc             ; 4B8C 0 3B0 180 CE11
                MOV     off(003c0h), 0aeh      ; 4B8E 0 3B0 180 B5AE7CC0
                CAL     vcal_4_sub_clear_acc_2             ; 4B92 0 3B0 180 32804E
                NOP                            ; 4B95 0 3B0 180 00
                MOVB    off(003bah), r3        ; 4B96 0 3B0 180 237CBA
                LB      A, r4                  ; 4B99 0 3B0 180 7C
                ADDB    A, #003h               ; 4B9A 0 3B0 180 8603
                STB     A, r2                  ; 4B9C 0 3B0 180 8A
                SJ      vcal_4_sub_set_ram3bc_bit0             ; 4B9D 0 3B0 180 CB48
vcal_4_sub_cmp_acc:     CMPB    A, #030h               ; 4B9F 0 3B0 180 C630
                JLT     vcal_4_sub_cmp_acc_2             ; 4BA1 0 3B0 180 CA32
                CMPB    A, #036h               ; 4BA3 0 3B0 180 C636
                JGT     vcal_4_sub_cmp_acc_2             ; 4BA5 0 3B0 180 C82E
                MOVB    r2, #003h              ; 4BA7 0 3B0 180 9A03
                CMPB    A, #030h               ; 4BA9 0 3B0 180 C630
                JEQ     vcal_4_sub_clear_ram0f8             ; 4BAB 0 3B0 180 C920
                MOV     DP, #00124h            ; 4BAD 0 3B0 180 622401
                MB      C, [DP].2              ; 4BB0 0 3B0 180 C22A
                JGE     vcal_4_sub_clear_ram0f8             ; 4BB2 0 3B0 180 CD19
                LB      A, off(003b8h)         ; 4BB4 0 3B0 180 F4B8
                JEQ     vcal_4_sub_cmp_r1             ; 4BB6 0 3B0 180 C907
                CMPB    r1, off(003b9h)        ; 4BB8 0 3B0 180 21C3B9
                JEQ     vcal_4_sub_load_r1             ; 4BBB 0 3B0 180 C907
                SJ      vcal_4_sub_load_ram3b8             ; 4BBD 0 3B0 180 CB08
vcal_4_sub_cmp_r1:     CMPB    r1, off(003b9h)        ; 4BBF 0 3B0 180 21C3B9
                JNE     vcal_4_sub_clear_ram0f8             ; 4BC2 0 3B0 180 CE09
vcal_4_sub_load_r1:     LB      A, r1                  ; 4BC4 0 3B0 180 79
                STB     A, 0f8h                ; 4BC5 0 3B0 180 D5F8
vcal_4_sub_load_ram3b8:     MOVB    off(003b8h), #028h     ; 4BC7 0 3B0 180 C4B89828
                SJ      vcal_4_sub_set_ram3bc_bit0             ; 4BCB 0 3B0 180 CB1A
vcal_4_sub_clear_ram0f8:     CLRB    0f8h                   ; 4BCD 0 3B0 180 C5F815
                CLRB    off(003b8h)            ; 4BD0 0 3B0 180 C4B815
                SJ      vcal_4_sub_set_ram3bc_bit0             ; 4BD3 0 3B0 180 CB12
vcal_4_sub_cmp_acc_2:     CMPB    A, #021h               ; 4BD5 0 3B0 180 C621
                JNE     vcal_4_sub_pops_lrb             ; 4BD7 0 3B0 180 CE19
                MOVB    r2, #003h              ; 4BD9 0 3B0 180 9A03
                JBR     off(003b3h).0, vcal_4_sub_if_ram3b3_bit1_clr ; 4BDB 0 3B0 180 D8B303
                CAL     vcal_4_sub_load_usp_2             ; 4BDE 0 3B0 180 329C4C
vcal_4_sub_if_ram3b3_bit1_clr:     JBR     off(003b3h).1, vcal_4_sub_set_ram3bc_bit0 ; 4BE1 0 3B0 180 D9B303
                CAL     vcal_4_sub_load_usp             ; 4BE4 0 3B0 180 325D4C
vcal_4_sub_set_ram3bc_bit0:     SB      off(003bch).0          ; 4BE7 0 3B0 180 C4BC18
                MOVB    r5, #002h              ; 4BEA 0 3B0 180 9D02
                LB      A, r1                  ; 4BEC 0 3B0 180 79
                ANDB    A, #01fh               ; 4BED 0 3B0 180 D61F
                STB     A, r6                  ; 4BEF 0 3B0 180 8E
                STB     A, STBUF                ; 4BF0 0 3B0 180 D57C
vcal_4_sub_pops_lrb:     POPS    LRB                    ; 4BF2 0 3B0 180 64
                RT                             ; 4BF3 0 3B0 180 01
int_serial_sub_cmp_acc:     CMPB    A, #07fh               ; 4BF4 0 3B0 ??? C67F
                JGT     int_serial_sub_load_imm             ; 4BF6 0 3B0 ??? C82A
                CLRB    ACCH                   ; 4BF8 0 3B0 ??? C50715
                MOV     X1, A                  ; 4BFB 0 3B0 ??? 50
                SLLB    A                      ; 4BFC 0 3B0 ??? 53
                LC      A, int_serial_tbl[ACC]       ; 4BFD 0 3B0 ??? B506A9CF6A
                MOV     DP, A                  ; 4C02 0 3B0 ??? 52
                LCB     A, int_serial_tbl_2[X1]        ; 4C03 0 3B0 ??? 90ABCF6B
                CMPB    A, #000h               ; 4C07 0 3B0 ??? C600
                JNE     int_serial_sub_cmp_acc_2             ; 4C09 0 3B0 ??? CE02
                J       [DP]                   ; 4C0B 0 3B0 ??? 9222
int_serial_sub_cmp_acc_2:     CMPB    A, #001h               ; 4C0D 0 3B0 ??? C601
                JNE     int_serial_sub_cmp_acc_3             ; 4C0F 0 3B0 ??? CE02
                LB      A, [DP]                ; 4C11 0 3B0 ??? F2
                RT                             ; 4C12 0 3B0 ??? 01
int_serial_sub_cmp_acc_3:     CMPB    A, #002h               ; 4C13 0 3B0 ??? C602
                JNE     int_serial_sub_cmp_acc_4             ; 4C15 0 3B0 ??? CE04
                CLRB    A                      ; 4C17 0 3B0 ??? FA
                LCB     A, [DP]                ; 4C18 0 3B0 ??? 92AA
                RT                             ; 4C1A 0 3B0 ??? 01
int_serial_sub_cmp_acc_4:     CMPB    A, #0ffh               ; 4C1B 0 3B0 ??? C6FF
                JNE     int_serial_sub_load_imm             ; 4C1D 0 3B0 ??? CE03
                LB      A, #000h               ; 4C1F 0 3B0 ??? 7700
                RT                             ; 4C21 0 3B0 ??? 01
int_serial_sub_load_imm:     LB      A, #0ffh               ; 4C22 0 3B0 ??? 77FF
                RT                             ; 4C24 0 3B0 ??? 01
                DB  062h,020h,002h,0F2h,0D6h,051h,001h,062h ; 4C25
                DB  03Ch,002h,0E2h,0C9h,006h,0B5h,006h,017h ; 4C2D
                DB  032h,029h,04Dh,0F5h,006h,001h,0E4h,00Eh ; 4C35
                DB  032h,029h,04Dh,0F5h,006h,001h,062h,0B4h ; 4C3D
                DB  002h,0F2h,032h,08Eh,044h,001h,0F9h,0F4h ; 4C45
                DB  0A9h,053h,053h,0B5h,006h,0ABh,0FFh,06Ch ; 4C4D
                DB  001h,062h,01Fh,002h,0F2h,0D6h,02Fh,001h ; 4C55
vcal_4_sub_load_usp:     MOV     USP, #00280h           ; 4C5D 0 3B0 280 A1988002
                CLRB    off(00300h)            ; 4C61 0 3B0 280 C40015
                L       A, #08000h             ; 4C64 1 3B0 280 670080
                ST      A, off(00304h)         ; 4C67 1 3B0 280 D404
                ST      A, off(00308h)         ; 4C69 1 3B0 280 D408
                ST      A, off(0030ch)         ; 4C6B 1 3B0 280 D40C
                MB      C, (00220h-00280h)[USP].0 ; 4C6D 1 3B0 280 C3A028
                LC      A, 05558h              ; 4C70 1 3B0 280 909C5855
                JLT     vcal_4_sub_store_ram30e             ; 4C74 1 3B0 280 CA04
                LC      A, 0555ah              ; 4C76 1 3B0 280 909C5A55
vcal_4_sub_store_ram30e:     ST      A, off(0030eh)         ; 4C7A 1 3B0 280 D40E
                MOVB    off(0032fh), #078h     ; 4C7C 1 3B0 280 C42F9878
                CLRB    off(0032eh)            ; 4C80 1 3B0 280 C42E15
                MOVB    off(00300h), #05ah     ; 4C83 1 3B0 280 C400985A
                MOVB    (002f5h-00280h)[USP], #006h ; 4C87 1 3B0 280 C3759806
                MOVB    (0028bh-00280h)[USP], #0fah ; 4C8B 1 3B0 280 C30B98FA
                MOVB    (00293h-00280h)[USP], #03dh ; 4C8F 1 3B0 280 C313983D
                LB      A, #01eh               ; 4C93 0 3B0 280 771E
                STB     A, (002ebh-00280h)[USP] ; 4C95 0 3B0 280 D36B
                MOV     USP, #00180h           ; 4C97 0 3B0 180 A1988001
                RT                             ; 4C9B 0 3B0 180 01
vcal_4_sub_load_usp_2:     MOV     USP, #00280h           ; 4C9C 0 3B0 280 A1988002
                CLR     A                      ; 4CA0 1 3B0 280 F9
                MOV     DP, #00110h            ; 4CA1 1 3B0 280 621001
                ST      A, [DP]                ; 4CA4 1 3B0 280 D2
                INC     DP                     ; 4CA5 1 3B0 280 72
                INC     DP                     ; 4CA6 1 3B0 280 72
                ST      A, [DP]                ; 4CA7 1 3B0 280 D2
                ST      A, (00210h-00280h)[USP] ; 4CA8 1 3B0 280 D390
                ST      A, (00212h-00280h)[USP] ; 4CAA 1 3B0 280 D392
                ST      A, 098h                ; 4CAC 1 3B0 280 D598
                ST      A, 09ah                ; 4CAE 1 3B0 280 D59A
                ST      A, 09ch                ; 4CB0 1 3B0 280 D59C
                CLRB    0f1h                   ; 4CB2 1 3B0 280 C5F115
                CLRB    (002bfh-00280h)[USP]   ; 4CB5 1 3B0 280 C33F15
                ANDB    (00233h-00280h)[USP], #01fh ; 4CB8 1 3B0 280 C3B3D01F
                ANDB    (00215h-00280h)[USP], #0bfh ; 4CBC 1 3B0 280 C395D0BF
                ANDB    (00218h-00280h)[USP], #0bfh ; 4CC0 1 3B0 280 C398D0BF
                CLRB    (002c0h-00280h)[USP]   ; 4CC4 1 3B0 280 C34015
                MOVB    (002c6h-00280h)[USP], #010h ; 4CC7 1 3B0 280 C3469810
                RB      09eh.0                 ; 4CCB 1 3B0 280 C59E08
                JEQ     vcal_4_sub_load_ram0d6             ; 4CCE 1 3B0 280 C903
                RB      (00232h-00280h)[USP].7 ; 4CD0 1 3B0 280 C3B20F
vcal_4_sub_load_ram0d6:     MOVB    0d6h, #010h            ; 4CD3 1 3B0 280 C5D69810
                MOVB    0d7h, #010h            ; 4CD7 1 3B0 280 C5D79810
                ORB     off(00336h), #0c0h     ; 4CDB 1 3B0 280 C436E0C0
                CAL     vcal_4_sub_clear_acc             ; 4CDF 1 3B0 280 32F24C
                ANDB    off(00336h), #03fh     ; 4CE2 1 3B0 280 C436D03F
                CAL     clamp_result_store_sub_load_dp             ; 4CE6 1 3B0 280 32104D
                MOV     USP, #00180h           ; 4CE9 1 3B0 180 A1988001
                ANDB    (00127h-00180h)[USP], #01fh ; 4CED 1 3B0 180 C3A7D01F
                RT                             ; 4CF1 1 3B0 180 01
vcal_4_sub_clear_acc:     CLR     A                      ; 4CF2 1 208 180 F9
                MOV     DP, #00330h            ; 4CF3 1 208 180 623003
                ST      A, [DP]                ; 4CF6 1 208 180 D2
                INC     DP                     ; 4CF7 1 208 180 72
                INC     DP                     ; 4CF8 1 208 180 72
                ST      A, [DP]                ; 4CF9 1 208 180 D2
                INC     DP                     ; 4CFA 1 208 180 72
                INC     DP                     ; 4CFB 1 208 180 72
                ST      A, [DP]                ; 4CFC 1 208 180 D2
                MOV     X1, #0035ch            ; 4CFD 1 208 180 605C03
                MOV     DP, #00013h            ; 4D00 1 208 180 621300
vcal_4_sub_load_tbl_x1:     MOV     00000h[X1], A          ; 4D03 1 208 180 B000008A
                DEC     X1                     ; 4D07 1 208 180 80
                DEC     X1                     ; 4D08 1 208 180 80
                JRNZ    DP, vcal_4_sub_load_tbl_x1         ; 4D09 1 208 180 30F8
                MOV     DP, #00362h            ; 4D0B 1 208 180 626203
                ST      A, [DP]                ; 4D0E 1 208 180 D2
                RT                             ; 4D0F 1 208 180 01
clamp_result_store_sub_load_dp:     MOV     DP, #001a0h            ; 4D10 0 208 180 62A001
                MOV     X1, #clamp_result_store_tbl          ; 4D13 0 208 180 606F57
clamp_result_store_sub_rom_load_tbl_x1:     LCB     A, [X1]                ; 4D16 0 208 180 90AA
                STB     A, [DP]                ; 4D18 0 208 180 D2
                INC     X1                     ; 4D19 0 208 180 70
                INC     DP                     ; 4D1A 0 208 180 72
                CMP     DP, #001abh            ; 4D1B 0 208 180 92C0AB01
                JLT     clamp_result_store_sub_rom_load_tbl_x1             ; 4D1F 0 208 180 CAF5
                MOV     DP, #00172h            ; 4D21 0 208 180 627201
                L       A, #00bb3h             ; 4D24 1 208 180 67B30B
                ST      A, [DP]                ; 4D27 1 208 180 D2
                RT                             ; 4D28 1 208 180 01
                DB  063h,063h,063h,063h,063h,063h,001h ; 4D29
percyl_counter_gate_sub_load_dp:     MOV     DP, #003dbh            ; 4D30 0 088 300 62DB03
                LB      A, [DP]                ; 4D33 0 088 300 F2
                CMPB    A, #066h               ; 4D34 0 088 300 C666
                JLT     percyl_counter_gate_sub_load_imm             ; 4D36 0 088 300 CA08
                CMPB    A, #099h               ; 4D38 0 088 300 C699
                JLE     percyl_counter_gate_sub_return             ; 4D3A 0 088 300 CF09
                CMPB    A, #0ffh               ; 4D3C 0 088 300 C6FF
                JGT     percyl_counter_gate_sub_return             ; 4D3E 0 088 300 C805
percyl_counter_gate_sub_load_imm:     LB      A, #04ch               ; 4D40 0 088 300 774C
                CAL     percyl_counter_gate_sub_cmp_ram0d7             ; 4D42 0 088 300 320C4A
percyl_counter_gate_sub_return:     RT                             ; 4D45 0 088 300 01
idle_init_start_sub_load_r3:     MOVB    r3, #008h              ; 4D46 0 208 180 9B08
                CLR     A                      ; 4D48 1 208 180 F9
idle_init_start_sub_rom_load_tbl_x1:     LC      A, [X1]                ; 4D49 1 208 180 90A8
                MB      C, PSWH.6              ; 4D4B 1 208 180 A22E
                INC     X1                     ; 4D4D 1 208 180 70
                INC     X1                     ; 4D4E 1 208 180 70
                JGE     idle_init_start_sub_load_x2             ; 4D4F 1 208 180 CD08
                RC                             ; 4D51 1 208 180 95
                RORB    r2                     ; 4D52 1 208 180 22C7
                RC                             ; 4D54 1 208 180 95
                RORB    r0                     ; 4D55 1 208 180 20C7
                SJ      idle_init_start_sub_decb_r3             ; 4D57 1 208 180 CB13
idle_init_start_sub_load_x2:     MOV     X2, A                  ; 4D59 1 208 180 51
                SLL     A                      ; 4D5A 1 208 180 53
                RORB    r2                     ; 4D5B 1 208 180 22C7
                L       A, X2                  ; 4D5D 1 208 180 41
                AND     A, #00fffh             ; 4D5E 1 208 180 D6FF0F
                MOV     DP, A                  ; 4D61 1 208 180 52
                L       A, X2                  ; 4D62 1 208 180 41
                SWAP                           ; 4D63 1 208 180 83
                SRL     A                      ; 4D64 1 208 180 63
                SRL     A                      ; 4D65 1 208 180 63
                SRL     A                      ; 4D66 1 208 180 63
                SRL     A                      ; 4D67 1 208 180 63
                MBR     C, [DP]                ; 4D68 1 208 180 C221
                RORB    r0                     ; 4D6A 1 208 180 20C7
idle_init_start_sub_decb_r3:     DECB    r3                     ; 4D6C 1 208 180 BB
                JNE     idle_init_start_sub_rom_load_tbl_x1             ; 4D6D 1 208 180 CEDA
                LB      A, r0                  ; 4D6F 0 208 180 78
                XORB    A, r2                  ; 4D70 0 208 180 22F2
                RT                             ; 4D72 0 208 180 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4D73
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4D7B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4D83
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0C5h,0A0h,02Fh ; 4D8B
                DB  0CDh,005h,0B5h,01Ah,098h,01Bh,014h,032h ; 4D93
                DB  0C8h,036h,001h,0FFh,0FFh,0FFh,0FFh,0FFh ; 4D9B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4DA3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4DAB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4DB3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh ; 4DBB
vss_clamp_common_sub_set_pswh_bit0_2:     SB      PSWH.0                 ; 4DC0 1 088 300 A218
                LB      A, #04dh               ; 4DC2 0 088 300 774D
                CAL     percyl_counter_gate_sub_cmp_ram0d7             ; 4DC4 0 088 300 320C4A
                RT                             ; 4DC7 0 088 300 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4DC8
knock_div_calc4_if_ram215_bit0_clr:     JBR     off(00215h).0, knock_div_calc4_goto_1ac7 ; 4DD0 0 208 180 D81506
                JBS     off(00216h).1, knock_div_calc4_goto_1ac7 ; 4DD3 0 208 180 E91603
                J       knock_div_calc4_if_ram213_bit1_set             ; 4DD6 0 208 180 03AF1A
knock_div_calc4_goto_1ac7:     J       knock_div_calc4_load_imm_2             ; 4DD9 0 208 180 03C71A
                DB  0FFh,0FFh,0FFh,0FFh ; 4DDC
knock_div_calc4_if_ram215_bit0_clr_2:     JBR     off(00215h).0, knock_div_calc4_goto_1ae0 ; 4DE0 0 208 180 D81506
                JBS     off(00216h).1, knock_div_calc4_goto_1ae0 ; 4DE3 0 208 180 E91603
                J       knock_div_calc4_if_ram22f_bit4_set             ; 4DE6 0 208 180 03D11A
knock_div_calc4_goto_1ae0:     J       knock_div_calc4_load_imm_3             ; 4DE9 0 208 180 03E01A
                DB  0FFh,0FFh,0FFh,0FFh ; 4DEC
crank_cycle_er2_store_load_imm:     L       A, #0141bh             ; 4DF0 1 108 280 671B14
                MB      C, 0a0h.7              ; 4DF3 1 108 280 C5A02F
                JLT     crank_cycle_er2_store_store_ie             ; 4DF6 1 108 280 CA03
                L       A, #0041bh             ; 4DF8 1 108 280 671B04
crank_cycle_er2_store_store_ie:     ST      A, IE                  ; 4DFB 1 108 280 D51A
                J       crank_cycle_er2_store_load_lrb             ; 4DFD 1 108 280 03E11E
tps_interp_exact_match_load_ie:     MOV     IE, #0141bh            ; 4E00 0 200 180 B51A981B14
                NOP                            ; 4E05 0 200 180 00
                MOV     IE, #0041bh            ; 4E06 0 200 180 B51A981B04
                J       tps_interp_exact_match_load_r0             ; 4E0B 0 200 180 03C022
ign_p40_toggle_load_ie:     MOV     IE, #0141bh            ; 4E0E 0 200 180 B51A981B14
                NOP                            ; 4E13 0 200 180 00
                MOV     IE, #0041bh            ; 4E14 0 200 180 B51A981B04
                J       ign_p40_toggle_load_lrb             ; 4E19 0 200 180 032228
                DB  0FFh,0FFh,0FFh,0FFh ; 4E1C
int_break_sub_load_ram07b:     MOVB    SCONB, #081h            ; 4E20 1 088 300 C57B9881
                LC      A, 00020h              ; 4E24 1 088 300 909C2000
                CMP     A, #00043h             ; 4E28 1 088 300 C64300
                JEQ     int_break_sub_return             ; 4E2B 1 088 300 C904
                MOVB    SCONB, #0a1h            ; 4E2D 1 088 300 C57B98A1
int_break_sub_return:     RT                             ; 4E31 1 088 300 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4E32
clamp_result_store_sub_load_r1:     MOVB    r1, #085h              ; 4E38 0 208 180 9985
                MOVB    r2, #081h              ; 4E3A 0 208 180 9A81
                L       A, #00043h             ; 4E3C 1 208 180 674300
                CMPC    A, 00020h              ; 4E3F 1 208 180 909E2000
                JEQ     clamp_result_store_sub_return             ; 4E43 1 208 180 C902
                MOVB    r2, #0a1h              ; 4E45 1 208 180 9AA1
clamp_result_store_sub_return:     RT                             ; 4E47 1 208 180 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4E48
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4E50
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4E58
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4E60
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4E68
                DB  062h,048h,003h,0F2h,0D6h,0F1h,001h,0FFh ; 4E70
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4E78
vcal_4_sub_clear_acc_2:     CLR     A                      ; 4E80 1 3B0 180 F9
                MOV     DP, #0011ah            ; 4E81 1 3B0 180 621A01
                MB      C, [DP].0              ; 4E84 1 3B0 180 C228
                JLT     vcal_4_sub_store_ram3c2             ; 4E86 1 3B0 180 CA02
                L       A, off(00382h)         ; 4E88 1 3B0 180 E482
vcal_4_sub_store_ram3c2:     ST      A, off(003c2h)         ; 4E8A 1 3B0 180 D4C2
                RT                             ; 4E8C 1 3B0 180 01
                DB  0FFh,0FFh,0FFh,0FAh,090h,09Dh,03Bh,000h ; 4E8D
                DB  0D6h,00Fh,083h,0D5h,007h,090h,09Dh,053h ; 4E95
                DB  06Dh,0D6h,00Fh,0C5h,007h,0E2h,001h,0FFh ; 4E9D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4EA5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4EAD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4EB5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4EBD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4EC5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4ECD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4ED5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4EDD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4EE5
                DB  0FFh,0FFh,0FFh ; 4EED
ign_p40_toggle_load_imm_2:     LB      A, #0ffh               ; 4EF0 0 100 280 77FF
                JBR     off(00132h).5, ign_p40_toggle_cmp_acc_3 ; 4EF2 0 100 280 DD3202
                LB      A, #0ffh               ; 4EF5 0 100 280 77FF
ign_p40_toggle_cmp_acc_3:     CMPB    A, off(00179h)         ; 4EF7 0 100 280 C779
                MB      off(00132h).5, C       ; 4EF9 0 100 280 C4323D
                LB      A, #0ffh               ; 4EFC 0 100 280 77FF
                JBR     off(00132h).6, ign_p40_toggle_cmp_acc_4 ; 4EFE 0 100 280 DE3202
                LB      A, #0ffh               ; 4F01 0 100 280 77FF
ign_p40_toggle_cmp_acc_4:     CMPB    A, off(00179h)         ; 4F03 0 100 280 C779
                MB      off(00132h).6, C       ; 4F05 0 100 280 C4323E
                LB      A, #0ffh               ; 4F08 0 100 280 77FF
                JBR     off(00132h).7, ign_p40_toggle_cmp_acc_5 ; 4F0A 0 100 280 DF3202
                LB      A, #0ffh               ; 4F0D 0 100 280 77FF
ign_p40_toggle_cmp_acc_5:     CMPB    A, off(00179h)         ; 4F0F 0 100 280 C779
                MB      off(00132h).7, C       ; 4F11 0 100 280 C4323F
                LB      A, #003h               ; 4F14 0 100 280 7703
                JBR     off(0011dh).1, ign_p40_toggle_if_ram132_bit5_clr ; 4F16 0 100 280 D91D07
                JBS     off(00132h).7, ign_p40_toggle_store_r0 ; 4F19 0 100 280 EF320F
ign_p40_toggle_load_imm_3:     LB      A, #001h               ; 4F1C 0 100 280 7701
                SJ      ign_p40_toggle_store_r0             ; 4F1E 0 100 280 CB0B
ign_p40_toggle_if_ram132_bit5_clr:     JBR     off(00132h).5, ign_p40_toggle_clear_acc ; 4F20 0 100 280 DD3207
                JBR     off(00132h).6, ign_p40_toggle_load_imm_3 ; 4F23 0 100 280 DE32F6
                LB      A, #002h               ; 4F26 0 100 280 7702
                SJ      ign_p40_toggle_store_r0             ; 4F28 0 100 280 CB01
ign_p40_toggle_clear_acc:     CLRB    A                      ; 4F2A 0 100 280 FA
ign_p40_toggle_store_r0:     STB     A, r0                  ; 4F2B 0 100 280 88
                J       ign_p40_toggle_clear_r1             ; 4F2C 0 100 280 03A228
                DB  0FFh ; 4F2F
sensor_bank_gate3_sub_vcal_0:     VCAL    0                      ; 4F30 0 208 180 10
                STB     A, r3                  ; 4F31 0 208 180 8B
                LB      A, 0d8h                ; 4F32 0 208 180 F5D8
                MOV     X1, #sensor_bank_gate3_tbl_2          ; 4F34 0 208 180 600D58
                RT                             ; 4F37 0 208 180 01
knockretard_store_load_imm_2:     LB      A, #019h               ; 4F38 0 200 180 7719
                J       knockretard_store_addb_acc             ; 4F3A 0 200 180 03806E
                DB  000h ; 4F3D
knockretard_store_load_ram280:     L       A, off(00280h)         ; 4F3E 1 200 180 E480
                ST      A, er3                 ; 4F40 1 200 180 8B
                MOV     X1, #knockretard_store_tbl          ; 4F41 1 200 180 600058
                LB      A, off(00288h)         ; 4F44 0 200 180 F488
                CAL     knockretard_table_gate_sub_load_acc             ; 4F46 0 200 180 32EE43
                VCAL    7                      ; 4F49 0 200 180 17
                STB     A, r0                  ; 4F4A 0 200 180 88
                JBR     off(00230h).5, knockretard_store_goto_2410 ; 4F4B 0 200 180 DD3003
                J       knockretard_store_load_ram29c             ; 4F4E 0 200 180 03FB23
knockretard_store_goto_2410:     J       knockretard_store_goto_6e90             ; 4F51 0 200 180 031024
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4F54
                DB  0FFh,0FFh,0FFh,0FFh ; 4F5C
idle_temp_hyst3_decb_ram296:     DECB    off(00296h)            ; 4F60 1 208 180 C49617
                L       A, #02000h             ; 4F63 1 208 180 670020
                JBS     off(00220h).6, idle_temp_hyst3_goto_3d3a ; 4F66 1 208 180 EE2004
                LC      A, 03d2bh              ; 4F69 1 208 180 909C2B3D
idle_temp_hyst3_goto_3d3a:     J       idle_temp_hyst3_store_ram24a             ; 4F6D 1 208 180 033A3D
idle_temp_hyst3_load_imm_4:     LB      A, #002h               ; 4F70 0 208 180 7702
                JBS     off(00220h).6, idle_temp_hyst3_store_ram296 ; 4F72 0 208 180 EE2004
                LCB     A, 03d38h              ; 4F75 0 208 180 909D383D
idle_temp_hyst3_store_ram296:     STB     A, off(00296h)         ; 4F79 0 208 180 D496
                J       idle_temp_hyst3_clear_acc_3             ; 4F7B 0 208 180 03393D
                DB  0FFh,0FFh,0FAh,062h,012h,002h,0C2h,028h ; 4F7E
                DB  0CAh,002h,0F5h,0DFh,001h,0FFh,0FFh,0FFh ; 4F86
                DB  0FFh,0FFh ; 4F8E
knockretard_store_sub_vcal_7:     VCAL    7                      ; 4F90 0 200 180 17
                STB     A, off(002cah)         ; 4F91 0 200 180 D4CA
                JBR     off(00217h).0, knockretard_store_sub_clear_acc ; 4F93 0 200 180 D81723
                JBR     off(00220h).6, knockretard_store_sub_clear_acc ; 4F96 0 200 180 DE2020
                JBS     off(00224h).2, knockretard_store_sub_clear_acc ; 4F99 0 200 180 EA241D
                JBR     off(00216h).2, knockretard_store_sub_clear_acc ; 4F9C 0 200 180 DA161A
                JBR     off(0022ch).4, knockretard_store_sub_clear_acc ; 4F9F 0 200 180 DC2C17
                CMPB    off(00288h), #060h     ; 4FA2 0 200 180 C488C060
                JGE     knockretard_store_sub_clear_acc             ; 4FA6 0 200 180 CD11
                CLRB    A                      ; 4FA8 0 200 180 FA
                LCB     A, 0145bh              ; 4FA9 0 200 180 909D5B14
                JBS     off(00220h).2, knockretard_store_sub_cmp_acc ; 4FAD 0 200 180 EA2004
                LCB     A, 01470h              ; 4FB0 0 200 180 909D7014
knockretard_store_sub_cmp_acc:     CMPB    A, 0d9h                ; 4FB4 0 200 180 C5D9C2
                JGE     knockretard_store_sub_load_dp             ; 4FB7 0 200 180 CD07
knockretard_store_sub_clear_acc:     CLRB    A                      ; 4FB9 0 200 180 FA
                STB     A, off(002bdh)         ; 4FBA 0 200 180 D4BD
                STB     A, off(002beh)         ; 4FBC 0 200 180 D4BE
                SJ      knockretard_store_sub_store_ram2c2             ; 4FBE 0 200 180 CB25
knockretard_store_sub_load_dp:     MOV     DP, #002bdh            ; 4FC0 0 200 180 62BD02
                MOV     X1, #002beh            ; 4FC3 0 200 180 60BE02
                MOVB    r0, #004h              ; 4FC6 0 200 180 9804
                MOVB    r1, #02ah              ; 4FC8 0 200 180 992A
                JBS     off(0022ch).2, knockretard_store_sub_load_r0 ; 4FCA 0 200 180 EA2C0A
                LB      A, #02ah               ; 4FCD 0 200 180 772A
                VCAL    7                      ; 4FCF 0 200 180 17
                STB     A, r1                  ; 4FD0 0 200 180 89
                L       A, X1                  ; 4FD1 1 200 180 40
                XCHG    A, DP                  ; 4FD2 1 200 180 9210
                MOV     X1, A                  ; 4FD4 1 200 180 50
                MOVB    r0, #006h              ; 4FD5 1 200 180 9806
knockretard_store_sub_load_r0:     LB      A, r0                  ; 4FD7 0 200 180 78
                MOVB    00000h[X1], A          ; 4FD8 0 200 180 C000008A
                LB      A, [DP]                ; 4FDC 0 200 180 F2
                JEQ     knockretard_store_sub_store_ram2c2             ; 4FDD 0 200 180 C906
                DECB    [DP]                   ; 4FDF 0 200 180 C217
                CLRB    off(002adh)            ; 4FE1 0 200 180 C4AD15
                LB      A, r1                  ; 4FE4 0 200 180 79
knockretard_store_sub_store_ram2c2:     STB     A, off(002c2h)         ; 4FE5 0 200 180 D4C2
                RT                             ; 4FE7 0 200 180 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4FE8
scale_result_common_sub_extnd_acc_3:     EXTND                          ; 4FF0 1 200 180 F8
                ADD     er3, A                 ; 4FF1 1 200 180 4781
                LB      A, off(002c2h)         ; 4FF3 0 200 180 F4C2
                EXTND                          ; 4FF5 1 200 180 F8
                ADD     er3, A                 ; 4FF6 1 200 180 4781
                RT                             ; 4FF8 1 200 180 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 4FF9
                DB  09Ch,0F8h,09Fh,0F0h,0A8h,0E8h,0A5h,0E0h ; 5001
                DB  0A9h,0D8h,0ACh,0D0h,0AFh,0C8h,0AAh,0C0h ; 5009
                DB  0A4h,0B0h,097h,0A8h,091h,0A0h,08Ah,098h ; 5011
                DB  081h,090h,077h,088h,06Eh,080h,064h,070h ; 5019
                DB  05Ah,060h,04Eh,050h,043h,040h,037h,020h ; 5021
                DB  02Ah,000h,01Ch,0FFh,020h,0FEh,021h,0BCh ; 5029
                DB  031h,0A7h,036h,09Dh,03Bh,092h,040h,088h ; 5031
                DB  046h,07Dh,04Dh,073h,057h,068h,061h,053h ; 5039
                DB  08Ah,03Fh,0EEh,000h,0EEh,0FFh,034h,0F8h ; 5041
                DB  030h,0F0h,02Ch,0E8h,029h,0E0h,026h,0D8h ; 5049
                DB  023h,0D0h,01Fh,0C8h,01Ch,0C0h,019h,0B0h ; 5051
                DB  015h,0A8h,013h,0A0h,011h,098h,00Fh,090h ; 5059
                DB  00Eh,088h,00Ch,080h,00Ah,070h,007h,060h ; 5061
                DB  005h,050h,003h,040h,002h,020h,000h,000h ; 5069
                DB  000h,0FFh,019h,0AEh,019h,087h,019h,057h ; 5071
                DB  019h,034h,000h,000h,000h,0D4h,000h,064h ; 5079
                DB  000h,089h,0D4h,076h,051h,0FFh,000h,01Fh ; 5081
                DB  000h,01Bh,000h,015h,006h,010h,00Dh,00Fh ; 5089
                DB  00Dh,000h,00Dh,0FFh,000h,01Fh,000h,01Bh ; 5091
                DB  000h,015h,000h,010h,000h,00Fh,000h,000h ; 5099
                DB  000h,0FFh,050h,0F1h,050h,0BAh,050h,0A1h ; 50A1
                DB  043h,057h,020h,028h,000h,000h,000h,0FFh ; 50A9
                DB  040h,0F1h,040h,0BAh,040h,0A1h,032h,057h ; 50B1
                DB  014h,028h,000h,000h,000h,0FFh,040h,0A0h ; 50B9
                DB  040h,080h,038h,040h,02Ch,000h,02Ch,0FFh ; 50C1
                DB  0FFh,000h,000h,050h,001h,000h,000h,000h ; 50C9
                DB  001h,015h,000h,0B3h,000h,015h,000h,000h ; 50D1
                DB  000h,000h,000h,0FFh,0FFh,000h,000h,0BEh ; 50D9
                DB  001h,000h,000h,045h,001h,015h,000h,0CDh ; 50E1
                DB  000h,015h,000h,000h,000h,000h,000h,0FFh ; 50E9
                DB  056h,080h,056h,060h,048h,040h,03Ch,000h ; 50F1
                DB  030h,0FFh,0A0h,05Dh,0A0h,02Fh,0A0h,000h ; 50F9
                DB  0A0h,0FFh,020h,05Dh,020h,02Fh,020h,000h ; 5101
                DB  020h,000h,000h,000h,000h,000h,000h,000h ; 5109
                DB  017h,037h,038h,03Bh,038h,045h,047h,055h ; 5111
                DB  057h,05Ah,05Bh,05Bh,05Bh,02Fh,03Bh,040h ; 5119
                DB  04Ah,057h,064h,073h,088h,080h,06Fh,073h ; 5121
                DB  080h,08Dh,08Dh,091h,091h,091h,091h,091h ; 5129
                DB  091h,000h,000h,000h,000h,000h,000h,000h ; 5131
                DB  000h,000h,000h,008h,00Eh,017h,01Fh,02Dh ; 5139
                DB  037h,040h,043h,05Bh,05Bh,000h,000h,000h ; 5141
                DB  002h,011h,022h,02Fh,037h,04Ch,05Dh,06Ah ; 5149
                DB  06Eh,074h,076h,07Bh,077h,07Bh,082h,093h ; 5151
                DB  093h,0FFh,04Dh,0D0h,04Dh,0C0h,040h,0A0h ; 5159
                DB  033h,080h,033h,040h,033h,000h,033h,0FFh ; 5161
                DB  02Ah,0D0h,02Ah,0C0h,02Ah,0A0h,02Ah,080h ; 5169
                DB  02Ah,040h,019h,000h,019h,000h,000h,04Ch ; 5171
                DB  080h,080h,000h,000h,000h,000h,000h,000h ; 5179
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 5181
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 5189
                DB  000h,000h,000h,000h,000h,000h,000h,004h ; 5191
                DB  006h,008h,014h,017h,017h,000h,000h,000h ; 5199
                DB  000h,000h,008h,008h,008h,008h,008h,008h ; 51A1
                DB  008h,008h,008h,030h,030h,040h,030h,030h ; 51A9
                DB  030h,020h,004h,030h,004h,020h,004h,020h ; 51B1
                DB  0D4h,0D4h,064h,03Fh,0D4h,0B6h,064h,03Fh ; 51B9
                DB  0FFh,04Ch,0F5h,04Ch,0BAh,04Ah,087h,048h ; 51C1
                DB  02Eh,044h,028h,040h,000h,040h,0FFh,06Ah ; 51C9
                DB  0F5h,06Ah,0BAh,062h,087h,05Dh,02Eh,04Ah ; 51D1
                DB  028h,040h,000h,040h,0FFh,040h,0F5h,040h ; 51D9
                DB  0BAh,040h,087h,040h,02Eh,040h,028h,040h ; 51E1
                DB  000h,040h,0FFh,053h,0F5h,053h,0BAh,053h ; 51E9
                DB  087h,04Eh,02Eh,043h,028h,040h,000h,040h ; 51F1
                DB  0FFh,060h,0D0h,060h,087h,059h,056h,050h ; 51F9
                DB  02Eh,045h,028h,040h,000h,040h,0FFh,08Fh ; 5201
                DB  0F5h,08Fh,0BAh,080h,087h,076h,02Eh,043h ; 5209
                DB  028h,040h,000h,040h,0FFh,0EBh,091h,0F5h ; 5211
                DB  0EBh,091h,0E1h,008h,08Ch,0BAh,02Bh,087h ; 5219
                DB  087h,000h,080h,057h,029h,07Ch,000h,029h ; 5221
                DB  07Ch,0FFh,099h,099h,0F5h,099h,099h,0E1h ; 5229
                DB  08Fh,05Ah,0A6h,0CDh,03Ch,07Ah,0C3h,035h ; 5231
                DB  034h,0D7h,023h,000h,0D7h,023h,0BAh,02Eh ; 5239
                DB  0A9h,057h,0BAh,03Bh,0A9h,094h,004h,004h ; 5241
                DB  000h,000h,05Ah,004h,05Ah,004h,0E0h,000h ; 5249
                DB  000h,000h,000h,000h,05Ah,004h,05Ah,004h ; 5251
                DB  0E0h,000h,000h,000h,00Bh,0BDh,0BDh,06Fh ; 5259
                DB  02Ch,00Bh,0BDh,0BDh,06Fh,02Ch,0FFh,030h ; 5261
                DB  0F0h,050h,0E0h,070h,0C0h,0B0h,0A0h,0E0h ; 5269
                DB  080h,0E0h,020h,0C0h,000h,0C0h,0FFh,0FFh ; 5271
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5279
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0F5h,000h ; 5281
                DB  089h,030h,0FFh,080h,01Fh,080h,018h,088h ; 5289
                DB  012h,092h,00Fh,098h,000h,098h,0FFh,08Ah ; 5291
                DB  0EDh,08Ah,094h,080h,062h,073h,044h,066h ; 5299
                DB  02Eh,05Ah,000h,05Ah,0FFh,07Dh,0EDh,07Dh ; 52A1
                DB  094h,06Ah,062h,05Dh,044h,050h,02Eh,043h ; 52A9
                DB  000h,043h,0FFh,08Ah,0EDh,08Ah,0BAh,082h ; 52B1
                DB  0A1h,070h,062h,05Bh,02Eh,050h,000h,050h ; 52B9
                DB  0FFh,07Dh,0EDh,07Dh,0BAh,06Dh,0A1h,060h ; 52C1
                DB  062h,050h,02Eh,033h,000h,033h,0FFh,0FFh ; 52C9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 52D1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,080h,080h ; 52D9
                DB  080h,080h,0FFh,000h,0F9h,000h,0DBh,00Fh ; 52E1
                DB  0BDh,02Ch,0A0h,048h,000h,048h,0FFh,000h ; 52E9
                DB  070h,000h,050h,05Ah,030h,0A6h,010h,0FFh ; 52F1
                DB  000h,0FFh,0FFh,08Bh,000h,0A7h,08Bh,000h ; 52F9
                DB  092h,0ABh,000h,07Dh,0DDh,000h,069h,036h ; 5301
                DB  001h,054h,0E5h,001h,000h,0E5h,001h,099h ; 5309
                DB  0D9h,005h,000h,000h,000h,066h,04Fh,007h ; 5311
                DB  000h,000h,000h,066h,034h,008h,000h,0D8h ; 5319
                DB  000h,033h,0A7h,003h,000h,000h,000h,033h ; 5321
                DB  08Ch,004h,000h,0D8h,000h,01Fh,0EEh,000h ; 5329
                DB  000h,000h,001h,028h,0ECh,000h,000h,000h ; 5331
                DB  001h,01Fh,0E9h,000h,000h,000h,001h,028h ; 5339
                DB  0ECh,000h,000h,000h,001h,0F9h,080h,089h ; 5341
                DB  040h,0FFh,050h,0E1h,048h,094h,038h,057h ; 5349
                DB  018h,02Eh,000h,000h,000h,0FFh,068h,0EDh ; 5351
                DB  068h,0D0h,05Dh,0A1h,057h,06Eh,03Ah,028h ; 5359
                DB  013h,000h,013h,0FFh,029h,0EDh,029h,0D0h ; 5361
                DB  024h,0A1h,024h,06Eh,023h,028h,010h,000h ; 5369
                DB  010h,0FFh,01Eh,000h,00Fh,0FFh,00Ah,000h ; 5371
                DB  019h,0FFh,08Ah,066h,0F5h,08Ah,066h,0E1h ; 5379
                DB  0BAh,037h,0BAh,004h,029h,06Eh,088h,013h ; 5381
                DB  028h,07Fh,008h,000h,07Fh,008h,0FFh,0FFh ; 5389
                DB  0FFh,0FFh,0F5h,080h,089h,04Eh,0FFh,083h ; 5391
                DB  0EDh,083h,094h,06Dh,062h,060h,044h,053h ; 5399
                DB  02Eh,046h,000h,046h,0FFh,083h,0EDh,083h ; 53A1
                DB  0BAh,070h,0A1h,06Ah,062h,060h,02Eh,03Ah ; 53A9
                DB  000h,03Ah,0FFh,08Dh,0EDh,08Dh,094h,080h ; 53B1
                DB  062h,073h,044h,066h,02Eh,05Ah,000h,05Ah ; 53B9
                DB  0FFh,08Dh,0EDh,08Dh,0BAh,082h,0A1h,07Dh ; 53C1
                DB  062h,073h,02Eh,050h,000h,050h,0FFh,014h ; 53C9
                DB  0FCh,014h,0E0h,013h,0CDh,009h,083h,009h ; 53D1
                DB  000h,009h,0FFh,019h,0FCh,019h,0E0h,00Ch ; 53D9
                DB  0CDh,020h,0C0h,030h,000h,030h,0FFh,01Dh ; 53E1
                DB  0FCh,01Dh,0E0h,01Dh,0CDh,013h,083h,013h ; 53E9
                DB  000h,013h,0FFh,023h,0FCh,023h,0E0h,014h ; 53F1
                DB  0CDh,028h,0C0h,038h,000h,038h,0F8h,000h ; 53F9
;  [info] rev-limit word pairs (16-bit, 'OBD1_16bit RPM' per p13info). Split here for labelling:
;    5401=3000h 5403=012Ah 5405=00DFh 5407=0120h | 5409=00C1h 540B=00FAh 540D=0112h 540F=00F4h
;    p13info: 5403 low-cam reset, 5407 low-cam set, 540B high-cam reset, 540F high-cam set.
;    Code uses (5403,5407) when 0212h.5 set, else (540B,540F); the latter pair is also the boot
;    default immediates @0C1E/0C23. See block at 1520.
                DB  000h,030h            ; 5401
revlimit_p1_reset_5403:
                DB  02Ah,01h             ; 5403
                DB  0DFh,00h             ; 5405
revlimit_p1_set_5407:
                DB  020h,01h             ; 5407
                DB  0C1h,00h             ; 5409
revlimit_p2_reset_540b:
                DB  0FAh,00h             ; 540B
                DB  012h,01h             ; 540D
revlimit_p2_set_540f:
                DB  0F4h,00h             ; 540F
                DB  0F0h,000h,066h,086h,033h,083h,000h,080h ; 5411
                DB  0DDh,07Dh,0AAh,07Ah,0AAh,07Ah,066h,086h ; 5419
                DB  033h,083h,000h,080h,0DDh,07Dh,0AAh,07Ah ; 5421
                DB  0AAh,07Ah,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5429
                DB  0FFh,0FFh,0FFh,0FFh,000h,000h,0FFh,0FFh ; 5431
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5439
                DB  000h,000h,05Bh,004h,0CAh,004h,039h,005h ; 5441
                DB  0A9h,005h,018h,006h,000h,000h,039h,005h ; 5449
                DB  0A9h,005h,018h,006h,088h,006h,0F7h,006h ; 5451
                DB  000h,000h,04Dh,075h,09Eh,0C5h,0FFh,000h ; 5459
                DB  012h,0F5h,000h,012h,0E4h,080h,009h,0D0h ; 5461
                DB  080h,009h,0B9h,000h,015h,087h,000h,012h ; 5469
                DB  058h,000h,00Fh,02Eh,020h,001h,000h,020h ; 5471
                DB  001h,0FFh,000h,010h,0F5h,000h,010h,0D8h ; 5479
                DB  000h,010h,0BAh,080h,009h,087h,000h,016h ; 5481
                DB  067h,000h,016h,04Dh,000h,00Fh,02Eh,020h ; 5489
                DB  001h,000h,020h,001h,0FFh,000h,040h,0F5h ; 5491
                DB  000h,040h,0E4h,000h,024h,0D0h,000h,024h ; 5499
                DB  0B9h,000h,02Dh,087h,000h,028h,058h,000h ; 54A1
                DB  020h,02Eh,080h,00Dh,000h,080h,00Dh,0FFh ; 54A9
                DB  000h,03Ch,0F5h,000h,03Ch,0D8h,000h,028h ; 54B1
                DB  0BAh,000h,01Eh,087h,000h,01Eh,067h,000h ; 54B9
                DB  01Eh,04Dh,000h,018h,02Eh,000h,00Fh,000h ; 54C1
                DB  000h,00Fh,0FFh,000h,026h,0F5h,000h,026h ; 54C9
                DB  0E4h,000h,016h,0D0h,000h,016h,0B9h,000h ; 54D1
                DB  01Bh,087h,000h,018h,058h,000h,014h,02Eh ; 54D9
                DB  000h,00Bh,000h,000h,00Bh,0FFh,000h,020h ; 54E1
                DB  0F5h,000h,020h,0D8h,000h,020h,0BAh,000h ; 54E9
                DB  019h,087h,000h,01Eh,067h,000h,01Eh,04Dh ; 54F1
                DB  000h,018h,02Eh,000h,00Fh,000h,000h,00Fh ; 54F9
                DB  0FFh,07Ah,0EDh,07Ah,094h,066h,062h,05Dh ; 5501
                DB  044h,053h,02Eh,046h,000h,046h,0FFh,086h ; 5509
                DB  0EDh,086h,094h,07Ah,062h,070h,044h,066h ; 5511
                DB  02Eh,066h,000h,066h,0FFh,0E2h,004h,0EDh ; 5519
                DB  0E2h,004h,094h,0A2h,005h,062h,05Eh,006h ; 5521
                DB  044h,053h,007h,02Eh,077h,00Ah,000h,077h ; 5529
                DB  00Ah,0FFh,04Fh,004h,0EDh,04Fh,004h,094h ; 5531
                DB  0E2h,004h,062h,06Dh,005h,044h,01Bh,006h ; 5539
                DB  02Eh,0B6h,007h,000h,0B6h,007h,024h,00Ah ; 5541
                DB  02Eh,010h,00Ch,001h,001h,001h,001h,001h ; 5549
                DB  002h,001h,000h,000h,000h,000h,00Fh,000h ; 5551
                DB  006h,000h,005h,0FFh,070h,0EDh,070h,094h ; 5559
                DB  063h,062h,05Ah,044h,050h,02Eh,043h,000h ; 5561
                DB  043h,0FFh,008h,000h,0EDh,008h,000h,094h ; 5569
                DB  012h,000h,062h,025h,000h,044h,02Eh,000h ; 5571
                DB  02Eh,05Ah,000h,000h,05Ah,000h,0FFh,070h ; 5579
                DB  0EDh,070h,094h,054h,062h,048h,044h,040h ; 5581
                DB  02Eh,034h,000h,034h,0FFh,01Ah,0EDh,01Ah ; 5589
                DB  094h,010h,062h,00Ah,044h,008h,02Eh,005h ; 5591
                DB  000h,005h,0FFh,063h,04Dh,063h,020h,046h ; 5599
                DB  017h,03Eh,000h,03Eh,0FFh,059h,04Dh,059h ; 55A1
                DB  02Dh,04Bh,017h,03Eh,000h,03Eh,0FFh,0C0h ; 55A9
                DB  005h,0A7h,030h,003h,082h,050h,001h,072h ; 55B1
                DB  010h,001h,060h,000h,000h,000h,000h,000h ; 55B9
                DB  0FFh,080h,004h,040h,080h,004h,033h,080h ; 55C1
                DB  006h,02Eh,080h,007h,000h,080h,007h,0FFh ; 55C9
                DB  0B8h,0A0h,0B8h,080h,09Ch,040h,080h,000h ; 55D1
                DB  080h,0FFh,040h,00Bh,0F5h,040h,00Bh,0D0h ; 55D9
                DB  080h,009h,0BAh,000h,008h,094h,000h,00Bh ; 55E1
                DB  057h,080h,00Dh,044h,040h,009h,028h,040h ; 55E9
                DB  005h,000h,040h,005h,0FFh,0FFh,040h,005h ; 55F1
                DB  0C5h,00Ah,040h,005h,077h,00Ah,040h,005h ; 55F9
                DB  045h,009h,080h,009h,000h,000h,080h,009h ; 5601
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5609
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5611
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5619
                DB  0FFh,0FFh,0FFh ; 5621
idle_temp_hyst3_tbl:       DB  0FFh,000h,007h,0DAh,000h,007h,0D0h,000h ; 5624
                DB  024h,0C3h,080h,01Fh,0ADh,050h,012h,090h ; 562C
                DB  0E0h,00Eh,066h,000h,000h,000h,000h,000h ; 5634
idle_temp_hyst3_tbl_2:       DB  0FFh,000h,02Ah,0F0h,000h,02Ah,0E0h,000h ; 563C
                DB  033h,0DAh,0D0h,029h,0D3h,000h,026h,0CAh ; 5644
                DB  000h,00Bh,0C0h,000h,000h,000h,000h,000h ; 564C
dcode14_check_tbl:       DB  0F7h,080h,060h,0C2h ; 5654
overrev_hardcap_compare_tbl:       DB  0FFh,000h,040h,0F1h,000h,040h,0E7h,000h ; 5658
                DB  032h,0DEh,000h,028h,0D0h,000h,01Dh,0BAh ; 5660
                DB  000h,017h,0A1h,000h,010h,062h,000h,000h ; 5668
                DB  000h,000h,000h ; 5670
overrev_hardcap_compare_tbl_2:       DB  0FFh,000h,040h,0F1h,000h,040h,0E7h,000h ; 5673
                DB  03Dh,0DEh,000h,031h,0D0h,000h,022h,0BAh ; 567B
                DB  000h,019h,0A1h,000h,012h,062h,000h,000h ; 5683
                DB  000h,000h,000h ; 568B
idle_gear_target_store_tbl:       DB  0FFh,0FFh,0C0h,0FFh,000h,040h,000h,0F0h,07Ah,02Ch ; 568E
                DB  000h,0C0h,0D7h,01Bh,000h,0A0h,0E3h,00Dh,000h,080h ; 5698
                DB  0DEh,004h,000h,060h,016h,002h,000h,050h,0B4h,000h ; 56A2
                DB  066h,046h,000h,000h,099h,039h,000h,000h,000h,000h ; 56AC
injector_effective_pw_skip_tbl:       DB  0FFh,000h,0DCh,000h,0D9h,050h,0D4h,0D0h ; 56B6
                DB  0CFh,0F0h,0CDh,0FFh,000h,0FFh,000h,000h ; 56BE
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 56C6
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 56CE
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 56D6
                DB  000h,000h,000h,000h,000h,000h ; 56DE
overrev_hardcap_compare_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 56E4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 56EC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,000h,000h,000h ; 56F4
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 56FC
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 5704
                DB  000h,000h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 570C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5714
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 571C
tipin_decay_zero_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5722
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 572C
tbl_tps_5736:       DB  066h,0E0h,01Ah,060h ; 5736
tbl_ect_simulate_ramp:       DB  0E1h,0CFh,0A0h,06Dh,028h ; 573A
tbl_dcode14_lo:       DB  0A7h,0CDh,0FCh,034h,000h,038h ; 573F
tbl_dcode14_hi:       DB  0FFh,000h,000h,000h,000h,000h ; 5745
revlimiter_engage_resume_check_tbl:       DB  02Eh,060h,022h ; 574B
dtc_scan_new_code_tbl:       DB  04Dh,00Fh,00Fh,00Fh,02Dh,02Dh,04Bh,00Fh ; 574E
                DB  000h,00Fh,02Dh,00Fh,02Dh,02Dh,0FFh,000h ; 5756
                DB  02Dh,006h,02Dh,00Fh,00Fh,02Dh,02Dh,0FFh ; 575E
                DB  0FFh,007h,007h,014h,0FFh,0FFh,0FFh,0FFh ; 5766
                DB  0FFh ; 576E
clamp_result_store_tbl:       DB  02Dh,02Dh,007h,006h,006h,006h ; 576F
learn_table1_check_tbl:       DB  019h,000h,019h,019h,019h,0FFh,0FFh,0FFh,0FFh,0B3h ; 5775
dtc_active_confirm_tbl:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah ; 577F
                DB  000h,00Ch,00Ch,00Dh,00Eh,011h,000h,000h ; 5787
                DB  014h,015h,016h,017h,018h,01Eh,01Fh,000h ; 578F
                DB  000h,019h,01Ah,01Bh,000h,000h,000h,000h ; 5797
                DB  000h,004h,008h,009h,00Fh,01Eh,01Fh,010h ; 579F
                DB  000h,004h,008h,009h,000h,000h,000h,000h ; 57A7
                DB  01Dh,0A1h,044h,034h ; 57AF
tbl_map_sign:       DB  000h,000h,000h,000h ; 57B3
rpm_decel_limit_check_tbl:       DB  0D4h,001h,0A9h,003h,053h,007h,000h,000h ; 57B7
                DB  000h,000h,0FFh,0FFh ; 57BF
crank_sync_exit_jump_tbl:       DB  084h,094h,0A4h,0B4h,006h,016h,026h,036h ; 57C3
                DB  046h,056h,06Eh,07Eh,08Eh,09Eh,0AEh,0BEh ; 57CB
                DB  00Ch,01Ch,02Ch,03Ch,04Ch,05Ch,064h,074h ; 57D3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 57DB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 57E3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 57EB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 57F3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh ; 57FB
knockretard_store_tbl:       DB  088h,0FFh,076h ; 5800
sensor_bank_gate3_tbl:       DB  0FFh,000h,087h,000h,057h,011h,013h,019h,000h,019h ; 5803
sensor_bank_gate3_tbl_2:       DB  0FFh,000h,087h,000h,057h,000h,013h,000h,000h,000h ; 580D
fuelcuttrack_store_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5817
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 581F
fuelcuttrack_store_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5827
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5831
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 583B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5845
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 584F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5859
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5863
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 586D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5877
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5881
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 588B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5895
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 589F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58A9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58B3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58BD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58C7
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58D1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58DB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58E5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58EF
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 58F9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5903
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 590D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5917
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5921
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 592B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5935
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 593F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5949
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5953
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 595D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5967
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5971
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 597B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5985
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 598F
idle_temp_hyst3_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5999
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59A1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59A9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59B1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59B9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59C1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59C9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59D1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59D9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59E1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59E9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59F1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 59F9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A09
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A11
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A19
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A21
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A29
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A31
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A39
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A41
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A49
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A51
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A59
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A61
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A69
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A71
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A79
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A81
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A89
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A91
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5A99
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AA1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AA9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AB1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AB9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AC1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AC9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AD1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AD9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AE1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AE9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AF1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5AF9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B09
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B11
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B19
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B21
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B29
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B31
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B39
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B41
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B49
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B51
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B59
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B61
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B69
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B71
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B79
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B81
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B89
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B91
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5B99
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BA1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BA9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BB1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BB9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BC1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BC9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BD1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BD9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BE1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BE9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BF1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5BF9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C09
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C11
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C19
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C21
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C29
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C31
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C39
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C41
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C49
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C51
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C59
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C61
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C69
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C71
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C79
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C81
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C89
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C91
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5C99
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CA1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CA9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CB1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CB9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CC1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CC9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CD1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CD9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CE1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CE9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CF1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5CF9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D09
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D11
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D19
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D21
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D29
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D31
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D39
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D41
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D49
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D51
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D59
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D61
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D69
o2trim_add_clamp_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D70
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D78
sensor_bank_gate3_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D80
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D8A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D94
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5D9E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DA8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DB2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DBC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DC6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DD0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DDA
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DE4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DEE
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5DF8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E02
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E0C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E16
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E20
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E2A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E34
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E3E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E48
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E52
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E5C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E66
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E70
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E7A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E84
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E8E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5E98
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EA2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EAC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EB6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EC0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5ECA
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5ED4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EDE
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EE8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EF2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5EFC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F06
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F10
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F1A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F24
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F2E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F38
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F42
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F4C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F56
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F60
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F6A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F74
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F7E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F88
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F92
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5F9C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FA6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FB0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FBA
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FC4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FCE
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FD8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FE2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FEC
calchecksum_loop_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 5FF6
tbl_rpm_scalar_lo40:       DB  0A6h,00Eh,0C5h,00Ah,076h,00Ah,045h,009h,053h,007h ; 6000
                DB  0A2h,005h,0E2h,004h,011h,004h,07Ch,003h,0EEh,002h ; 600A
                DB  09Dh,002h,071h,002h,027h,002h,0EDh,001h,0D4h,001h ; 6014
                DB  0B4h,001h,08Eh,001h,06Fh,001h,038h,001h,0FAh,000h ; 601E
tbl_rpm_scalar_hi40:       DB  0A2h,005h,0E2h,004h,011h,004h,07Ch,003h,0EEh,002h ; 6028
                DB  09Dh,002h,071h,002h,0FAh,001h,0D4h,001h,0BEh,001h ; 6032
                DB  0A0h,001h,08Eh,001h,077h,001h,061h,001h,04Eh,001h ; 603C
                DB  038h,001h,020h,001h,013h,001h,0FDh,000h,0EAh,000h ; 6046
tbl_map_axis_mbar10:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,0FFh ; 6050
tbl_fuel_row_mult_lo40:       DB  076h,075h,075h,077h,077h,07Ch,080h,080h,081h,088h ; 605A
                DB  086h,083h,086h,088h,08Ch,093h,093h,095h,094h,085h ; 6064
                DB  0A1h,0A8h,0AAh,0A9h,0A2h,096h,098h,09Eh,0A6h,09Eh ; 606E
                DB  099h,09Dh,09Eh,0ABh,09Ah,0A3h,0A3h,0A6h,083h,063h ; 6078
tbl_fuel_row_mult_hi40:       DB  097h,097h,097h,097h,097h,095h,092h,09Eh,09Ah,09Ah ; 6082
                DB  094h,094h,09Ah,09Fh,0A1h,0A8h,0AEh,0ADh,0A8h,0A2h ; 608C
                DB  002h,002h,002h,002h,002h,002h,002h,002h,01Dh,025h ; 6096
                DB  038h,034h,04Eh,068h,085h,084h,08Ch,07Ah,06Ch,06Ah ; 60A0
tbl_fuel_lo_cam:       DB  080h,080h,080h,090h,08Eh,091h,09Ch,0AEh,0A7h,0A7h ; 60AA
                DB  080h,080h,080h,08Ch,08Eh,08Fh,0A1h,0AEh,0B0h,0B0h ; 60B4
                DB  080h,080h,080h,091h,092h,08Fh,0A1h,0AEh,0AFh,0AFh ; 60BE
                DB  080h,080h,080h,093h,08Fh,090h,0A2h,0AFh,0AEh,0AEh ; 60C8
                DB  080h,080h,080h,095h,091h,093h,094h,0A0h,09Eh,09Eh ; 60D2
                DB  080h,080h,080h,094h,091h,092h,093h,09Dh,09Bh,09Ah ; 60DC
                DB  080h,080h,080h,090h,090h,090h,091h,09Bh,099h,099h ; 60E6
                DB  080h,080h,080h,093h,08Eh,08Eh,092h,09Ch,09Dh,09Ch ; 60F0
                DB  080h,080h,080h,08Fh,08Eh,090h,091h,09Dh,0A1h,0A1h ; 60FA
                DB  080h,080h,080h,090h,08Dh,08Ch,08Fh,099h,09Bh,09Bh ; 6104
                DB  080h,080h,080h,08Fh,08Fh,08Fh,09Dh,099h,09Ah,09Ah ; 610E
                DB  080h,080h,080h,092h,092h,092h,095h,09Eh,09Fh,09Fh ; 6118
                DB  080h,080h,080h,093h,092h,090h,092h,09Eh,09Ch,09Ch ; 6122
                DB  080h,080h,093h,091h,091h,08Fh,092h,09Eh,09Ch,09Ch ; 612C
                DB  080h,080h,09Ah,096h,095h,094h,097h,0A1h,09Fh,09Fh ; 6136
                DB  080h,098h,094h,091h,091h,08Fh,08Eh,09Bh,099h,099h ; 6140
                DB  080h,097h,095h,094h,092h,092h,09Eh,09Ch,09Bh,09Bh ; 614A
                DB  080h,09Eh,096h,093h,092h,093h,09Ch,09Bh,09Ah,09Ah ; 6154
                DB  080h,0A3h,099h,097h,094h,08Ah,093h,091h,08Fh,08Fh ; 615E
                DB  080h,0A0h,0AAh,0ABh,0ABh,0AAh,0ADh,0ADh,0ADh,0ADh ; 6168
tbl_fuel_hi_cam:       DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h ; 6172
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h ; 617C
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h ; 6186
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h ; 6190
                DB  080h,080h,080h,082h,084h,085h,08Ah,092h,095h,095h ; 619A
                DB  080h,080h,080h,082h,084h,08Ah,08Dh,09Bh,09Dh,09Dh ; 61A4
                DB  080h,080h,080h,080h,080h,085h,08Eh,09Dh,0A3h,0A3h ; 61AE
                DB  080h,080h,080h,081h,082h,086h,08Ch,097h,099h,099h ; 61B8
                DB  080h,080h,080h,087h,088h,088h,08Eh,09Bh,09Ah,09Ah ; 61C2
                DB  080h,080h,088h,09Ch,089h,08Ah,08Eh,09Eh,095h,095h ; 61CC
                DB  080h,080h,09Fh,095h,092h,090h,093h,092h,096h,096h ; 61D6
                DB  080h,096h,086h,083h,088h,097h,09Ah,099h,098h,098h ; 61E0
                DB  080h,0A0h,095h,090h,092h,09Eh,0A4h,0A7h,0A5h,0A5h ; 61EA
                DB  080h,09Eh,096h,095h,09Ah,0A5h,0A6h,0A5h,0A6h,0A6h ; 61F4
                DB  080h,09Ah,08Fh,08Fh,093h,09Bh,098h,099h,09Bh,09Bh ; 61FE
                DB  080h,09Ch,097h,094h,08Eh,0A1h,09Eh,09Ch,09Bh,09Bh ; 6208
                DB  080h,092h,099h,099h,0A5h,0A0h,09Fh,09Ch,099h,099h ; 6212
                DB  080h,099h,0A0h,0A0h,0ACh,0A5h,0A2h,0A1h,09Dh,09Dh ; 621C
                DB  080h,099h,099h,09Ah,0B0h,0ADh,0A8h,0A8h,0A5h,0A5h ; 6226
                DB  080h,08Dh,0A4h,0A3h,0ADh,0A9h,0A7h,0A7h,0A3h,0A3h ; 6230
tbl_corr_map_a_623a:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 623A
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 6244
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 624E
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 6258
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 6262
                DB  080h,080h,07Ah,07Ah,078h,078h,080h,080h,080h,080h ; 626C
                DB  080h,080h,07Ah,07Ah,078h,079h,080h,080h,080h,080h ; 6276
                DB  080h,080h,07Ah,07Ah,078h,07Bh,080h,080h,080h,080h ; 6280
                DB  080h,080h,07Ah,07Ah,078h,078h,07Bh,080h,080h,080h ; 628A
                DB  080h,080h,07Eh,07Eh,07Eh,07Eh,080h,080h,080h,080h ; 6294
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 629E
tbl_corr_map_b_62a8:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 62A8
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 62B2
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 62BC
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 62C6
                DB  080h,080h,07Ah,07Ah,078h,077h,080h,080h,080h,080h ; 62D0
                DB  080h,080h,07Ah,07Ah,078h,078h,080h,080h,080h,080h ; 62DA
                DB  080h,080h,07Ah,07Ah,078h,079h,080h,080h,080h,080h ; 62E4
                DB  080h,080h,07Ah,07Ah,078h,07Bh,080h,080h,080h,080h ; 62EE
                DB  080h,080h,07Ah,07Ah,078h,07Bh,080h,080h,080h,080h ; 62F8
                DB  080h,080h,07Eh,07Eh,07Eh,07Eh,080h,080h,080h,080h ; 6302
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 630C
tbl_corr_map_c_6316:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6316
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6320
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 632A
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6334
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 633E
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6348
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6352
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 635C
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6366
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6370
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 637A
tbl_corr_map_d_6384:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6384
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 638E
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6398
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63A2
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63AC
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63B6
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63C0
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63CA
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63D4
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63DE
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 63E8
tbl_aux_63f2:       DB  040h,000h,06Bh,0BFh,08Dh,02Bh ; 63F2
tbl_ign_lo_cam:       DB  055h,055h,055h,055h,02Eh,00Eh,000h,000h,000h,000h ; 63F8
                DB  055h,055h,055h,055h,030h,00Fh,000h,000h,000h,000h ; 6402
                DB  055h,055h,055h,055h,038h,010h,000h,000h,000h,000h ; 640C
                DB  055h,055h,055h,055h,044h,024h,00Ah,006h,002h,002h ; 6416
                DB  055h,055h,055h,055h,055h,03Bh,01Dh,019h,011h,011h ; 6420
                DB  074h,074h,074h,072h,06Fh,051h,033h,02Ah,022h,022h ; 642A
                DB  085h,085h,085h,082h,077h,057h,03Bh,033h,02Fh,02Fh ; 6434
                DB  090h,090h,090h,08Dh,07Eh,062h,048h,040h,037h,037h ; 643E
                DB  098h,098h,098h,095h,084h,06Bh,059h,04Ch,04Ch,04Ch ; 6448
                DB  09Eh,09Eh,09Eh,09Ah,091h,077h,061h,05Dh,05Dh,05Dh ; 6452
                DB  09Fh,09Fh,09Fh,09Bh,095h,07Eh,072h,06Ah,06Ah,06Ah ; 645C
                DB  09Fh,09Fh,09Fh,09Bh,093h,080h,072h,06Eh,06Eh,06Eh ; 6466
                DB  0A4h,0A4h,0A0h,09Bh,099h,08Ah,07Dh,074h,074h,074h ; 6470
                DB  0A9h,0A6h,0A3h,0A1h,09Eh,08Dh,07Dh,076h,076h,076h ; 647A
                DB  0ADh,0AAh,0A9h,0A3h,09Eh,08Eh,07Eh,07Bh,07Bh,07Bh ; 6484
                DB  0B3h,0AEh,0A9h,0A1h,09Bh,08Fh,07Eh,077h,077h,077h ; 648E
                DB  0B3h,0AEh,0A7h,09Dh,097h,093h,08Fh,086h,07Bh,07Bh ; 6498
                DB  0B3h,0AEh,0A7h,0A0h,09Bh,095h,091h,086h,082h,082h ; 64A2
                DB  0B3h,0AEh,0A9h,0A7h,0A6h,0A0h,09Bh,099h,093h,093h ; 64AC
                DB  0B3h,0AEh,0A9h,0A7h,0A6h,0A0h,09Bh,099h,093h,093h ; 64B6
tbl_ign_lo_cam_alt1:       DB  055h,055h,055h,055h,055h,03Bh,01Dh,019h,011h,011h ; 64C0
                DB  074h,074h,074h,072h,06Fh,051h,033h,02Ah,022h,022h ; 64CA
                DB  085h,085h,085h,082h,077h,057h,03Bh,033h,02Fh,02Fh ; 64D4
                DB  090h,090h,090h,08Dh,07Eh,062h,048h,040h,037h,037h ; 64DE
                DB  098h,098h,098h,095h,084h,06Bh,059h,04Ch,04Ch,04Ch ; 64E8
                DB  09Eh,09Eh,09Eh,09Ah,091h,077h,061h,05Dh,05Dh,05Dh ; 64F2
                DB  09Fh,09Fh,09Fh,09Bh,095h,07Eh,072h,06Ah,06Ah,06Ah ; 64FC
                DB  09Fh,09Fh,09Fh,09Bh,093h,080h,072h,06Eh,06Eh,06Eh ; 6506
                DB  0A4h,0A4h,0A0h,09Bh,099h,08Ah,07Dh,074h,074h,074h ; 6510
                DB  0A9h,0A6h,0A3h,0A1h,09Eh,08Dh,07Dh,076h,076h,076h ; 651A
                DB  0ADh,0AAh,0A9h,0A3h,09Eh,08Eh,07Eh,07Bh,07Bh,07Bh ; 6524
tbl_ign_lo_cam_alt2:       DB  055h,055h,055h,055h,055h,03Bh,01Dh,019h ; 652E
                DB  011h,011h,074h,074h,074h,072h,06Fh,051h ; 6536
                DB  033h,02Ah,022h,022h,085h,085h,085h,082h ; 653E
                DB  077h,057h,03Bh,033h,02Fh,02Fh,090h,090h ; 6546
                DB  090h,08Dh,07Eh,062h,048h,040h,037h,037h ; 654E
                DB  098h,098h,098h,095h,084h,06Bh,059h,04Ch ; 6556
                DB  04Ch,04Ch,09Eh,09Eh,09Eh,09Ah,091h,077h ; 655E
fueltbl_range_check_tbl:       DB  061h,05Dh,05Dh,05Dh,09Fh,09Fh,09Fh,09Bh ; 6566
                DB  095h,07Eh,072h,06Ah,06Ah,06Ah,09Fh,09Fh ; 656E
                DB  09Fh,09Bh,093h,080h,072h,06Eh,06Eh,06Eh ; 6576
                DB  0A4h,0A4h,0A0h,09Bh,099h,08Ah,07Dh,074h ; 657E
                DB  074h,074h,0A9h,0A6h,0A3h,0A1h,09Eh,08Dh ; 6586
                DB  07Dh,076h,076h,076h,0ADh,0AAh,0A9h,0A3h ; 658E
                DB  09Eh,08Eh,07Eh,07Bh,07Bh,07Bh ; 6596
tbl_ign_hi_cam:       DB  08Ah,085h,080h,07Ch,062h,040h,035h,033h,02Fh,02Fh ; 659C
                DB  08Eh,089h,084h,07Ch,06Dh,046h,042h,040h,03Bh,03Bh ; 65A6
                DB  09Bh,096h,091h,088h,080h,055h,048h,042h,040h,040h ; 65B0
                DB  09Fh,09Ah,095h,08Dh,084h,062h,051h,04Bh,04Ah,04Ah ; 65BA
                DB  0ACh,0A7h,0A2h,099h,091h,073h,062h,05Eh,057h,057h ; 65C4
                DB  0B9h,0B4h,0AFh,0A2h,097h,077h,06Dh,06Bh,064h,064h ; 65CE
                DB  0D2h,0CDh,0C8h,0C0h,0AFh,088h,080h,07Ch,073h,073h ; 65D8
                DB  0E3h,0DEh,0D9h,0D1h,0AFh,0A0h,091h,08Dh,088h,088h ; 65E2
                DB  0E3h,0DEh,0D9h,0D1h,0ADh,09Eh,088h,084h,080h,080h ; 65EC
                DB  0E3h,0DEh,0D9h,0CDh,0AAh,09Bh,07Bh,073h,06Fh,06Fh ; 65F6
                DB  0E3h,0DEh,0D9h,0CDh,0A6h,099h,07Eh,077h,073h,073h ; 6600
                DB  0E3h,0DEh,0D9h,0C8h,0A0h,097h,088h,080h,080h,080h ; 660A
                DB  0E6h,0E6h,0E0h,0C4h,0A5h,09Dh,095h,08Dh,08Dh,08Dh ; 6614
                DB  0E3h,0E3h,0D5h,0C0h,0A8h,09Eh,097h,093h,08Dh,08Dh ; 661E
                DB  0DAh,0DAh,0C9h,0C0h,0A8h,0A0h,097h,093h,091h,091h ; 6628
                DB  0D5h,0D5h,0C4h,0B7h,0A4h,09Bh,095h,091h,091h,091h ; 6632
                DB  0C8h,0C8h,0B7h,0B3h,0A2h,099h,095h,093h,091h,091h ; 663C
                DB  0CAh,0CAh,0B9h,0B0h,0A2h,099h,095h,093h,091h,091h ; 6646
                DB  0B6h,0B6h,0A7h,0A0h,09Bh,099h,095h,093h,091h,091h ; 6650
                DB  0B6h,0B6h,0A7h,0A0h,09Bh,099h,095h,093h,091h,091h ; 665A
tbl_ign_hi_cam_alt1:                 DW  0a7ach           ; 6664
o2trim_add_clamp_tbl_2:       DB  0A2h,099h,091h,073h,062h,05Eh,057h,057h ; 6666
                DB  0B9h,0B4h,0AFh,0A2h,097h,077h,06Dh,06Bh ; 666E
                DB  064h,064h,0D2h,0CDh,0C8h,0C0h,0AFh,088h ; 6676
                DB  080h,07Ch,073h,073h,0E3h,0DEh,0D9h,0D1h ; 667E
                DB  0AFh,0A0h,091h,08Dh,088h,088h,0E3h,0DEh ; 6686
                DB  0D9h,0D1h,0ADh,09Eh,088h,084h,080h,080h ; 668E
                DB  0E3h,0DEh,0D9h,0CDh,0AAh,09Bh,07Bh,073h ; 6696
                DB  06Fh,06Fh,0E3h,0DEh,0D9h,0CDh,0A6h,099h ; 669E
                DB  07Eh,077h,073h,073h,0E3h,0DEh,0D9h,0C8h ; 66A6
                DB  0A0h,097h,088h,080h,080h,080h,0E6h,0E6h ; 66AE
                DB  0E0h,0C4h,0A5h,09Dh,095h,08Dh,08Dh,08Dh ; 66B6
                DB  0E3h,0E3h,0D5h,0C0h,0A8h,09Eh,097h,093h ; 66BE
                DB  08Dh,08Dh,0DAh,0DAh,0C9h,0C0h,0A8h,0A0h ; 66C6
                DB  097h,093h,091h,091h ; 66CE
tbl_ign_hi_cam_alt2:       DB  0ACh,0A7h,0A2h,099h,091h,073h,062h,05Eh,057h,057h ; 66D2
                DB  0B9h,0B4h,0AFh,0A2h,097h,077h,06Dh,06Bh,064h,064h ; 66DC
                DB  0D2h,0CDh,0C8h,0C0h,0AFh,088h,080h,07Ch,073h,073h ; 66E6
                DB  0E3h,0DEh,0D9h,0D1h,0AFh,0A0h,091h,08Dh,088h,088h ; 66F0
                DB  0E3h,0DEh,0D9h,0D1h,0ADh,09Eh,088h,084h,080h,080h ; 66FA
                DB  0E3h,0DEh,0D9h,0CDh,0AAh,09Bh,07Bh,073h,06Fh,06Fh ; 6704
                DB  0E3h,0DEh,0D9h,0CDh,0A6h,099h,07Eh,077h,073h,073h ; 670E
                DB  0E3h,0DEh,0D9h,0C8h,0A0h,097h,088h,080h,080h,080h ; 6718
                DB  0E6h,0E6h,0E0h,0C4h,0A5h,09Dh,095h,08Dh,08Dh,08Dh ; 6722
                DB  0E3h,0E3h,0D5h,0C0h,0A8h,09Eh,097h,093h,08Dh,08Dh ; 672C
                DB  0DAh,0DAh,0C9h,0C0h,0A8h,0A0h,097h,093h,091h,091h ; 6736
injector_effective_pw_skip_tbl_2:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6740
                DB  000h,000h,00Ch,013h,019h,02Dh,000h,000h,000h,000h ; 674A
                DB  000h,000h,00Ch,013h,029h,03Ch,000h,000h,000h,000h ; 6754
                DB  000h,000h,00Eh,018h,02Fh,050h,000h,000h,000h,000h ; 675E
                DB  000h,000h,010h,01Ah,033h,05Ch,000h,000h,000h,000h ; 6768
                DB  000h,000h,01Bh,025h,03Fh,060h,000h,000h,000h,000h ; 6772
                DB  000h,000h,01Eh,02Bh,04Eh,060h,000h,000h,000h,000h ; 677C
                DB  000h,000h,01Fh,030h,052h,060h,000h,000h,000h,000h ; 6786
                DB  000h,000h,020h,032h,054h,060h,000h,000h,000h,000h ; 6790
                DB  000h,000h,00Bh,010h,01Ch,020h,000h,000h,000h,000h ; 679A
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 67A4
injector_effective_pw_skip_tbl_3:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 67AE
                DB  000h,000h,00Ch,013h,019h,02Dh,000h,000h,000h,000h ; 67B8
                DB  000h,000h,00Ch,013h,029h,03Ch,000h,000h,000h,000h ; 67C2
                DB  000h,000h,00Eh,018h,02Fh,050h,000h,000h,000h,000h ; 67CC
                DB  000h,000h,010h,01Ah,033h,05Ch,000h,000h,000h,000h ; 67D6
                DB  000h,000h,01Bh,025h,03Fh,060h,000h,000h,000h,000h ; 67E0
                DB  000h,000h,01Eh,02Bh,04Eh,060h,000h,000h,000h,000h ; 67EA
                DB  000h,000h,01Fh,030h,052h,060h,000h,000h,000h,000h ; 67F4
                DB  000h,000h,020h,032h,054h,060h,000h,000h,000h,000h ; 67FE
                DB  000h,000h,00Bh,010h,01Ch,020h,000h,000h,000h,000h ; 6808
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6812
tbl_zero_681c:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 681C
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6826
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6830
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 683A
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6844
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 684E
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6858
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6862
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 686C
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6876
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6880
tbl_zero_688a:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 688A
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6894
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 689E
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68A8
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68B2
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68BC
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68C6
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68D0
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68DA
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68E4
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68EE
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 68F8
idle_temp_hyst3_tbl_4:       DB  0FFh,000h,03Ch,0A0h,000h,03Ch,080h,000h ; 6902
                DB  022h,040h,000h,00Ah,000h,000h,00Ah ; 690A
tbl_inj_pw_volt_6911:       DB  0FFh,098h,0E0h,098h,0D0h,080h,0C0h,073h ; 6911
                DB  0A0h,073h,080h,066h,040h,066h,000h,066h ; 6919
tbl_dw_6921:                 DW  05858h           ; 6921
tbl_allff_6923:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6923
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 692D
tbl_allff_6937:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6937
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6941
rpm_accel_clamp_tbl:       DB  0FFh,056h,000h,0A0h,056h,000h,080h,056h ; 694B
                DB  000h,06Dh,074h,000h,060h,093h,000h,040h ; 6953
                DB  0AFh,000h,000h,0AFh,000h,0FFh,0FFh,0FFh ; 695B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6963
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 696B
                DB  0FFh ; 6973
tipin_decay_zero_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6974
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 697E
scale_result_common_tbl:       DB  000h,000h,004h,00Ah,015h,01Eh,022h,037h,048h,04Ch ; 6988
                DB  051h,057h,05Eh,06Ah,077h,084h,084h,080h,075h,075h ; 6992
                DB  000h,000h,000h,000h,000h,000h,000h,001h,008h,011h ; 699C
                DB  01Ah,022h,02Fh,03Ah,040h,045h,04Ch,05Eh,07Bh,07Bh ; 69A6
ign_p40_toggle_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69B0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69B8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69C0
tbl_cfg_69c6:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69C6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,022h,06Eh,022h ; 69CE
                DB  044h,022h,028h,022h,000h,022h,0FFh,000h ; 69D6
                DB  087h,000h,057h,011h,013h,019h,000h,019h ; 69DE
overrev_hardcap_compare_tbl_4:       DB  0FFh,060h,0D0h,060h,0BAh,060h,087h,060h ; 69E6
                DB  02Eh,050h,028h,040h,000h,040h ; 69EE
idle_temp_hyst3_tbl_5:       DB  0FFh,006h,0EDh,006h,094h,006h,062h,006h ; 69F4
                DB  044h,006h,02Eh,019h,000h,019h ; 69FC
scale_result_common_tbl_2:       DB  024h,024h,024h,022h,031h,027h,026h,022h,028h,01Bh ; 6A02
                DB  017h,017h,022h,02Ah,022h,019h,01Dh,01Dh,01Dh,01Dh ; 6A0C
scale_result_common_tbl_3:       DB  000h,000h,000h,000h,011h,019h,022h,01Bh,020h,028h ; 6A16
                DB  028h,035h,02Ch,028h,024h,026h,024h,026h,01Dh,01Dh ; 6A20
Cranking_tbl:       DB  0FFh,0FFh,080h,000h,000h,031h,080h,000h ; 6A2A
                DB  04Fh,012h,053h,000h,000h,000h,053h,000h ; 6A32
injector_effective_pw_skip_tbl_6:       DB  0FFh,000h,0B0h,000h,0A0h,070h,060h,070h ; 6A3A
                DB  040h,070h,000h,000h ; 6A42
tbl_knock_6a46:       DB  066h,073h,08Ch,099h,080h ; 6A46
sensor_bank_gate3_tbl_4:       DB  0B3h,000h,0A9h,080h ; 6A4B
tbl_6a4f:       DB  008h,005h,004h,004h,006h,009h,009h,009h,005h,009h ; 6A4F
                DB  00Bh,00Ah,009h,005h,00Ah,007h,007h,005h,00Eh,018h ; 6A59
tbl_6a63:       DB  034h,034h,034h,034h,034h,034h,034h,026h,028h,028h ; 6A63
                DB  024h,024h,01Bh,012h,00Ah,00Bh,00Eh,012h,016h,016h ; 6A6D
tbl_corr_map_lo_6a77:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6A77
                DB  080h,080h,080h,080h,080h,080h,080h,085h,086h,086h ; 6A81
tbl_corr_map_hi_6a8b:       DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h ; 6A8B
                DB  080h,080h,080h,080h,083h,088h,088h,084h,086h,086h ; 6A95
tbl_knock_retard_6a9f:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6A9F
                DB  0FFh,0FFh,000h,000h,0FFh,0FFh,0FFh,0FFh ; 6AA7
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,000h,000h ; 6AAF
tbl_knock_ptr_6ab7:       DB  039h,005h,0A9h,005h,018h,006h,088h,006h ; 6AB7
                DB  0F7h,006h,000h,000h,018h,006h,088h,006h ; 6ABF
                DB  0F7h,006h,067h,007h,0D6h,007h,000h,000h ; 6AC7
int_serial_tbl:       DB  0C1h,003h,0C0h,003h,080h,04Fh,0FFh,0FFh ; 6ACF
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6AD7
                DB  0C4h,003h,0C5h,003h,0FFh,0FFh,0C6h,003h ; 6ADF
                DB  0C7h,003h,0C8h,003h,0FFh,0FFh,0C9h,003h ; 6AE7
                DB  0DAh,003h,0D2h,003h,075h,000h,0D3h,003h ; 6AEF
                DB  077h,000h,0D0h,003h,0FFh,0FFh,0D7h,003h ; 6AF7
                DB  06Dh,000h,0D8h,003h,073h,000h,06Fh,000h ; 6AFF
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6B07
                DB  061h,001h,0FFh,0FFh,009h,003h,0FFh,0FFh ; 6B0F
                DB  0C3h,003h,0C2h,003h,082h,002h,043h,04Ch ; 6B17
                DB  02Ch,04Ch,071h,000h,03Bh,04Ch,094h,002h ; 6B1F
                DB  091h,002h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6B27
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6B2F
                DB  0FFh,0FFh,0A1h,001h,0A2h,001h,0A0h,001h ; 6B37
                DB  0A9h,001h,0AAh,001h,0A8h,001h,0F8h,000h ; 6B3F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6B47
                DB  070h,04Eh,049h,003h,04Ah,003h,04Bh,003h ; 6B4F
                DB  04Ch,003h,04Dh,003h,04Eh,003h,04Fh,003h ; 6B57
                DB  050h,003h,051h,003h,052h,003h,053h,003h ; 6B5F
                DB  054h,003h,055h,003h,056h,003h,057h,003h ; 6B67
                DB  058h,003h,059h,003h,05Ah,003h,05Bh,003h ; 6B6F
                DB  05Ch,003h,05Dh,003h,0FFh,0FFh,0FFh,0FFh ; 6B77
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6B7F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6B87
                DB  038h,003h,039h,003h,03Ah,003h,03Bh,003h ; 6B8F
                DB  03Ch,003h,03Dh,003h,03Eh,003h,03Fh,003h ; 6B97
                DB  040h,003h,041h,003h,042h,003h,043h,003h ; 6B9F
                DB  044h,003h,045h,003h,046h,003h,047h,003h ; 6BA7
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6BAF
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6BB7
                DB  090h,04Eh,054h,06Dh,04Bh,04Ch,056h,04Ch ; 6BBF
                DB  025h,04Ch,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6BC7
int_serial_tbl_2:       DB  001h,001h,000h,0FFh,0FFh,0FFh,0FFh,0FFh ; 6BCF
                DB  001h,001h,0FFh,001h,001h,001h,0FFh,001h ; 6BD7
                DB  001h,001h,001h,001h,001h,001h,0FFh,001h ; 6BDF
                DB  001h,001h,001h,001h,0FFh,0FFh,0FFh,0FFh ; 6BE7
                DB  001h,0FFh,001h,0FFh,001h,001h,001h,000h ; 6BEF
                DB  000h,001h,000h,001h,001h,0FFh,0FFh,0FFh ; 6BF7
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,001h,001h,001h ; 6BFF
                DB  001h,001h,001h,001h,0FFh,0FFh,0FFh,0FFh ; 6C07
                DB  000h,001h,001h,001h,001h,001h,001h,001h ; 6C0F
                DB  001h,0FFh,001h,001h,001h,0FFh,0FFh,001h ; 6C17
                DB  0FFh,001h,001h,0FFh,001h,001h,0FFh,0FFh ; 6C1F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C27
                DB  001h,001h,001h,001h,001h,001h,001h,001h ; 6C2F
                DB  001h,001h,001h,001h,001h,001h,001h,001h ; 6C37
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C3F
                DB  000h,002h,000h,000h,000h,0FFh,0FFh,0FFh ; 6C47
idle_init_start_tbl:       DB  014h,002h,024h,001h,02Ch,0A2h,024h,011h ; 6C4F
                DB  024h,051h,000h,000h,000h,000h,025h,0C1h ; 6C57
idle_init_start_tbl_2:       DB  000h,000h,000h,000h,000h,000h,024h,021h ; 6C5F
                DB  029h,082h,029h,0A2h,024h,0B1h,000h,000h ; 6C67
idle_init_start_tbl_3:       DB  025h,012h,025h,002h,025h,072h,025h,062h ; 6C6F
                DB  000h,000h,026h,032h,025h,0A0h,000h,000h ; 6C77
idle_init_start_tbl_4:       DB  025h,032h,025h,022h,025h,042h,01Ah,012h ; 6C7F
                DB  000h,000h,026h,022h,026h,052h,000h,000h ; 6C87
idle_init_start_tbl_5:       DB  025h,052h,000h,000h,000h,000h,000h,000h ; 6C8F
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6C97
idle_init_start_tbl_6:       DB  01Bh,002h,000h,000h,000h,000h,000h,000h ; 6C9F
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6CA7
dtc_active_confirm_tbl_2:       DB  094h,045h,04Fh,046h,09Eh,045h,0A9h,045h,041h,046h ; 6CAF
                DB  0B2h,045h,0BDh,045h,0C7h,045h,0D4h,045h,0DCh,045h ; 6CB9
                DB  04Fh,046h,0E6h,045h,0FAh,045h,041h,046h,041h,046h ; 6CC3
                DB  041h,046h,041h,046h,04Fh,046h,04Fh,046h,004h,046h ; 6CCD
                DB  041h,046h,041h,046h,041h,046h,00Eh,046h,011h,046h ; 6CD7
                DB  015h,046h,021h,046h,04Fh,046h,025h,046h,031h,046h ; 6CE1
                DB  039h,046h,04Fh,046h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6CEB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6CF5
clamp_result_store_tbl_2:       DB  000h,000h,000h,000h,000h,020h,008h,004h ; 6CFF
                DB  001h,004h,00Ch,000h,001h,008h,00Ch,000h ; 6D07
                DB  001h,002h,00Ch,000h,002h,001h,00Ch,003h ; 6D0F
                DB  002h,001h,01Ch,003h,003h,004h,00Ch,002h ; 6D17
                DB  003h,008h,00Ch,002h,003h,002h,00Ch,002h ; 6D1F
                DB  003h,020h,008h,004h,004h,001h,00Ch,000h ; 6D27
                DB  000h,001h,004h,000h,000h,001h,014h,000h ; 6D2F
                DB  000h,001h,004h,000h,000h,001h,00Ch,002h ; 6D37
                DB  000h,001h,01Ch,002h,000h,001h,004h,000h ; 6D3F
                DB  002h,004h,00Ch,003h,002h,008h,00Ch,003h ; 6D47
                DB  002h,020h,008h,005h,003h,093h,0F0h ; 6D4F
clamp_result_store_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D56
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D5E
                DB  0FFh,012h,013h,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D66
                DB  0FFh,0FFh ; 6D6E
to_set_pswl4_flag_b_sub_call_4880:     CAL     o2_trim_dp300_read_sub_clear_x1             ; 6D70 1 100 280 328048
                LB      A, #041h               ; 6D73 0 100 280 7741
                JBS     off(0012fh).7, to_set_pswl4_flag_b_sub_cmp_ram0df ; 6D75 0 100 280 EF2F02
                LB      A, #03eh               ; 6D78 0 100 280 773E
to_set_pswl4_flag_b_sub_cmp_ram0df:     CMPB    0dfh, A                ; 6D7A 0 100 280 C5DFC1
                MB      off(0012fh).7, C       ; 6D7D 0 100 280 C42F3F
                RT                             ; 6D80 0 100 280 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D81
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D89
to_set_pswl4_flag_b_sub_if_ram11f_bit3_clr:     JBR     off(0011fh).3, to_set_pswl4_flag_b_sub_cmp_acc ; 6D90 0 100 280 DB1F0B
                MOV     er2, #0ffffh           ; 6D93 0 100 280 4698FFFF
                JBS     off(00120h).0, to_set_pswl4_flag_b_sub_cmp_acc ; 6D97 0 100 280 E82004
                MOV     er2, #006f7h           ; 6D9A 0 100 280 4698F706
to_set_pswl4_flag_b_sub_cmp_acc:     CMPB    A, off(00178h)         ; 6D9E 0 100 280 C778
                JGT     to_set_pswl4_flag_b_sub_goto_4775             ; 6DA0 0 100 280 C803
                J       to_set_pswl4_flag_b_sub_load_er2             ; 6DA2 0 100 280 036F47
to_set_pswl4_flag_b_sub_goto_4775:     J       to_set_pswl4_flag_b_sub_load_ram166             ; 6DA5 0 100 280 037547
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DA8
to_set_pswl4_flag_b_sub_cmp_r0:     CMPB    r0, off(00179h)        ; 6DB0 1 100 280 20C379
                JGT     to_set_pswl4_flag_b_sub_goto_4775_2             ; 6DB3 1 100 280 C806
                JBS     off(0012fh).7, to_set_pswl4_flag_b_sub_goto_4775_2 ; 6DB5 1 100 280 EF2F03
                J       o2trim_add_clamp             ; 6DB8 1 100 280 037F47
to_set_pswl4_flag_b_sub_goto_4775_2:     J       to_set_pswl4_flag_b_sub_load_ram166             ; 6DBB 1 100 280 037547
                DW  0ffffh           ; 6DBE
knockretard_store_if_lt_goto_6dca:     JLT     knockretard_store_goto_2419             ; 6DC0 0 200 180 CA08
                CMPB    r0, #000h              ; 6DC2 0 200 180 20C000
                JEQ     knockretard_store_goto_2419             ; 6DC5 0 200 180 C903
                J       knockretard_store_goto_6e90             ; 6DC7 0 200 180 031024
knockretard_store_goto_2419:     J       knockretard_store_store_ram2ae             ; 6DCA 0 200 180 031924
                DB  0FFh,0FFh,0FFh ; 6DCD
sensor_bank_gate3_if_ram216_bit1_set:     JBS     off(00216h).1, sensor_bank_gate3_goto_16b7 ; 6DD0 0 208 180 E91620
                LB      A, #005h               ; 6DD3 0 208 180 7705
                CMPB    A, 0dfh                ; 6DD5 0 208 180 C5DFC2
                JGE     sensor_bank_gate3_goto_16a8             ; 6DD8 0 208 180 CD16
                MOV     X1, #053dbh            ; 6DDA 0 208 180 60DB53
                JBS     off(0021dh).1, sensor_bank_gate3_load_ram289 ; 6DDD 0 208 180 E91D03
                MOV     X1, #053cfh            ; 6DE0 0 208 180 60CF53
sensor_bank_gate3_load_ram289:     LB      A, off(00289h)         ; 6DE3 0 208 180 F489
                VCAL    0                      ; 6DE5 0 208 180 10
                ADDB    A, #020h               ; 6DE6 0 208 180 8620
                JGE     sensor_bank_gate3_cmp_acc_3             ; 6DE8 0 208 180 CD02
                LB      A, #0ffh               ; 6DEA 0 208 180 77FF
sensor_bank_gate3_cmp_acc_3:     CMPB    A, off(00288h)         ; 6DEC 0 208 180 C788
                JGE     sensor_bank_gate3_goto_16b7             ; 6DEE 0 208 180 CD03
sensor_bank_gate3_goto_16a8:     J       sensor_bank_gate3_load_imm             ; 6DF0 0 208 180 03A816
sensor_bank_gate3_goto_16b7:     J       sensor_bank_gate3_clear_carry             ; 6DF3 0 208 180 03B716
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DF6
                DB  0FFh,0FFh ; 6DFE
vtec_state_store_set_carry:     SC                             ; 6E00 0 100 280 85
                LB      A, off(001b4h)         ; 6E01 0 100 280 F4B4
                JNE     vtec_state_store_store_carry_ram11d_bit2             ; 6E03 0 100 280 CE01
                RC                             ; 6E05 0 100 280 95
vtec_state_store_store_carry_ram11d_bit2:     MB      off(0011dh).2, C       ; 6E06 0 100 280 C41D3A
                LB      A, 0efh                ; 6E09 0 100 280 F5EF
                MOV     DP, #tbl_6a63          ; 6E0B 0 100 280 62636A
                J       vtec_state_store_load_x1             ; 6E0E 0 100 280 034D29
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E11
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E19
knockretard_store_if_ram216_bit5_clr:     JBR     off(00216h).5, knockretard_store_goto_2457 ; 6E20 0 200 180 DD1606
                JBS     off(0021dh).2, knockretard_store_goto_2457 ; 6E23 0 200 180 EA1D03
                J       knockretard_store_clear_acc             ; 6E26 0 200 180 033D24
knockretard_store_goto_2457:     J       knockretard_store_store_ram2b0             ; 6E29 0 200 180 035724
                DB  0FFh,0FFh,0FFh,0FFh ; 6E2C
overrev_hardcap_compare_if_ram216_bit6_set:     JBS     off(00216h).6, overrev_hardcap_compare_goto_1314 ; 6E30 0 208 180 EE1606
                JBS     off(0021dh).2, overrev_hardcap_compare_goto_1314 ; 6E33 0 208 180 EA1D03
                J       overrev_hardcap_compare_cmp_ram2ce             ; 6E36 0 208 180 030113
overrev_hardcap_compare_goto_1314:     J       overrev_hardcap_compare_load_ram2ce             ; 6E39 0 208 180 031413
                DB  0FFh,0FFh,0FFh,0FFh ; 6E3C
knockretard_store_if_ram21d_bit2_clr:     JBR     off(0021dh).2, knockretard_store_goto_23d8 ; 6E40 0 200 180 DA1D06
                RB      off(00230h).5          ; 6E43 0 200 180 C4300D
                J       knockretard_store_goto_4f3e             ; 6E46 0 200 180 03F823
knockretard_store_goto_23d8:     J       knockretard_store_load_ram289             ; 6E49 0 200 180 03D823
                DB  0FFh,0FFh,0FFh,0FFh ; 6E4C
sensor_bank_gate3_clear_acc:     CLR     A                      ; 6E50 1 208 180 F9
                CMPB    off(00295h), off(00289h) ; 6E51 1 208 180 C495C389
                JLE     sensor_bank_gate3_if_ram230_bit4_clr             ; 6E55 1 208 180 CF03
                JBS     off(00224h).2, sensor_bank_gate3_goto_162b ; 6E57 1 208 180 EA2406
sensor_bank_gate3_if_ram230_bit4_clr:     JBR     off(00230h).4, sensor_bank_gate3_goto_162b ; 6E5A 1 208 180 DC3003
                J       sensor_bank_gate3_if_ram211_bit1_set             ; 6E5D 1 208 180 031716
sensor_bank_gate3_goto_162b:     J       sensor_bank_gate3_store_ram280             ; 6E60 1 208 180 032B16
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E63
                DB  0FFh,0FFh,0FFh,0FFh,0FFh ; 6E6B
fuelcuttrack_store_sub_load_x1:     MOV     X1, #fuelcuttrack_store_tbl_2          ; 6E70 0 100 280 602758
                JBS     off(0011dh).1, fuelcuttrack_store_sub_return ; 6E73 0 100 280 E91D03
                MOV     X1, #fuelcuttrack_store_tbl          ; 6E76 0 100 280 601758
fuelcuttrack_store_sub_return:     RT                             ; 6E79 0 100 280 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E7A
knockretard_store_addb_acc:     ADDB    A, off(00281h)         ; 6E80 0 200 180 8781
                JLT     knockretard_store_load_imm_3             ; 6E82 0 200 180 CA04
                SRAB    A                      ; 6E84 0 200 180 73
                ROLB    A                      ; 6E85 0 200 180 33
                JGE     knockretard_store_vcal_7_2             ; 6E86 0 200 180 CD02
knockretard_store_load_imm_3:     LB      A, #07fh               ; 6E88 0 200 180 777F
knockretard_store_vcal_7_2:     VCAL    7                      ; 6E8A 0 200 180 17
                J       knockretard_store_store_ram2ae             ; 6E8B 0 200 180 031924
                DW  0ffffh           ; 6E8E
knockretard_store_clear_ram230_bit5:     RB      off(00230h).5          ; 6E90 0 200 180 C4300D
                LB      A, #004h               ; 6E93 0 200 180 7704
                MB      C, (00128h-00180h)[USP].1 ; 6E95 0 200 180 C3A829
                JLT     knockretard_store_store_ram29c             ; 6E98 0 200 180 CA17
                LB      A, #007h               ; 6E9A 0 200 180 7707
                JBS     off(0021ah).6, knockretard_store_store_ram29c ; 6E9C 0 200 180 EE1A12
                LB      A, #009h               ; 6E9F 0 200 180 7709
                CMPB    off(00289h), #098h     ; 6EA1 0 200 180 C489C098
                JGE     knockretard_store_store_ram29c             ; 6EA5 0 200 180 CD0A
                LB      A, #005h               ; 6EA7 0 200 180 7705
                CMPB    off(00289h), #050h     ; 6EA9 0 200 180 C489C050
                JGE     knockretard_store_store_ram29c             ; 6EAD 0 200 180 CD02
                LB      A, #003h               ; 6EAF 0 200 180 7703
knockretard_store_store_ram29c:     STB     A, off(0029ch)         ; 6EB1 0 200 180 D49C
                J       knockretard_store_load_r0             ; 6EB3 0 200 180 031724
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EB6
                DB  0FFh,0FFh ; 6EBE
knock_div_calc4_if_ram21d_bit0_set:     JBS     off(0021dh).0, knock_div_calc4_goto_1a9c ; 6EC0 0 208 180 E81D03
                JBR     off(0021dh).2, knock_div_calc4_goto_1aa2 ; 6EC3 0 208 180 DA1D03
knock_div_calc4_goto_1a9c:     J       knock_div_calc4_load_imm             ; 6EC6 0 208 180 039C1A
knock_div_calc4_goto_1aa2:     J       knock_div_calc4_load_ram2ed             ; 6EC9 0 208 180 03A21A
                DB  0FFh,0FFh,0FFh,0FFh ; 6ECC
transit_flag_common_sub_load_dp:     MOV     DP, #00348h            ; 6ED0 0 208 180 624803
                SB      off(00232h).6          ; 6ED3 0 208 180 C4321E
                RT                             ; 6ED6 0 208 180 01
transit_flag_common_clear_ram232_bit6:     RB      off(00232h).6          ; 6ED7 0 208 180 C4320E
                J       transit_flag_common_return             ; 6EDA 0 208 180 032C3B
int_break_set_ram232_bit6:     SB      off(00232h).6          ; 6EDD 1 208 ??? C4321E
                JNE     int_break_goto_08f6             ; 6EE0 1 208 ??? CE06
                MOV     DP, #00332h            ; 6EE2 1 208 ??? 623203
                J       int_break_clear_dp_ind             ; 6EE5 1 208 ??? 03E308
int_break_goto_08f6:     J       int_break_load_dp_2             ; 6EE8 1 208 ??? 03F608
int_break_sub_clear_ram232_bit6:     RB      off(00232h).6          ; 6EEB 1 208 ??? C4320E
                MOV     LRB, #00011h           ; 6EEE 1 088 ??? 571100
                RT                             ; 6EF1 1 088 ??? 01
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EF2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EFA
dtc_active_confirm_vcal_4:     VCAL    4                      ; 6F00 1 208 180 14
                MOV     DP, #00334h            ; 6F01 1 208 180 623403
                J       dtc_active_confirm_load_x1             ; 6F04 1 208 180 03071E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F07
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F0F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F17
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F1F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F27
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F2F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F37
                DB  0FFh ; 6F3F
injector_effective_pw_skip_if_ram11a_bit1_clr:     JBR     off(0011ah).1, injector_effective_pw_skip_if_ram11d_bit0_clr ; 6F40 0 100 280 D91A03
                J       injector_effective_pw_skip_subb_acc             ; 6F43 0 100 280 03BD35
injector_effective_pw_skip_if_ram11d_bit0_clr:     JBR     off(0011dh).0, injector_effective_pw_skip_goto_35c2 ; 6F46 0 100 280 D81D06
                ADDB    A, #020h               ; 6F49 0 100 280 8620
                JGE     injector_effective_pw_skip_goto_35c2             ; 6F4B 0 100 280 CD02
                LB      A, #0ffh               ; 6F4D 0 100 280 77FF
injector_effective_pw_skip_goto_35c2:     J       injector_effective_pw_skip_cmp_acc_8             ; 6F4F 0 100 280 03C235
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F52
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F5A
vss_clamp_common_load_ram210:     L       A, off(00210h)         ; 6F60 1 208 180 E410
                JNE     vss_clamp_common_goto_37d5             ; 6F62 1 208 180 CE0A
                L       A, off(00212h)         ; 6F64 1 208 180 E412
                AND     A, #074fdh                         ; 6F66 1 208 180 D6FD74
                JNE     vss_clamp_common_goto_37d5             ; 6F69 1 208 180 CE03
                J       vss_clamp_common_cmp_ram0d9             ; 6F6B 1 208 180 030238
vss_clamp_common_goto_37d5:     J       vss_clamp_common_clear_ram229_bit4             ; 6F6E 1 208 180 03D537
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F71
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F79
injector_effective_pw_skip_if_ram121_bit0_set:     JBS     off(00121h).0, injector_effective_pw_skip_if_ram112_bit5_clr ; 6F80 0 100 280 E82103
                J       injector_effective_pw_skip_andb_r0             ; 6F83 0 100 280 030236
injector_effective_pw_skip_if_ram112_bit5_clr:     JBR     off(00112h).5, injector_effective_pw_skip_goto_35db ; 6F86 0 100 280 DD1203
                JBS     off(0012eh).7, injector_effective_pw_skip_set_ram11d_bit1_2 ; 6F89 0 100 280 EF2E03
injector_effective_pw_skip_goto_35db:     J       injector_effective_pw_skip_load_ram110             ; 6F8C 0 100 280 03DB35
injector_effective_pw_skip_set_ram11d_bit1_2:     SB      off(0011dh).1          ; 6F8F 0 100 280 C41D19
                RB      off(0011ah).1          ; 6F92 0 100 280 C41A09
                J       injector_effective_pw_skip_load_dp             ; 6F95 0 100 280 034236
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F98
vemapscalar_gate_if_ram212_bit5_set:     JBS     off(00212h).5, vemapscalar_gate_goto_153e ; 6FA0 1 208 180 ED1206
                JBR     off(0021dh).1, vemapscalar_gate_goto_153e ; 6FA3 1 208 180 D91D03
                J       vemapscalar_gate_call_add24_clamp_neg1             ; 6FA6 1 208 180 034415
vemapscalar_gate_goto_153e:     J       vemapscalar_gate_load_x1             ; 6FA9 1 208 180 033E15
vemapscalar_gate_if_ram212_bit5_set_2:     JBS     off(00212h).5, vemapscalar_gate_goto_156c ; 6FAC 1 208 180 ED1206
                JBR     off(0021dh).1, vemapscalar_gate_goto_156c ; 6FAF 1 208 180 D91D03
                J       vemapscalar_gate_call_4977             ; 6FB2 1 208 180 037215
vemapscalar_gate_goto_156c:     J       vemapscalar_gate_load_x1_2             ; 6FB5 1 208 180 036C15
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FB8
calchecksum_loop_sub_div_acc:     DIV                            ; 6FC0 1 208 180 9037
                DIV                            ; 6FC2 1 208 180 9037
                J       calchecksum_loop_sub_load_dp             ; 6FC4 1 208 180 03CA4A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FC7
                DB  0FFh ; 6FCF
crank_sync_flag_high_if_ram111_bit0_clr:     JBR     off(00111h).0, crank_sync_flag_high_goto_02b0 ; 6FD0 0 108 280 D81106
                RB      off(0011ah).7          ; 6FD3 0 108 280 C41A0F
                J       crank_sync_flag_high_load_ram13c             ; 6FD6 0 108 280 03B502
crank_sync_flag_high_goto_02b0:     J       crank_sync_flag_high_clear_trnsit_bit6             ; 6FD9 0 108 280 03B002
                DB  0FFh,0FFh,0FFh,0FFh ; 6FDC
ofc_enable_check_load_ram1f3:     LB      A, off(001f3h)         ; 6FE0 0 100 280 F4F3
                JEQ     ofc_enable_check_goto_2f03             ; 6FE2 0 100 280 C906
                SB      off(0011bh).3          ; 6FE4 0 100 280 C41B1B
                J       fuelcuttrack_store_clear_pswl_bit4             ; 6FE7 0 100 280 03DD2E
ofc_enable_check_goto_2f03:     J       revlimiter_fuelcut_set_if_ram12d_bit7_set             ; 6FEA 0 100 280 03032F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FF5
                DB  0FFh,0FFh,0FFh ; 6FFD
tipin_gate_common_if_ram130_bit6_set:       JBS     off(00130h).6, tipin_gate_common_goto_2c96 ; 7000 0 100 280 EE3003
                JBS     off(00130h).4, tipin_gate_common_goto_2ca8 ; 7003 0 100 280 EC3003
tipin_gate_common_goto_2c96:     J       tipin_gate_common_if_ram11c_bit6_set             ; 7006 0 100 280 03962C
tipin_gate_common_goto_2ca8:     J       tipin_gate_common_set_ram131_bit0             ; 7009 0 100 280 03A82C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 700C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7014
                DB  0FFh,0FFh,0FFh,0FFh ; 701C
warmcold_tm2_check_set_ram09f_bit4:     SB      09fh.4                 ; 7020 0 208 180 C59F1C
                RB      09bh.2                 ; 7023 0 208 180 C59B0A
                J       warmcold_tm2_check_store_ram294             ; 7026 0 208 180 03FE10
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7029
idle_temp_hyst3_cmp_ram298:     CMPB    off(00298h), #000h     ; 7030 1 208 180 C498C000
                JEQ     idle_temp_hyst3_sra_acc             ; 7034 1 208 180 C908
                J       idle_temp_hyst3_add_acc             ; 7036 1 208 180 035E3C
idle_temp_hyst3_decb_ram298:     DECB    off(00298h)            ; 7039 1 208 180 C49817
                JLT     idle_temp_hyst3_load_imm_5             ; 703C 1 208 180 CA04
idle_temp_hyst3_sra_acc:     SRA     A                      ; 703E 1 208 180 73
                ROL     A                      ; 703F 1 208 180 33
                JGE     idle_temp_hyst3_goto_3c64             ; 7040 1 208 180 CD03
idle_temp_hyst3_load_imm_5:     L       A, #07fffh             ; 7042 1 208 180 67FF7F
idle_temp_hyst3_goto_3c64:     J       idle_temp_hyst3_store_ram284             ; 7045 1 208 180 03643C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7048
                DB  0FFh,0FFh,0FFh ; 7050
idle_temp_hyst3_load_er1:     L       A, er1                 ; 7053 1 208 180 35
                JLT     idle_temp_hyst3_load_imm_6             ; 7054 1 208 180 CA09
                J       idle_temp_hyst3_add_acc_2             ; 7056 1 208 180 033240
idle_temp_hyst3_if_lt_goto_705f:     JLT     idle_temp_hyst3_load_imm_6             ; 7059 1 208 180 CA04
                SRA     A                      ; 705B 1 208 180 73
                ROL     A                      ; 705C 1 208 180 33
                JGE     idle_temp_hyst3_goto_403a             ; 705D 1 208 180 CD03
idle_temp_hyst3_load_imm_6:     L       A, #07fffh             ; 705F 1 208 180 67FF7F
idle_temp_hyst3_goto_403a:     J       idle_temp_hyst3_load_x1_5             ; 7062 1 208 180 033A40
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7065
                DB  0FFh,0FFh,0FFh ; 706D
overrev_hardcap_compare_if_ram212_bit0_set:     JBS     off(00212h).0, overrev_hardcap_compare_goto_144c ; 7070 1 208 180 E81208
                MB      C, 098h.1              ; 7073 1 208 180 C59829
                JLT     overrev_hardcap_compare_goto_144c             ; 7076 1 208 180 CA03
                J       overrev_hardcap_compare_if_ram216_bit1_set             ; 7078 1 208 180 031A14
overrev_hardcap_compare_goto_144c:     J       overrev_hardcap_compare_set_ram216_bit2             ; 707B 1 208 180 034C14
                DW  0ffffh           ; 707E
int_crank_task_if_ram110_bit7_clr:     JBR     off(00110h).7, int_crank_task_goto_024b ; 7080 1 108 280 DF1006
                SB      off(00127h).4          ; 7083 1 108 280 C4271C
                J       int_crank_task_load_ram0bc_2             ; 7086 1 108 280 035502
int_crank_task_goto_024b:     J       int_crank_task_clear_trnsit_bit7             ; 7089 1 108 280 034B02
                DB  0FFh,0FFh,0FFh,0FFh ; 708C
tipin_gate_common_sub_store_carry_ram11d_bit5:     MB      off(0011dh).5, C       ; 7090 0 100 280 C41D3D
                JBS     off(0011fh).5, tipin_gate_common_sub_store_carry_ram11c_bit5 ; 7093 0 100 280 ED1F03
                MB      C, off(0011ch).4       ; 7096 0 100 280 C41C2C
tipin_gate_common_sub_store_carry_ram11c_bit5:     MB      off(0011ch).5, C       ; 7099 0 100 280 C41C3D
                RT                             ; 709C 0 100 280 01
                DB  0FFh,0FFh,0FFh ; 709D
idle_temp_hyst3_sub_add_acc:     ADD     A, off(00248h)         ; 70A0 1 208 180 8748
                SRA     A                      ; 70A2 1 208 180 73
                ROL     A                      ; 70A3 1 208 180 33
                JGE     idle_temp_hyst3_sub_store_er2             ; 70A4 1 208 180 CD03
                L       A, #07fffh             ; 70A6 1 208 180 67FF7F
idle_temp_hyst3_sub_store_er2:     ST      A, er2                 ; 70A9 1 208 180 8A
                RT                             ; 70AA 1 208 180 01
idle_temp_hyst3_if_ge_goto_70b0:     JGE     idle_temp_hyst3_vcal_7             ; 70AB 1 208 180 CD03
                L       A, #07fffh             ; 70AD 1 208 180 67FF7F
idle_temp_hyst3_vcal_7:     VCAL    7                      ; 70B0 1 208 180 17
                ST      A, er2                 ; 70B1 1 208 180 8A
                J       idle_temp_hyst3_load_ram244             ; 70B2 1 208 180 03BB3C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 70B5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 70BD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 70C5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 70CD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 70D5
                DB  0FFh,0FFh,0FFh ; 70DD
rpm_decel_limit_check_if_ram230_bit1_set:     JBS     off(00230h).1, rpm_decel_limit_check_goto_20dc ; 70E0 0 200 180 E93009
                RC                             ; 70E3 0 200 180 95
                LB      A, off(002bah)         ; 70E4 0 200 180 F4BA
                JEQ     rpm_decel_limit_check_goto_20dc             ; 70E6 0 200 180 C904
                CMPCB   A, 020d9h              ; 70E8 0 200 180 909FD920
rpm_decel_limit_check_goto_20dc:     J       rpm_decel_limit_check_store_carry_ram223_bit5             ; 70EC 0 200 180 03DC20
                DB  0FFh ; 70EF
crankfuel_clamp_max_clear_x1:     CLR     X1                     ; 70F0 0 108 280 9015
                MOVB    r1, #004h              ; 70F2 0 108 280 9904
                RB      TRNSIT.3                 ; 70F4 0 108 280 C5290B
                J       crankfuel_clamp_max_srlb_r0             ; 70F7 0 108 280 032605
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 70FA
vss_ect_gate_load_r4:     MOVB    r4, #032h              ; 7100 0 208 180 9C32
                JBR     off(0021bh).1, vss_ect_gate_load_ram2f1 ; 7102 0 208 180 D91B06
                JBR     off(00217h).0, vss_ect_gate_load_ram2f1 ; 7105 0 208 180 D81703
                J       vss_ect_gate_load_ram2d6             ; 7108 0 208 180 039C17
vss_ect_gate_load_ram2f1:     MOVB    off(002f1h), r4        ; 710B 0 208 180 247CF1
                J       idle_stage_alt_start             ; 710E 0 208 180 03C017
vss_ect_gate_if_ram218_bit0_clr:     JBR     off(00218h).0, vss_ect_gate_load_ram2f1_2 ; 7111 0 208 180 D81803
                J       vss_ect_gate_goto_711d             ; 7114 0 208 180 03A517
vss_ect_gate_load_ram2f1_2:     MOVB    off(002f1h), r4        ; 7117 0 208 180 247CF1
                J       vss_ect_gate_load_ram2d3             ; 711A 0 208 180 03B717
vss_ect_gate_load_stk:     L       A, (00160h-00180h)[USP] ; 711D 1 208 180 E3E0
                CMPC    A, 017a8h              ; 711F 1 208 180 909EA817
                JGE     vss_ect_gate_nop_acc             ; 7123 1 208 180 CD06
                CMPC    A, 017adh              ; 7125 1 208 180 909EAD17
                JGT     vss_ect_gate_load_ram2f1_3             ; 7129 1 208 180 C813
vss_ect_gate_nop_acc:     NOP                            ; 712B 1 208 180 00
                NOP                            ; 712C 1 208 180 00
                NOP                            ; 712D 1 208 180 00
                NOP                            ; 712E 1 208 180 00
                NOP                            ; 712F 1 208 180 00
                NOP                            ; 7130 1 208 180 00
                CMPB    0d9h, #03ch            ; 7131 1 208 180 C5D9C03C
                JLE     vss_ect_gate_goto_17eb             ; 7135 1 208 180 CF04
                LB      A, off(002f1h)         ; 7137 0 208 180 F4F1
                JNE     vss_ect_gate_goto_17b1             ; 7139 0 208 180 CE06
vss_ect_gate_goto_17eb:     J       idle_stage_c0_load_clear_ram218_bit0             ; 713B 0 208 180 03EB17
vss_ect_gate_load_ram2f1_3:     MOVB    off(002f1h), r4        ; 713E 1 208 180 247CF1
vss_ect_gate_goto_17b1:     J       vss_ect_gate_load_r3             ; 7141 1 208 180 03B117
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7144
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 714C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7154
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 715C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7164
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 716C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7174
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 717C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7184
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 718C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7194
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 719C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71A4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71AC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71B4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71BC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71C4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71CC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71D4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71DC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71E4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71EC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71F4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 71FC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7204
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 720C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7214
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 721C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7224
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 722C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7234
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 723C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7244
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 724C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7254
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 725C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7264
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 726C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7274
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 727C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7284
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 728C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7294
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 729C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72A4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72AC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72B4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72BC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72C4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72CC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72D4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72DC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72E4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72EC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72F4
vcal_4_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 72FB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7303
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 730B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7313
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 731B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7323
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 732B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7333
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 733B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7343
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 734B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7353
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 735B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7363
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 736B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7373
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 737B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7383
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 738B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7393
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 739B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73A3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73AB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73B3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73BB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73C3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73CB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73D3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73DB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73E3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73EB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73F3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 73FB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7403
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 740B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7413
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 741B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7423
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 742B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7433
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 743B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7443
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 744B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7453
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 745B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7463
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 746B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7473
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 747B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7483
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 748B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7493
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 749B
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74A3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74AB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74B3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74BB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74C3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74CB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74D3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74DB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74E3
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74EB
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74F3
                DB  0FFh,0FFh ; 74FB
vss_clamp_common_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 74FD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7505
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 750D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7515
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 751D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7525
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 752D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7535
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 753D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7545
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 754D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7555
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 755D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7565
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 756D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7575
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 757D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7585
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 758D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7595
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 759D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75A5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75AD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75B5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75BD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75C5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75CD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75D5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75DD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75E5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75ED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75F5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 75FD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7605
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 760D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7615
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 761D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7625
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 762D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7635
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 763D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7645
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 764D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7655
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 765D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7665
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 766D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7675
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 767D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7685
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 768D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7695
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 769D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76A5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76AD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76B5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76BD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76C5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76CD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76D5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76DD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76E5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76ED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76F5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 76FD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7705
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 770D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7715
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 771D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7725
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 772D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7735
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 773D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7745
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 774D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7755
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 775D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7765
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 776D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7775
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 777D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7785
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 778D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7795
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 779D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77A5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77AD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77B5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77BD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77C5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77CD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77D5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77DD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77E5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77ED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77F5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77FD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7805
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 780D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7815
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 781D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7825
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 782D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7835
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 783D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7845
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 784D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7855
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 785D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7865
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 786D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7875
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 787D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7885
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 788D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7895
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 789D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78A5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78AD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78B5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78BD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78C5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78CD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78D5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78DD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78E5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78ED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78F5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 78FD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7905
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 790D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7915
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 791D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7925
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 792D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7935
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 793D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7945
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 794D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7955
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 795D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7965
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 796D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7975
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 797D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7985
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 798D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7995
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 799D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79A5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79AD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79B5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79BD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79C5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79CD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79D5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79DD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79E5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79ED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79F5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 79FD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A05
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A0D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A15
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A1D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A25
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A2D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A35
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A3D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A45
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A4D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A55
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A5D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A65
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A6D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A75
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A7D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A85
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A8D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A95
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7A9D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AA5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AAD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AB5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7ABD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AC5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7ACD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AD5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7ADD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AE5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AF5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7AFD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B05
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B0D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B15
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B1D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B25
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B2D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B35
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B3D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B45
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B4D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B55
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B5D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B65
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B6D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B75
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B7D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B85
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B8D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B95
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7B9D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BA5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BAD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BB5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BBD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BC5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BCD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BD5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BDD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BE5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BF5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7BFD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C05
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C0D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C15
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C1D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C25
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C2D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C35
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C3D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C45
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C4D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C55
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C5D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C65
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C6D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C75
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C7D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C85
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C8D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C95
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7C9D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CA5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CAD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CB5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CBD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CC5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CCD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CD5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CDD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CE5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CF5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7CFD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D05
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D0D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D15
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D1D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D25
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D2D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D35
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D3D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D45
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D4D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D55
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D5D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D65
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D6D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D75
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D7D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D85
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D8D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D95
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7D9D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DA5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DAD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DB5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DBD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DC5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DCD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DD5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DDD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DE5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DF5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7DFD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E05
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E0D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E15
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E1D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E25
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E2D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E35
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E3D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E45
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E4D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E55
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E5D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E65
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E6D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E75
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E7D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E85
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E8D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E95
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7E9D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EA5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EAD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EB5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EBD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EC5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7ECD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7ED5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EDD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EE5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EED
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EF5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7EFD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F05
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F0D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F15
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F1D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F25
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F2D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F35
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F3D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F45
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F4D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F55
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F5D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F65
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F6D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F75
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F7D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F85
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F8D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F95
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7F9D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FA5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FAD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FB5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FBD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FC5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FCD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FD5
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FDD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7FE5
;  [info] end of programmed ROM (image stops at 7FF0h; asm662 pads to 8000h). There is no version
;    signature here (unlike the HTS TunerSuite ROMs). Reads of 07FF0h..07FF3h therefore return 0:
;    these are the p13info 'Debug/Test mode' flags -- 00h = disabled, writing FFh in an EPROM that
;    extends past 7FF0h enables the alt paths listed at 0D22. The 5441h pointer words seen at
;    6AB7h are the knock handler table, not code.
                DB  0FFh,0FFh,0FFh,000h ; 7FED
