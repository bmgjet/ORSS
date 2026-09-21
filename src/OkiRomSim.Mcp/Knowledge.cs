namespace OkiRomSim.Mcp;

/// What an agent needs to know to read and write 66K (MSM66207 / nX-8/200) assembly, by topic. Written from the datasheet, the opcode grammar and what the simulator had to get right to run the stock Honda ROMs.
public static class Knowledge
{
    public static readonly (string Topic, string Summary, string Text)[] Topics =
    {
        ("overview", "the chip, the ECU, and how to approach a ROM", """
OKI MSM66207 (family MSM66201/66P207, CPU core nX-8/200, "66K"). 16-bit accumulator machine with
byte and word operations, bit instructions, hardware multiply/divide, 4 timers, 8-channel 10-bit
ADC, serial port, 2 PWM outputs. Used in Honda OBD1 ECUs (P28, P30, P72, P08...).

  ROM (code space)   0000-7FFF  32 KB, read by instruction fetch and LC/LCB/CMPC (data tables)
  RAM (data space)   0000-0FFF  4 KB: 0000-00FF SFRs (control registers), then RAM
  Stack              system stack (SSP, starts 07FE-ish, grows down), user stack USP

Code and data are separate spaces: `L A, 1234h` reads RAM; `LC A, 1234h` reads ROM.

Clock: the P28 board has a 10 MHz crystal. Instruction timing and timers run at fOSC/4 = 2.5 MHz in
the simulator's cycle units, timers /8 = 312.5 kHz: the stock ROMs' rpm word then reads 1,875,000/rpm
and injector ticks are 3.2 us, exactly the tuning software's scalings.

Workflow for an agent:
  1. `disassemble` a .bin (or open the .asm) -> `symbols` / `file_search` to find things
  2. `arch` topics dd, addressing, instructions; `opcode` for any mnemonic you are unsure of
  3. `explore` a routine to see what it calls, reads, writes and probably does
  4. edit with file_edit, `assemble` (errors come with line numbers), `run` to test it boots,
     keeps the fuel pump on and injects, `compare_bins` to check a patch only changed what you meant
"""),
        ("memory", "code/data spaces, SFR map, register banks in RAM", """
DATA SPACE (RAM + SFR), 0000-0FFF
  0000 SSP  0002 LRB  0004 PSW (PSWL=0004, PSWH=0005)  0006 ACC (A; ACCH=0007)
  0018 IRQ (16 request bits)   001A IE (16 enable bits)
  0020 P0  0021 P0IO   0022 P1 0023 P1IO   0024 P2 0025 P2IO 0026 P2SF
  0028 P3 0029 P3IO 002A P3SF   002C P4 002D P4IO 002E P4SF   002F P5 (analog inputs as port)
  0030/0032 TM0/TMR0  0034/0036 TM1/TMR1  0038/003A TM2/TMR2  003C/003E TM3/TMR3
  0040-0043 TCON0-3   0046 TRNS (transition detect)   0058 ADSCAN 0059 ADSEL  0060.. ADCR0..7
  (the assembler knows all SFR names: `LB A, P2`, `ST A, IE`, `MOV off(...)`)
  0080-00BF pointing-register sets PR0..PR7: X1, X2, DP, USP of set n live at 0080+8n
            (+0 X1, +2 X2, +4 DP, +6 USP); PSW.SCB (bits 0-2) selects the live set
  local register banks (r0-r7 / er0-er3): LRB selects an 8-byte bank:
            bank base = ((LRB >> 5) << 8) | ((LRB & 1F) << 3)
  `off N8` operands address the LRB page: ((LRB >> 5) << 8) | N8
  plain `N8` operands address 0000-00FF directly (SFRs and page-zero RAM)

CODE SPACE, 0000-7FFF
  0000 reset vector   0002 BRK vector   0004 watchdog timeout   0006 NMI
  0008-0027 16 maskable interrupt vectors, one per IRQ/IE bit (see topic interrupts)
  0028-0037 VCAL table: `VCAL n` (1 byte) calls the address stored at 0028+2n
  0038..    code and calibration data (Honda: maps near the top of ROM, 6000-7FFF)
"""),
        ("registers", "A, pointer registers, register banks, PSW", """
A      16-bit accumulator (A = ACCH:ACCL). Most ALU operations have A as destination.
r0..r7 8-bit local registers, er0..er3 their 16-bit pairs (er0 = r1:r0) - in the LRB bank.
X1, X2 index registers (N16[X1], N16[X2] addressing)
DP     data pointer ([DP], and JRNZ DP loops)
USP    user stack pointer, also used as a base: S8[USP] (e.g. `(001e7h-00180h)[USP]` with USP=0180)
SSP    system stack pointer (CAL/RT, interrupts, PUSHS/POPS)
LRB    local register base (selects the r0-r7 bank and the `off` page)
PSW    PSWH (high byte) / PSWL (low byte):
         PSWH.7 CY carry (borrow after SUB/CMP)   PSWH.6 Z zero   PSWH.5 HC half carry
         PSWH.4 DD data descriptor (1 = word, 0 = byte; see topic dd)
         PSWH.0 MIE master interrupt enable (ORB PSWH,#01h enables, ANDB PSWH,#0FEh disables)
         PSWL.0-2 SCB (pointer register set)   PSWL.4/.5, PSWH.1 user flags (ROMs use them)
"""),
        ("dd", "the DD (data descriptor) flag: 8-bit vs 16-bit - the #1 source of wrong disassembly", """
DD = PSWH.4 decides whether accumulator operations are 16-bit (DD=1, word) or 8-bit (DD=0, byte).
Many opcode bytes mean different instructions depending on DD:
     18      DD=1: ADC A, er0      DD=0: ADCB A, r0
     96 xx.. DD=1: ADC A, #N16 (3 bytes)   DD=0: ADCB A, #N8 (2 bytes)   <- even the LENGTH changes
So the CPU state, not just the bytes, determines what executes.

What sets DD:
  set   (word): L A,..   MOV A,<word>   CLR A   EXTND   (and ST/ADD... do NOT change it)
  reset (byte): LB A,..  MOVB A,<byte>  CLRB A
  DD is saved with PSW on interrupts (restored by RTI) and by PUSHS/POPS PSW; CAL/RT do NOT save it,
  so a subroutine's DD at entry is whatever the caller had.

Rules when writing code:
  * Before a word op on A (ADD A,.. SUB A,.. CMP A,.. ST A,..) make sure the last load was L/MOV A
    or CLR A; before a byte op (ADDB, CMPB, STB...) the last load was LB/MOVB A or CLRB A.
  * At a label reached from several places, every path must arrive with the same DD.
  * After CAL, assume nothing about DD unless you know the callee's exit state; reload A.
  * The assembler encodes what you write (ADDB = byte encoding); if DD is wrong at run time the CPU
    executes the OTHER meaning. `explore` and `run` show DD per instruction (the 0/1 column).
In disassembly listings of the stock ROMs the comment column `; 1234 1 200 180 ...` shows
address, DD (1/0), LRB and USP at that instruction.
"""),
        ("addressing", "operand forms, indirect and double-indirect (redirect) access", """
Operand forms:
  A, r0-r7, er0-er3, X1, X2, DP, USP, SSP, LRB, PSWH, PSWL, C (carry bit)
  #N8 / #N16            immediate
  N8                    direct 0000-00FF (SFRs, page-zero RAM)      e.g. LB A, 0d9h
  N16                   direct anywhere in RAM                       e.g. L A, 0404h
  off N8 / off(N16)     LRB page + N8                                e.g. STB A, off(00236h)
  [DP]                  indirect through DP                          e.g. LB A, [DP]
  N16[X1], N16[X2]      indexed: address = N16 + X1                  e.g. L A, 00360h[X1]
  S8[USP]               USP + signed 8-bit displacement              e.g. MOVB r3, (001e7h-00180h)[USP]
  N'16[X1]              second-immediate indexed form of some MOV/compare instructions
  bit operands: <byte operand>.n, e.g. P0.7, off(00212h).4, [DP].5, r0.0, PSWH.4

CODE-SPACE reads (tables and constants in ROM):
  LC  A, N16 / LCB A, N16        load word/byte from ROM
  LC  A, [DP] / N16[X1] / [X1]   indexed/indirect ROM reads (table lookups)
  CMPC / CMPCB                    compare against ROM

INDIRECT CONTROL FLOW ("redirect"):
  J [DP] / CAL [DP]          target = the value IN the register (J [er0], [X1], [X2], [USP]...)
  J [off N8] / J [N8]        target = the word stored in RAM at that address
  DOUBLE REDIRECT - the target is found through two levels of memory:
  J [[DP]] / CAL [[DP]]      DP points at a RAM word; that word is the jump target
  J [N16[X1]] / CAL [N16[X2]] / J [S8[USP]]   indexed RAM word holds the target
  (these read the pointer from DATA space; a ROM jump table needs LC first, see below)

DOUBLE INDIRECTION (a pointer to a pointer), e.g. dispatch tables:
        MOV  DP, #cmd_table     ; ROM table of routine addresses
        ADD  DP, A              ; index (word entries: add the index twice)
        LC   A, [DP]            ; first indirection: read the entry from ROM
        MOV  DP, A
        J    [DP]               ; second: jump to it
  The the tuning software serial command handler and many ISR dispatchers work like this. When you move code,
  the TABLE ENTRIES must be updated (they are DW label, not relative) - use labels, never raw
  addresses, so the assembler fixes them for you.

Pointer tables in RAM work the same way with L A,[DP] / L A,N16[X1].
"""),
        ("instructions", "instruction groups and naming conventions", """
Width suffix: B = byte form (LB, STB, ADDB, CMPB, MOVB, CLRB, INCB...). No suffix = word.
Transfer:   L / LB (load A), ST / STB (store A), MOV / MOVB (memory/register to memory/register,
            including immediates: MOVB off(0212h), #01h), XCHG, CLR, LC/LCB (from ROM), PUSHS/POPS
Arithmetic: ADD ADC SUB SBC CMP (+B forms), INC DEC, MUL (A*er0 -> er1:A), MULB (AL*r0 -> A),
            DIV (er0:A / er2), DIVB, EXTND (sign-extend AL), DAA/DAS, NEG-like via CLR/SUB
Logic:      AND OR XOR (+B), SLL SRL SRA ROL ROR (+B; rotates go through carry), SWAP/SWAPB
Bits:       SB / RB (set/reset bit; Z = old bit was 0), MB C,bit / MB bit,C (move via carry),
            JBS / JBR bit,target (jump if bit set/reset), SBR/RBR/MBR/TBR (bit number in A),
            TBR = TRB: both spellings assemble to the same opcode (test bit, sets Z)
Branches:   J (absolute), SJ (short, rel8), JEQ JNE JLT JGE JGT JLE (after CMP: LT/GE use carry,
            i.e. unsigned), JRNZ reg,target (decrement and loop), CAL / SCAL / VCAL n / RT,
            RTI (interrupt return), BRK (software trap -> vector 0002)
Flags:      SC / RC (carry), CMP sets C when destination < source (unsigned)
Use `opcode <mnemonic>` for every encoding, byte length, cycles and DD requirement.
"""),
        ("branches", "conditional jumps, ranges, loops and calls", """
JEQ/JNE test Z. JLT/JGE test carry (unsigned: JLT = below, JGE = above-or-equal). JGT/JLE use C and Z.
Conditional jumps and SJ are 8-bit relative (-128..+127 from the next instruction). If the
assembler reports "out of range", invert the condition around a J:
        JEQ  far_label        ->     JNE  skip
                                     J    far_label
                              skip:
JBS/JBR bit,target are also relative. JRNZ DP/rN,target: decrement, loop while not zero (a DP of 0
runs 65,536 times - the ROMs' boot delays do exactly that).
CAL addr (3 bytes, any address), CAL [reg] (indirect), SCAL (2-byte short call), VCAL n (1 byte, via
the table at 0028). RT returns. Interrupt handlers end with RTI, which restores PSW (and DD, MIE).
"""),
        ("stack", "system stack, calls and interrupt frames", """
SSP stores then decrements (word at [SSP], SSP -= 2). CAL pushes the return address; RT pops it.
Interrupt entry pushes PC, A, LRB, PSW (in that order), clears MIE and jumps to the vector.
RTI pops them back in reverse. PUSHS/POPS move a register or A to/from the system stack.
Handlers usually start `L A,0fah / ST A,IE` (mask), switch LRB to their own bank
(MOV LRB,#nnnnh), save DP/X1 with PUSHS, and restore everything before RTI.
"""),
        ("interrupts", "IRQ/IE, vectors, what fires on a P28 board", """
IRQ (0018) holds 16 request bits, IE (001A) the matching enables, PSWH.0 (MIE) the master enable.
The lowest pending enabled bit is served first; its vector is the word at 0008 + 2*bit.
  vector  bit  source
  0008     0   INT0 (vehicle speed sensor on a P28)
  000A     1   serial receive          000C  2  serial transmit     000E  3  serial RX baud gen
  0010     4   TM0 overflow            0012  5  TM0 match (injector pulse end)
  0014     6   TM1 overflow            0016  7  TM1 match
  0018     8   TM2 overflow            001A  9  TM2 capture (crank CKP pulse)
  001C    10   TM3 overflow            001E 11  TM3 match (ignition)
  0020    12   A/D conversion done     0022 13  PWM timer     0024 14  serial TX baud gen
  0026    15   INT1 (TDC)
Watchdog: the ROM must write WDT regularly (P28 also toggles P2.4 as a board watchdog heartbeat).
"""),
        ("p28", "Honda P28 board: what each pin and analog channel is (pinout measured on a board)", """
Crystal 10 MHz (OSC0/OSC1), RES reset.
External bus (P0 = AD0-7, P1 = A8-15, ALE/RD/WR) to an 8255 PPI at data addresses:
  0F00h port A (input: switches; the ROM stores PA XOR 38h at 0210h)
  1F00h port B (output: the ROM copies P0 here - fuel pump relay is PB7 = P0.7, low = on)
  2F00h port C (output: the ROM copies P1 here - VTEC solenoid is PC0 = P1.0)
  3F00h control (the ROMs write 90h: A in, B and C out); the ROM reads B/C back to verify
  So "P0.7 / P1.0" in the code are latch bits that reach the car through the 8255.
Injectors: P2.0 = injector 1, P2.1 = injector 3, P2.2 = injector 4, P2.3 = injector 2 (firing order).
  They are not timed per channel: the wanted pattern is latched on P2.0-3 and the injector gate pulse
  (P3.4, timer 0 output) opens them for the pulse width, ended by a TM0 match.
P2.4 watchdog heartbeat   P2.5-P2.7 analog mux select (two CD4051s, U5 and U6)
P3.0 TX  P3.1 RX (datalog)  P3.2 VSS (INT0)  P3.3 TDC (INT1)  P3.4 injector gate pulse
P3.5 IACV PWM  P3.6 CKP (TM2 capture, 24 pulses per cam turn)  P3.7 ignition (TM3 output)
P4.2 EGR (PWM0)  P4.3 A/T lockup (PWM1)  P4.4 CYP (TRNS0)  P4.5 ICM test / igniter feedback (TRNS1)
P4.6 injector test / driver feedback (TRNS2; some ROMs also read it in their VTEC logic)
Analog: P5.0 U6 out (mux: ch0 ECT, ch3 baro, ch7 IAT)  P5.1 U5 out (mux: ch0 O2)  P5.2 ALT FR
        P5.3 EGR lift  P5.5 battery (divider)  P5.6 MAP  P5.7 TPS
Scalings used by the tuning software: rpm = 1,875,000 / period word; MAP mbar = byte*7.221-59;
TPS % = (byte-25)/2.04; ignition deg = byte*0.25-6; injector ms = word*3.2/1000.
"""),
        ("maps", "how Honda code looks up its fuel/ignition maps", """
2D maps are rows of RPM x columns of load (MAP). The set-up code is always the same shape:
        MOVB r0, #018h          ; bytes per row (stride)
        MOVB r1, #014h          ; rows
        MOVB r2, <col index>    ; from RAM, written by the load-axis search
        MOVB r3, <row index>    ; from RAM, written by the rpm-axis search
        MOV  X1, #FUEL1_Lo      ; the map (alternatives chosen by flags: primary/secondary, lo/hi cam)
        SB   PSWL.5             ; set = fuel map with a per-column multiplier row after it
        CAL  table2d_lookup_interp
Axis searches: MOV X1,#axis / MOVB r6,#count / CAL search / LB A,r6 / STB A,<index RAM>.
Low-cam RPM axis bytes are exponent/mantissa (2^(b>>6) * (500 + 7.8125*(b&63))), high-cam
linear (1875000*b/43520), a trailing 00 means 256. Fuel cell value = cell * multiplier / 4.
`detect_tables` finds all of this automatically.
"""),
        ("assembler", "source syntax and directives accepted by `assemble`", """
Syntax: `label:  MNEMONIC operands ; comment`. Numbers: 0FFh / 0ffh hex (leading
digit required), 0x1F, $1F, decimal. Expressions: + - * / % & | ^ << >> ( ), comparisons.
Directives: ORG addr, DB bytes/"string", DW words, EQU (name EQU value), DS count[,fill],
ALIGN n, INCLUDE "file", INCBIN "file", IF/IFDEF/IFNDEF/ELSEIF/ELSE/ENDIF, DEFINE/UNDEF,
MODULE name .. ENDMODULE, ASSERT expr,"msg", ERROR/WARNING/MESSAGE "msg", ROMSIZE.
Strict by default: undefined symbols, duplicate labels, out-of-range branches, overlapping
bytes and code past 7FFF are errors (compat=true relaxes these to warnings).
Outputs: .bin, and optionally .sym (ADDR NAME), .lst (listing) and .map (usage, free space).
To add code: find free space with `assemble` (map shows free regions, usually FF-filled near the
end of ROM), put it there with ORG, and reach it with CAL/J from the patched site.
"""),
        ("pitfalls", "mistakes that assemble fine but break the ECU", """
* Wrong DD at a byte/word op (see dd). Symptom in `run`: garbage values, BRK traps, lost sync.
* Moving code without updating DW tables / VCAL table / vectors - always use labels.
* Changing an instruction's length shifts everything after it: that is fine with labels, but
  hard-coded addresses in comments, jump tables written as raw numbers, or checksum routines
  (the stock ROMs check their own ROM/RAM at boot) will break.
* Forgetting to service WDT in a long new loop -> watchdog reset.
* Clobbering a register bank another routine expects (ISRs switch LRB; save what you use).
* Interrupt handlers must end with RTI, restore LRB/A/DP, and keep IE/MIE consistent.
* JLT/JGE are unsigned. For signed compares test the sign bit yourself.
* `run` a patched image and check: fuel pump ON, injector events ~ rpm/60*2 per injector-pair,
  no traps. Compare against the unpatched image.
"""),
    };

    public static string Get(string? topic)
    {
        if (string.IsNullOrWhiteSpace(topic) || topic == "list")
            return "Topics (call arch with one of these):\n" + string.Join("\n", Topics.Select(t => $"  {t.Topic,-13} {t.Summary}"));
        if (topic == "all") return string.Join("\n\n", Topics.Select(t => $"=== {t.Topic} ===\n{t.Text.Trim()}"));
        var hit = Topics.FirstOrDefault(t => t.Topic.Equals(topic, StringComparison.OrdinalIgnoreCase));
        if (hit.Text != null) return hit.Text.Trim();
        var partial = Topics.Where(t => t.Topic.Contains(topic, StringComparison.OrdinalIgnoreCase) || t.Text.Contains(topic, StringComparison.OrdinalIgnoreCase)).ToList();
        return partial.Count == 0 ? $"no topic '{topic}'. " + Get(null)
            : string.Join("\n\n", partial.Select(t => $"=== {t.Topic} ===\n{t.Text.Trim()}"));
    }
}
