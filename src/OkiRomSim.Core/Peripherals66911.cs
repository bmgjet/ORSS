// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Core;

/// The OKI MSM66911's peripherals - the Honda P13 / P14 generation - as a set of their own, because they are not the 66207's with different names on them. The register map is somewhere else entirely, the crank timer is a free-running counter with capture channels rather than four compare timers, the injectors are driven by one-shots instead of a latched pattern plus a gate pulse, and there are two free-running PWM counters the ROM checks are moving before it will run. Everything here is known from what a stock P13-N51 image does with each register, from the public P13 research notes and from bench measurements; there is no datasheet for the part. Where something is a guess the comment says so. <para> What this has to get right, or the ROM resets before it ever injects: the 0x56 counter ticking every 4 us with its captures, the 10.24 ms housekeeping interrupt (or the runaway check trips with BRK code 0x57), both PWM counters visibly advancing (codes 0x58-0x5A), all sixteen bits of IE reading back what was written (0x50), the one-shots counting down and driving their pins, and the A/D results appearing as 16-bit words. </para>
public sealed class Peripherals66911
{
    readonly Bus _bus;
    public Peripherals66911(Bus bus) { _bus = bus; }

    // ---------------------------------------------------------------- register map

    public const ushort SfrPclk = 0x0F;
    public const ushort SfrWdt = 0x11;
    public const ushort SfrIrq = 0x18, SfrIe = 0x1A;
    public const ushort SfrP5 = 0x1E;                 // analog inputs, read-only
    public const ushort SfrP4Sf = 0x1F, SfrP4Io = 0x20, SfrP4 = 0x21;
    public const ushort SfrP3Sf = 0x22, SfrP3Io = 0x23, SfrP3 = 0x24;
    public const ushort SfrP2A = 0x25;                // upper nibble direction, lower nibble data
    public const ushort SfrP2Sf = 0x26, SfrP2Io = 0x27, SfrP2 = 0x28;
    public const ushort SfrTrnsit = 0x29;             // edge latches, not a direction register
    public const ushort SfrPwm0Con = 0x2A, SfrPwmIe = 0x2B, SfrPwm1Con = 0x2C, SfrPwmPre = 0x2D;
    public const ushort SfrPwm0Cmp = 0x2E, SfrPwm0Cnt = 0x30;
    public const ushort SfrPwm1Cmp = 0x3E, SfrPwm1Cnt = 0x40;
    public const ushort SfrOsIe = 0x42;
    public const ushort SfrOs0 = 0x44;                // 0x44 0x46 0x48 0x4A - general one-shots
    public const ushort SfrInj0 = 0x4C;               // 0x4C 0x4E 0x50 0x52 - the injector drivers
    public const ushort SfrTcon = 0x54, SfrTcon2 = 0x55;
    public const ushort SfrTimer = 0x56;              // free-running 16-bit up-counter, 4 us a tick
    public const ushort SfrCap0 = 0x58;               // CKP or TDC, per TCON bit 4
    public const ushort SfrCap3 = 0x5E;               // VSS
    public const ushort SfrIgnCon = 0x61;
    public const ushort SfrIgnA = 0x62;               // expiry drives the ignition pin LOW  (coil on)
    public const ushort SfrIgnB = 0x64;               // expiry drives it HIGH (the spark)
    public const ushort SfrAdscan = 0x66, SfrAdsel = 0x67;
    public const ushort SfrAdcr0 = 0x68;              // eight 16-bit results, 12 bits left-justified
    public const ushort SfrSttmr = 0x78, SfrSttm = 0x79;
    public const ushort SfrSconA = 0x7A, SfrSconB = 0x7B;
    public const ushort SfrStbuf = 0x7C, SfrSrbuf = 0x7D, SfrSrstat = 0x7E;

