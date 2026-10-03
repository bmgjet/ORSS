; ==================================================================================================
; dlmemread.asm - datalogging: memory read
;> feature: FEAT_DLMEMREAD
;> name: Datalogging: memory read
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL
;> about: The ECU's RAM read over the datalog cable while the engine runs, 32 bytes at a time: any value
;>        or module state on the car, not just the ones a datalog channel sends (Datalogging > Codes and
;>        service… > ECU memory). The ROM itself is never sent, so the code and the maps of a tune stay
;>        in the chip.
;
;   60h alo ahi chk     read the 32 bytes from the address (80h-460h: RAM, not the registers, where a read can
;                       change what they hold). chk makes the four bytes sum to 00h. Answer 60h, the 32 bytes,
;                       and their sum with the 60h; 7Fh for a bad checksum or an address outside RAM.
; A running stream stops for it (any command stops it) and is started again with 71h.
; ==================================================================================================
ifdef FEAT_DLMEMREAD

if XP == XP_DEFS
DL_MSUM         EQU     00375h          ; the request's sum while it comes in (the stream's list checksum)
DL_MADDR        EQU     00376h          ; its address (the stream's tick latch: no frame is being sent)
endif

if XP == XP_CODE
; ------------------------------------------------------------------ 60h (datalog.asm's receive interrupt, command state)
dl_rx_memcmd:   MOVB    r0, #006h
                MOV     DP, #DL_MSUM
                STB     A, [DP]                ; the sum starts with the 60h
                J       dl_rx_ret
; ------------------------------------------------------------------ states 6-8: the address, low then high, then the checksum
dl_rx_memrd:    STB     A, r1                  ; (r1: the receive interrupt's own)
                MOV     DP, #DL_MSUM
                ADDB    A, [DP]
                STB     A, [DP]
                CMPB    r0, #008h
                JEQ     dl_mr_check
                MOV     DP, #DL_MADDR
                CMPB    r0, #006h
                JEQ     dl_mr_lo
                INC     DP
dl_mr_lo:       LB      A, r1
                STB     A, [DP]
                INCB    r0
                J       dl_rx_ret
dl_mr_check:    MOVB    r0, #000h
                CMPB    A, #000h
                JNE     dl_mr_no
                MOV     DP, #DL_MADDR
                L       A, [DP]
                CMP     A, #00080h
                JLT     dl_mr_no               ; the registers
                CMP     A, #00460h
                JGT     dl_mr_no               ; past RAM (the 32 bytes must fit below 480h)
                MOVB    r2, #007h
                J       dl_rx_start
dl_mr_no:       LB      A, #07fh
                J       dl_rx_send

; ------------------------------------------------------------------ the next byte (r2 = 7): 60h, the 32 bytes, their sum
dl_next_mem:    LB      A, r3
                JNE     dl_nm_byte
                LB      A, #060h
                J       dl_next_put
dl_nm_byte:     CMPB    A, #021h
                JGE     dl_nm_sum
                SUBB    A, #001h
                L       A, ACC                 ; (ACCH clear: dl_next starts with CLR A)
                MOV     DP, #DL_MADDR
                ADD     A, [DP]
                MOV     DP, A
                LB      A, [DP]
                J       dl_next_put
dl_nm_sum:      J       dl_next_fsum           ; the sum of the 33, and the end
endif

endif