    // Vector = 0x0008 + 2*N. These are the sources, not the 66207's.
    public const int IrqCapture = 0;      // Int0  CKP / TDC edge
    public const int IrqCrankTask = 1;    // Int1  raised by software from Int0 (SB IRQ.1 at 0x01E7)
    public const int IrqHalt = 2;
    public const int IrqVss = 3;          // Int3  VSS edge
    /// Int4 is the 0x56 counter wrapping. The boot timer test (0x0A5D) loads TIMER with 0xFFFE and fails with BRK 0x53 unless IRQ bit 4 is set a few microseconds later; the handler at 0x0170 counts the wraps into 0xF7/0xF6 so periods longer than 262 ms can be measured, and the VSS capture checks IRQ.4 for a wrap that has not been serviced yet.
    public const int IrqOverflow = 4;
    public const int IrqPwm0Pin = 5, IrqPwm0Sw = 6, IrqPwm1Pin = 9;
    /// Int10 is the 10.24 ms housekeeping tick: its handler (0x016C) only sets 0x9E.3, which the main loop polls and clears, and the runaway check measures the gap between those passes.
    public const int IrqTick = 10;
    public const int IrqAdc = 11;         // Int11 the ROM polls instead of using it
    public const int IrqSerial = 12;      // Int12 RX and TX share it
    public const int IrqIgnition = 13, IrqOneShots = 14, IrqInjectors = 15;

    /// The housekeeping interrupt comes every 2560 ticks of the 4 us counter - 10.24 ms. The ROM's runaway check wants to see the routine it drives at least every 20 ms.
    public const int TicksPerHousekeeping = 2560;

    /// SRSTAT: bit 4 TX interrupt enable, 5 RX interrupt enable, 6 TX done, 7 RX pending. The handler clears 6 and 7 itself.
    const byte SrstatTxDone = 0x40, SrstatRxReady = 0x80;

    // ---------------------------------------------------------------- state

    /// Machine cycles per tick of the 0x56 counter: 4.000 us, measured. At the profile's 5 MHz with no divider that is 20 machine cycles.
    public static uint CyclesPerTick => Math.Max(1, (uint)Math.Round(4.0 * Bus.CyclesPerUs));

    uint _tickRemainder;
    int _housekeeping;
    ulong _ticks;
    /// Ticks of the 4 us counter since reset, for anything that wants wall time.
    public ulong Ticks => _ticks;

    /// What each one-shot was armed with, so a pulse width can be reported when it expires.
    readonly ushort[] _armed = new ushort[8];
    /// Which timers are counting: the eight one-shots, then IGNA and IGNB. Running is a state of its own, not a register value - the boot tests (0x0A88, 0x0ADB) insist every one of them reads 0 out of reset without doing anything, counts down once written, and reads 0xFFFF when it has run out. Writing 0xFFFF stops one.
    readonly bool[] _running = new bool[10];
    const int IgnARun = 8, IgnBRun = 9;
    /// Measured injector pulse widths and coil firings go into the Bus's own counters, which is where the gauges, the MCP tools and the command line read them from whichever part is being simulated.
    uint[] InjectorPulseUs => _bus.InjectorPulseUs;
    long[] InjectorEvents => _bus.InjectorEvents;
    ulong[] InjectorLastEventAt => _bus.InjectorLastEventAt;
    /// The ignition pin's state: false = the coil is charging (pin low), true = at rest.
    public bool IgnitionRest = true;
    public float IacvDutyCyclePct, EgrDutyCyclePct;

    uint? _adcCyclesRemaining;
    uint? _serialTxCyclesRemaining;

    /// True while an injector one-shot is running, which is when its pin is pulled low.
    public bool InjectorOpen(int n)
    {
        if (n is < 0 or > 3) return false;
        // the one-shot only reaches the pin when P3SF has attached it (stock 0xF0 attaches all four)
        if ((_bus.Ram[SfrP3Sf] & (1 << (4 + n))) == 0) return false;
        return _running[4 + n];
    }

    // ---------------------------------------------------------------- helpers

    ushort Read16(ushort addr) => (ushort)(_bus.Ram[addr] | (_bus.Ram[addr + 1] << 8));

    void Write16(ushort addr, ushort v)
    {
        _bus.Ram[addr] = (byte)(v & 0xFF);
        _bus.Ram[addr + 1] = (byte)(v >> 8);
    }

    // ---------------------------------------------------------------- reads and writes

    /// A read the peripherals have to answer themselves. False leaves it to plain RAM, which is right for every register the ROM only ever reads back what it wrote (which is most of them, and is what the SFR integrity test at 0x0EBC depends on).
    public bool Read(ushort addr, out byte value)
    {
        switch (addr)
        {
            case SfrSrbuf:
                if (_bus.SerialRxQueue.Count > 0)
                {
                    value = _bus.SerialRxQueue[0];
                    _bus.SerialRxQueue.RemoveAt(0);
                    // the flag stays set while there is more waiting
                    if (_bus.SerialRxQueue.Count == 0) _bus.Ram[SfrSrstat] &= unchecked((byte)~SrstatRxReady);
                    return true;
                }
                value = _bus.Ram[SfrSrbuf];
                return true;

            case SfrP5:
                // the analog pins read as digital levels: a channel above half scale reads high
                {
                    byte b = 0;
                    for (int i = 0; i < 8; i++) if (_bus.AdcInput(i) >= 512) b |= (byte)(1 << i);
                    value = b;
                    return true;
                }

            case SfrP2:
            case SfrP3:
            case SfrP4:
                value = ReadPort(addr);
                return true;

            case SfrPwm1Con:
                // bit 4 is a live input, not a stored bit: the reset path (int_break, 0x0791) and the NMI standby loop (0x0765) read it as "supply good" and park the CPU in standby while it is low, and the SFR integrity test masks it out (& 0xEF). The ECU is powered whenever it is being simulated, so it reads high.
                value = (byte)(_bus.Ram[SfrPwm1Con] | 0x10);
                return true;

            default:
                value = 0;
                return false;
        }
    }

    /// A port the way the silicon reads it: a pin driven by a one-shot or another on-chip function reports what that function is doing, an output pin reports its latch, and an input pin reports the level on it.
    public byte ReadPort(ushort dataSfr)
    {
        byte latch = _bus.Ram[dataSfr];
        byte dir = dataSfr switch { SfrP2 => _bus.Ram[SfrP2Io], SfrP3 => _bus.Ram[SfrP3Io], _ => _bus.Ram[SfrP4Io] };
        byte sf = dataSfr switch { SfrP2 => _bus.Ram[SfrP2Sf], SfrP3 => _bus.Ram[SfrP3Sf], _ => _bus.Ram[SfrP4Sf] };
        byte result = 0;
        for (int bit = 0; bit < 8; bit++)
        {
            bool level;
            if ((sf >> bit & 1) != 0) level = SecondaryFunction(dataSfr, bit, latch, bit);
            else if ((dir >> bit & 1) != 0) level = (latch >> bit & 1) != 0;
            else level = ExternalLevel(dataSfr, bit);
            if (level) result |= (byte)(1 << bit);
        }
        return result;
    }

    /// What an on-chip function is doing with a pin it has been given.
    bool SecondaryFunction(ushort dataSfr, int bit, byte latch, int _)
    {
        if (dataSfr == SfrP3 && bit >= 4)
            // an injector driver: low while its one-shot runs
            return !InjectorOpen(bit - 4);
        if (dataSfr == SfrP2 && bit == 2) return IgnitionRest;         // the ignition command
        if (dataSfr == SfrP2 && bit == 1) return true;                 // serial TX idles high
        if (dataSfr == SfrP4 && bit == 0) return Pwm0Pin;   // PWM0, the IACV
        if (dataSfr == SfrP4 && bit == 4) return Pwm1Pin;   // PWM1, EGR
        return (latch >> bit & 1) != 0;
    }

    /// The board's own levels on the input pins. Only the ones the notes pin down are modelled; the rest read high, which is what an unconnected pull-up input does.
    bool ExternalLevel(ushort dataSfr, int bit)
    {
        if (dataSfr == SfrP4)
            return bit switch
            {
                5 => _bus.StarterSignal,              // pin 51
                6 => _bus.PowerSteeringPressure,      // pin 52
                // pin 55, O2 heater feedback: low while the heater drive (P2A.2, pin 36) is on. The ROM checks the two against each other every pass (0x27E5) and logs a fault the DTC handler resets on if they disagree
                7 => (_bus.Ram[SfrP2A] & 0x04) == 0,
                3 => _p43,
                _ => true,
            };
        return true;
    }

    /// A write the peripherals act on. False means "just store it".
    public bool Write(ushort addr, byte val)
    {
        // the A/D results are read-only; a conversion writes the latches itself
        if (addr >= SfrAdcr0 && addr < SfrAdcr0 + 16) return true;

        switch (addr)
        {
            case SfrAdscan:
                // Bit 6 with a channel in bits 0-2 is a one-off conversion, and it does not stay in the register: the crank interrupt writes 0x56 (MAP, channel 6) at 0x01E3 and reads ADCR6 straight after, while the SFR test at 0x0F18 insists ADSCAN & 0x57 == 0x10.
                if ((val & 0x40) != 0)
                {
                    int ch = val & 0x07;
                    Write16((ushort)(SfrAdcr0 + (ch * 2)), _bus.AdcResult(ch));
                    val = (byte)(val & ~0x47);
                }
                _bus.Ram[addr] = val;
                // bit 4 enables the converter; the ROM leaves it on and polls the results
                _adcCyclesRemaining = (val & 0x10) != 0 ? Bus.AdcConversionCycles : null;
                return true;

            case SfrStbuf:
                _bus.Ram[addr] = val;
                _bus.SerialTxQueue.Add(val);
                if (_bus.SerialTxQueue.Count > 8192) _bus.SerialTxQueue.RemoveRange(0, _bus.SerialTxQueue.Count - 4096);
                _bus.Ram[SfrSrstat] &= unchecked((byte)~SrstatTxDone);
                _serialTxCyclesRemaining = SerialByteCycles();
                return true;

            case SfrWdt:
                _bus.Ram[addr] = val;
                // the ROM feeds it 0x3C then 0xC3; either half restarts it in this model
                _bus.WatchdogCyclesRemaining = _bus.WatchdogTimeoutCycles;
                _bus.WatchdogTripped = false;
                return true;

            default:
                return false;
        }
    }

    /// Noted after a 16-bit write, so arming a one-shot can be seen and its width remembered.
    public void Armed(ushort addr)
    {
        for (int i = 0; i < 8; i++)
        {
            ushort reg = (ushort)(SfrOs0 + (i * 2));
            if (addr != reg && addr != reg + 1) continue;
            ushort v = Read16(reg);
            // 0xFFFF is both "stopped" and what the ROM writes to kill a pulse in flight
            _armed[i] = v;
            bool was = _running[i];
            _running[i] = v != 0xFFFF;
            // TRANSIT is a transition detector: the injector feedback pin (20) edges when a driver turns on as well as off, and the crank task checks for it (0x062B, code 16) straight after arming a pulse - long before that pulse could have ended (the ROM attaches the pin with SBR P3SF just after arming, so this does not wait for that)
            if (i >= 4 && !was && _running[i]) _bus.Ram[SfrTrnsit] |= 0x08;
        }
        if (addr == SfrIgnA || addr == SfrIgnA + 1) _running[IgnARun] = Read16(SfrIgnA) != 0xFFFF;
        if (addr == SfrIgnB || addr == SfrIgnB + 1) _running[IgnBRun] = Read16(SfrIgnB) != 0xFFFF;
    }

    /// Machine cycles one serial byte takes, from the baud reload the ROM chose. The reloads the P13 family uses: 0x40 4800, 0x20 9600 (stock), 0x0F 19200, 0x07 39063, 0x04 62500.
    uint SerialByteCycles()
    {
        int baud = _bus.Ram[SfrSttmr] switch
        {
            0x40 => 4800, 0x20 => 9600, 0x0F => 19200, 0x07 => 39063, 0x04 => 62500,
            var r => r > 0 ? (int)(312500.0 / r) : 9600,   // the table is 312500 / reload
        };
        return (uint)(Bus.CpuHz * 10 / (ulong)Math.Max(300, baud));   // 8N1: ten bit times
    }

    // ---------------------------------------------------------------- engine edges

    /// A crank (or TDC) tooth: the counter is captured and Int0 raised, which is where the ROM measures the tooth period from. TCON bit 0 enables it - and also gates the capture.
    public ushort CaptureCrank()
    {
        if ((_bus.Ram[SfrTcon] & 0x01) == 0) return 0;
        Write16(SfrCap0, Read16(SfrTimer));
        return 1 << IrqCapture;
    }

    /// A road-speed pulse: captured into 0x5E, Int3.
    public ushort CaptureVss()
    {
        if ((_bus.Ram[SfrTcon] & 0x08) == 0) return 0;
        Write16(SfrCap3, Read16(SfrTimer));
        return 1 << IrqVss;
    }

    /// The cylinder-position pulse (one per cycle), which latches on TRANSIT like the other edge inputs. Without it the ROM free-runs off TDC and says nothing, so this only matters to a ROM that checks - but a real distributor sends it.
    public void SignalCyp() => _bus.Ram[SfrTrnsit] |= 0x40;          // pin 27 = P2.6

    /// TDC, four a cycle: latched on TRANSIT bit 7 (pin 28 = P2.7). The crank task (0x020F / 0x024B) read-clears it on every tooth, expects it every sixth, and without it sets code 8 (TDC), whose handler restarts the ECU.
    public void SignalTdc()
    {
        _bus.Ram[SfrTrnsit] |= 0x80;
        _p43 = !_p43;
    }

    /// P4.3 (a CN3 input) as a pulse train that follows the crank. What drives it on the car is not known; what is known is that for ECU IDs 0x12 / 0x13 (option bit 0x221.1 from the variant table at 0x6CFF) the ROM watches it at 0x38D6 and logs code 24 if it stops changing while the engine turns. Toggled on every TDC here, the simplest signal that satisfies that.
    bool _p43;

    // ---------------------------------------------------------------- the tick

    public ushort Tick(uint cycles)
    {
        ushort irq = 0;

        // everything on this part is timed off the 4 us counter
        uint total = _tickRemainder + cycles;
        uint ticks = total / CyclesPerTick;
        _tickRemainder = total % CyclesPerTick;

        if (ticks > 0)
        {
            _ticks += ticks;

            // the free-running counter, and Int4 when it wraps
            uint sum = (uint)Read16(SfrTimer) + ticks;
            Write16(SfrTimer, (ushort)sum);
            if (sum > 0xFFFF) irq |= 1 << IrqOverflow;

            // housekeeping every 2560 ticks = 10.24 ms, on Int10
            _housekeeping += (int)ticks;
            if (_housekeeping >= TicksPerHousekeeping)
            {
                _housekeeping -= TicksPerHousekeeping;
                irq |= 1 << IrqTick;
            }

            irq |= TickOneShots(ticks);
        }

        irq |= TickPwm(cycles);

        irq |= TickSerial(cycles);
        irq |= TickAdc(cycles);
        TickWatchdog(cycles);

        if (irq != 0)
        {
            ushort now = (ushort)(_bus.Ram[SfrIrq] | (_bus.Ram[SfrIrq + 1] << 8) | irq);
            _bus.Ram[SfrIrq] = (byte)(now & 0xFF);
            _bus.Ram[SfrIrq + 1] = (byte)(now >> 8);
        }
        return irq;
    }

    /// Eight 16-bit countdowns. A running one-shot holds its pin; when it reaches the end it stops at 0xFFFF and releases it. 0x44-0x48 are used by the ROM as main-loop stopwatches, 0x4C-0x52 are the injector drivers, and 0x62/0x64 work the ignition pin between them.
    ushort TickOneShots(uint ticks)
    {
        ushort irq = 0;
        for (int i = 0; i < 8; i++)
        {
            ushort reg = (ushort)(SfrOs0 + (i * 2));
            if (!_running[i]) continue;
            ushort v = Read16(reg);
            // a down-counter that runs through 0 and stops when it wraps to 0xFFFF
            if (v >= ticks) { Write16(reg, (ushort)(v - ticks)); continue; }

            Write16(reg, 0xFFFF);
            _running[i] = false;
            if (i >= 4)
            {
                int inj = i - 4;
                // the pulse lasted what it was armed with, one tick being 4 us
                InjectorPulseUs[inj] = (uint)(_armed[i] * 4);
                _bus.InjectorPulseWidthUs = InjectorPulseUs[inj];
                InjectorEvents[inj]++;
                InjectorLastEventAt[inj] = _bus.ElapsedCycles;
                irq |= 1 << IrqInjectors;
                // the driver's confirmation comes back on the feedback pin's edge latch (pin 20)
                _bus.Ram[SfrTrnsit] |= 0x08;
            }
            else irq |= 1 << IrqOneShots;
        }

        // the ignition pair: A pulls the pin low (coil charging), B lets it go (the spark)
        foreach (var (reg, rest, run) in new[] { (SfrIgnA, false, IgnARun), (SfrIgnB, true, IgnBRun) })
        {
            if (!_running[run]) continue;
            ushort v = Read16(reg);
            if (v >= ticks) { Write16(reg, (ushort)(v - ticks)); continue; }
            Write16(reg, 0xFFFF);
            _running[run] = false;
            // the igniter feedback (pin 21) edges on both the coil switching on and the spark
            if (IgnitionRest != rest) _bus.Ram[SfrTrnsit] |= 0x10;
            IgnitionRest = rest;
            if (rest)
            {
                _bus.IgnitionEvents++;
                _bus.LastIgnitionAt = _bus.ElapsedCycles;
                // the igniter answers on the ICM feedback pin's latch (pin 21)
                _bus.Ram[SfrTrnsit] |= 0x10;
            }
            if ((_bus.Ram[SfrIgnCon] & 0x30) != 0) irq |= 1 << IrqIgnition;
        }
        return irq;
    }

    /// Both PWM channels, as the ROM's own checks of them (0x0D36-0x0DD6, BRK 0x58/0x59/0x5A) pin them down. It reads each counter twice a few instructions apart and resets unless the two differ, so they count machine cycles, not 4 us ticks. PWM0 (the IACV) is a signed counter running 0xF800..0x07FF with its pin high for the negative half (high for 0xF80A..0xFFF6, low for 0x000A..0x07F6 - whatever the compare, which the ROM sets anywhere from 0xA0 to 0x800, so how the compare shapes the real waveform is not known; it is shown as a duty of cmp / 0x800); PWM1 (EGR) is a plain 16-bit counter that reloads from its compare on overflow, with its pin high from 0xA000 up (low for 0x000A..0x5FF6, high for 0xA00A..0xFFF6 - the ROM sets the compare to 0xA000 minus the EGR demand, which can take it well below 0x5FF6 under load, so the pin cannot follow the compare itself), and its rising edge latches IRQ bit 9, which the check also wants to see. The prescaler at 0x2D is not established and is not applied.
    public bool Pwm0Pin => (short)Read16(SfrPwm0Cnt) < 0;
    public bool Pwm1Pin => Read16(SfrPwm1Cnt) >= 0xA000;

    ushort TickPwm(uint cycles)
    {
        ushort irq = 0;
        // PWM0: 12 bits, sign-extended
        int c0 = (short)Read16(SfrPwm0Cnt) + 0x800;
        c0 = (int)((c0 + cycles) & 0xFFF) - 0x800;
        Write16(SfrPwm0Cnt, (ushort)(short)c0);
        IacvDutyCyclePct = Math.Clamp(Read16(SfrPwm0Cmp) / 20.48f, 0f, 100f);

        // PWM1 reloads from its compare register when it overflows, so the compare sets the period and the pin is high for the fixed top 0x6000 counts
        bool was = Pwm1Pin;
        uint c1 = Read16(SfrPwm1Cnt) + cycles;
        if (c1 > 0xFFFF) c1 = Read16(SfrPwm1Cmp) + ((c1 - 0x10000) % (uint)Math.Max(1, 0x10000 - Read16(SfrPwm1Cmp)));
        Write16(SfrPwm1Cnt, (ushort)c1);
        if (!was && Pwm1Pin) irq |= 1 << IrqPwm1Pin;
        EgrDutyCyclePct = 0x6000 * 100f / Math.Max(0x6000, 0x10000 - Read16(SfrPwm1Cmp));
        return irq;
    }

    ushort TickSerial(uint cycles)
    {
        ushort irq = 0;
        while (_bus.SerialRxPending(out byte b))
        {
            _bus.SerialRxQueue.Add(b);
            _bus.Ram[SfrSrstat] |= SrstatRxReady;
            if ((_bus.Ram[SfrSrstat] & 0x20) != 0) irq |= 1 << IrqSerial;
        }
        if (_serialTxCyclesRemaining is uint left)
        {
            if (cycles >= left)
            {
                _serialTxCyclesRemaining = null;
                _bus.Ram[SfrSrstat] |= SrstatTxDone;
                if ((_bus.Ram[SfrSrstat] & 0x10) != 0) irq |= 1 << IrqSerial;
            }
            else _serialTxCyclesRemaining = left - cycles;
        }
        return irq;
    }

    /// Eight channels into eight 16-bit results, the 12-bit reading left-justified so the high byte is the "raw" sensor byte a datalog streams. (The ROM's own MAP bound of 0xA1F0 is 3.16 V, which is what fixes the justification.)
    ushort TickAdc(uint cycles)
    {
        if (_adcCyclesRemaining is not uint remaining) return 0;
        if (cycles < remaining) { _adcCyclesRemaining = remaining - cycles; return 0; }
        for (int ch = 0; ch < 8; ch++) Write16((ushort)(SfrAdcr0 + (ch * 2)), _bus.AdcResult(ch));
        // bit 5 = "a scan has finished". The ROM clears it with RB and only takes the results (and steps the multiplexer on) when it was set - the boot waits at 0x09F7 for all eight mux positions to come round that way, so without it a P13 never gets past its init.
        _bus.Ram[SfrAdscan] |= 0x20;
        _adcCyclesRemaining = (_bus.Ram[SfrAdscan] & 0x10) != 0 ? Bus.AdcConversionCycles : null;
        return 1 << IrqAdc;
    }

    void TickWatchdog(uint cycles)
    {
        if (!_bus.WatchdogEnabled) return;
        if (_bus.WatchdogCyclesRemaining == 0) _bus.WatchdogCyclesRemaining = _bus.WatchdogTimeoutCycles;
        if (cycles >= _bus.WatchdogCyclesRemaining)
        {
            _bus.WatchdogTripped = true;
            _bus.WatchdogCyclesRemaining = _bus.WatchdogTimeoutCycles;
        }
        else _bus.WatchdogCyclesRemaining -= cycles;
    }

    /// Put the boot values the ROM's SFR integrity test insists on into place, so a freshly reset simulator looks like a chip that has just come out of reset rather than one full of zeroes. The ROM writes all of these itself during boot; having them here means a ROM that is started part-way through, or one being poked at by hand, still reads sensible registers.
    public void Reset()
    {
        _tickRemainder = 0; _housekeeping = 0; _ticks = 0; _p43 = false;
        Array.Fill(_armed, (ushort)0xFFFF);
        Array.Clear(_running);
        Array.Clear(InjectorPulseUs); Array.Clear(InjectorEvents); Array.Clear(InjectorLastEventAt);
        _bus.InjectorPulseWidthUs = 0; _bus.IgnitionEvents = 0; _bus.LastIgnitionAt = 0; IgnitionRest = true;
        _adcCyclesRemaining = Bus.AdcConversionCycles;
        _serialTxCyclesRemaining = null;

        _bus.Ram[SfrPclk] = 0xA4;
        _bus.Ram[SfrP4Sf] = 0x01; _bus.Ram[SfrP4Io] = 0x11; _bus.Ram[SfrP4] = 0x11;
        _bus.Ram[SfrP3Sf] = 0xF0; _bus.Ram[SfrP3Io] = 0xFF; _bus.Ram[SfrP3] = 0x07;
        _bus.Ram[SfrP2A] = 0x6F;
        _bus.Ram[SfrP2Sf] = 0x06; _bus.Ram[SfrP2Io] = 0x06; _bus.Ram[SfrP2] = 0xF0;
        _bus.Ram[SfrPwm0Con] = 0x03; _bus.Ram[SfrPwm1Con] = 0x6F; _bus.Ram[SfrPwmPre] = 0x93;
        _bus.Ram[SfrOsIe] = 0xF0;
        _bus.Ram[SfrTcon] = 0x89; _bus.Ram[SfrTcon2] = 0x00;
        _bus.Ram[SfrIgnCon] = 0x10;
        _bus.Ram[SfrAdscan] = 0x10; _bus.Ram[SfrAdsel] = 0x00;
        _bus.Ram[SfrSttmr] = 0x20; _bus.Ram[SfrSttm] = 0x20;
        _bus.Ram[SfrSconA] = 0x80;
        // The P13 notes give both a boot value of 0x81 for this register and a self-test of "& 0xE5 == 0x80" - and 0x81 & 0xE5 is 0x81, so the two cannot both be right. The test is the one the ROM actually runs every main-loop pass (BRK 0x4E if it fails), so 0x80 it is; either the noted boot value is a digit out or bit 0 is not really in the mask. Worth settling against the disassembly at 0x0EBC.
        _bus.Ram[SfrSconB] = 0x80;
        _bus.Ram[SfrSrstat] = 0x20;
        // every one-shot stopped, reading 0 as it does out of reset (the boot tests check that)
        for (int i = 0; i < 8; i++) Write16((ushort)(SfrOs0 + (i * 2)), 0);
        Write16(SfrIgnA, 0); Write16(SfrIgnB, 0);
    }
}
