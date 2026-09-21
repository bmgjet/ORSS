// OKI MSM66207 Memory Bus & Peripheral Simulation.

namespace OkiRomSim.Core;

public sealed class Bus
{
    public const int RomSize = 32768; // 32KB ROM space (0x0000..0x7FFF)
    public const int RamSize = 4096;  // 4KB Data RAM & SFR space (0x0000..0x0FFF)

    /// The board carries a 10 MHz crystal (measured on OSC0/OSC1). The simulator's cycle counts (Decoder.IntCycles, from the instruction tables) run at fOSC/4 = 2.5 MHz, and the timers divide that by 8 = 312.5 kHz: at exactly that rate the ROMs' crank-period word reads 1,875,000 / rpm and a timer tick is 3.2 us - the tuning software's own rpm and injector scalings - and the boot delay lasts about as long as the check-engine light stays on at key-on (~4.5 s). The active ProcessorProfile sets both numbers.
    public static double CrystalMHz { get; private set; } = 10.0;
    /// Rate of the simulator's machine cycles, Hz (fOSC / 4).
    public static ulong CpuHz { get; private set; } = 2_500_000;
    /// Machine cycles per microsecond.
    public static double CyclesPerUs => CpuHz / 1_000_000.0;
    /// A/D conversion time: the MSM66207 manual specifies 64us per conversion (at 10 MHz).
    public static uint AdcConversionCycles => (uint)(64 * CyclesPerUs);

    /// Oscillator clocks per machine cycle.
    public static int ClockDivider { get; private set; } = 4;

    /// Change the crystal (and the clocks per machine cycle). Affects simulators created or reset afterwards.
    public static void SetCrystal(double mhz, int divider = 4)
    {
        CrystalMHz = mhz;
        ClockDivider = Math.Max(1, divider);
        CpuHz = (ulong)(mhz * 1_000_000 / ClockDivider);
    }

    // SFR offsets
    public const ushort SfrAssp = 0x00;
    public const ushort SfrAlrb = 0x02;
    public const ushort SfrPsw = 0x04;
    public const ushort SfrAcc = 0x06;
    public const ushort SfrIrq = 0x18;
    public const ushort SfrIe = 0x1A;
    public const ushort SfrExion = 0x1C;

    // IRQ/IE bit numbers correspond one-for-one with the 16 maskable
    // vector-table entries at code addresses 0x0008..0x0027.
    public const int IrqInt0 = 0;
    public const int IrqSerialRx = 1;
    public const int IrqStgen = 3;
    public const int IrqTm0Ovf = 4;
    public const int IrqTm0 = 5;
    public const int IrqTm1 = 7;
    public const int IrqTm2Ovf = 8;
    public const int IrqTm2 = 9;
    public const int IrqTm3 = 11;
    public const int IrqAdc = 12;
    public const int IrqPwm = 13;
    public const int IrqInt1 = 15;

    // Ports. Each port has a data register, a mode register (PxIO: 1 = output,
    // 0 = input; reset 00H) and, for P2..P4, a secondary-function register
    // (PxSF: 1 = the pin is driven by the on-chip peripheral).
    public const ushort SfrP0 = 0x20;
    public const ushort SfrP0Io = 0x21;
    public const ushort SfrP1 = 0x22;
    public const ushort SfrP1Io = 0x23;
    public const ushort SfrP2 = 0x24;
    public const ushort SfrP2Io = 0x25;
    public const ushort SfrP2Sf = 0x26;
    public const ushort SfrP3 = 0x28;
    public const ushort SfrP3Io = 0x29;
    public const ushort SfrP3Sf = 0x2A;
    public const ushort SfrP4 = 0x2C;
    public const ushort SfrP4Io = 0x2D;
    public const ushort SfrP4Sf = 0x2E;
    public const ushort SfrP5 = 0x2F;

    private readonly struct PortDef
    {
        public readonly ushort Data, Mode;
        public readonly ushort? Sf;
        public PortDef(ushort data, ushort mode, ushort? sf) { Data = data; Mode = mode; Sf = sf; }
    }

    private static readonly PortDef[] Ports =
    {
        new(SfrP0, SfrP0Io, null),
        new(SfrP1, SfrP1Io, null),
        new(SfrP2, SfrP2Io, SfrP2Sf),
        new(SfrP3, SfrP3Io, SfrP3Sf),
        new(SfrP4, SfrP4Io, SfrP4Sf),
    };

    /// Index into PortPins for P4.
    public const int Port4 = 4;
    /// P4.1 is wired as a plain GPIO input on the P28 board. Low = running, high = "power is going away, shut down" (polled by the ROM's NMI path).
    public const byte P4RunSense = 1;

    public const ushort SfrTm0 = 0x30;
    public const ushort SfrTmr0 = 0x32;
    public const ushort SfrTm1 = 0x34;
    public const ushort SfrTmr1 = 0x36;
    public const ushort SfrTm2 = 0x38;
    public const ushort SfrTmr2 = 0x3A;
    public const ushort SfrTm3 = 0x3C;
    public const ushort SfrTmr3 = 0x3E;

    public const ushort SfrTcon0 = 0x40;
    public const ushort SfrTcon1 = 0x41;
    public const ushort SfrTcon2 = 0x42;
    public const ushort SfrTcon3 = 0x43;

    /// Transition-detector status register. On the P28 board the distributor's CYP (cylinder-position) signal drives TRNS0/P4.4, so bit 0 is the once-per-camshaft-revolution cylinder-#1 marker.
    public const ushort SfrTrns = 0x46;

    public const ushort SfrAdscan = 0x58;
    public const ushort SfrAdsel = 0x59;
    public const ushort SfrAdcr0 = 0x60;

    /// P28 board-level CD4051 banks. U6 feeds P5.0/AI0 (ADCR0), U5 feeds P5.1/AI1 (ADCR1). Both share A/B/C selects on P2.5/P2.6/P2.7. The ROM's background scan stores mux channel n of ADCR0 at 0x3CA+n and of ADCR1 at 0x3D2+n (the 115 ROM layout); what each channel carries is read from the code that consumes those slots:
    public const int P28MuxU6Adcr0 = 0;
    public const int P28MuxU5Adcr1 = 1;

    /// ADCR0 mux 0: coolant temperature (ECT), sampled at every TDC.
    public const int P28U6EctSelect = 0;
    /// ADCR0 mux 3: barometric pressure.
    public const int P28U6BaroSelect = 3;
    /// ADCR0 mux 7: intake air temperature (IAT).
    public const int P28U6IatSelect = 7;
    /// ADCR1 mux 0: primary O2 sensor -- the O2 selector's default source.
    public const int P28U5HegoSelect = 0;

    /// Direct (unmultiplexed) P5 analog inputs on the P28 board.
    public const int P28AdcEgr = 3;
    /// Spare analog input: unconnected on a stock board (reads 0 V), kept inactive by default.
    public const int P28AdcAux = 4;
    /// Battery voltage (as in the original model; not independently traced).
    public const int P28AdcBattery = 5;
    public const int P28AdcMap = 6;
    public const int P28AdcTps = 7;

    public const ushort SfrPwmc0 = 0x70;
    public const ushort SfrPwmr0 = 0x72;
    public const ushort SfrPwmc1 = 0x74;
    public const ushort SfrPwmr1 = 0x76;
    public const ushort SfrPwcon0 = 0x78;
    public const ushort SfrPwcon1 = 0x7A;

    public const ushort SfrSrbuf = 0x55;
    public const ushort SfrStbuf = 0x51;

    public byte[] Rom = new byte[RomSize];
    public byte[] Ram = new byte[RamSize];

    /// Direct MCU ADC-pin levels (P5.0..P5.7). P28 channels 0 and 1 are driven by the external muxes below and do not sample these two array entries.
    public ushort[] AdcInputs = new ushort[8];

    /// External P28 analog mux inputs, indexed [U6/U5][select].
    public ushort[][] P28MuxInputs = { new ushort[8], new ushort[8] };

    public ulong ElapsedCycles;

    // Board outputs, decoded from the port pins the ROMs drive. Each mapping
    // is taken from the ROM code that drives it:
    //   P0.7      fuel pump relay, active low ("fuelpump_relay_drive: MB P0.7, C";
    //             held low whenever the ROM sees the engine turning, high at key-on
    //             once the prime time has run out)
    //   P1.0      VTEC solenoid, active high (vtec_highcam_output / _force_on)
    //   P2.0-P2.3 injectors 1-4, active low (injenable_p2_update opens,
    //             int_timer_0 / inj_p2_drive_return close)
    //   P2.4      watchdog heartbeat, toggled by every ResetWatchDog call
    //   P2.5-P2.7 analog mux select A/B/C
    public bool FuelPumpActive => IsOutput(0, 7) && !Latch(0, 7);
    public bool VtecSolenoidActive => IsOutput(1, 0) && Latch(1, 0);
    public bool InjectorOpen(int n) => IsOutput(2, n) && !Latch(2, n);

    // Injector pulse width. P2.0-P2.3 only select the injector: the ROM pulls
    // the line low, sets TMR0 = TM0 + pulse width in the same routine, and
    // raises the line again within ~50 us. The injection event ends at that
    // timer-0 compare match, so the pulse is measured from the select edge to
    // the next TM0 match.
    readonly ulong?[] _injSelectedAt = new ulong?[4];
    /// Last measured pulse width per injector, microseconds.
    public readonly uint[] InjectorPulseUs = new uint[4];
    /// Injection events per injector since reset.
    public readonly long[] InjectorEvents = new long[4];
    /// Cycle count of each injector's last injection event.
    public readonly ulong[] InjectorLastEventAt = new ulong[4];
    /// Most recent pulse width on any injector, microseconds.
    public uint InjectorPulseWidthUs;
    /// Timer-3 compare matches (coil firings) since reset, and when the last one was.
    public long IgnitionEvents;
    public ulong LastIgnitionAt;
    public float IacvDutyCyclePct;

    /// VTEC oil-pressure switch input on P4.6 ("vtec_oilpressure_pin_check: MB C, P4.6"). True = pressure present, which the ROM reads as a low pin.
    public bool VtecPressureSwitch = true;

    /// Activity of every port pin: level, when it last changed, how long its last high and low phases lasted, and which instruction drove it.
    public readonly PinActivity Pins = new();

    bool IsOutput(int port, int bit) => (Ram[Ports[port].Mode] >> bit & 1) != 0;
    bool Latch(int port, int bit) => (Ram[Ports[port].Data] >> bit & 1) != 0;

    /// PC of the instruction being executed, for PinActivity's "driven by".
    public ushort CurrentPc;

    /// PWM0/PWM1 output pin state, surfaced on P4.2 / P4.3.
    public bool[] PwmOut = new bool[2];

    /// Fractional prescaler remainder for TM0..TM3.
    public uint[] TimerAccum = new uint[4];


    /// Remaining machine cycles in the current A/D conversion.
    public uint? AdcCyclesRemaining;

    /// Levels driven onto P0..P4 from outside the chip. Only consulted for bits the ROM has configured as inputs.
    public byte[] PortPins = new byte[5];

    /// The harness driving those pins. Null keeps the original behaviour (PortPins consulted directly), so nothing that predates Board changes.
    public Board? Board;

    /// Called on every data-space read, with the address. StallMonitor uses it to learn which locations a spinning loop is polling. Null by default; the null check is the entire cost when unused.
    public Action<ushort>? OnDataRead;

    /// Called after every data-space write with (address, old value, new value). Used to trace which code drives which port pin.
    public Action<ushort, byte, byte>? OnDataWrite;

    /// Machine cycles left before the current serial transmission completes. A byte written to STBUF is "on the wire" until then, at which point the transmit-complete interrupt (IRQ bit 2) is raised -- without this the ROM's datalogging path waits on a flag that never arrives.
    public uint? SerialTxCyclesRemaining;

    /// Bit-time for the modeled UART, in machine cycles. 10 bits at the diagnostic link's 10,400 baud is ~960us; the exact rate only matters for relative timing, so this stays a single tunable.
    public uint SerialByteCycles = (uint)(960 * CyclesPerUs);

    /// Serial transmit-complete interrupt, vector-table slot 2 (int_serial_tx_vec at code address 0x000C).
    public const int IrqSerialTx = 2;

    /// Watchdog. The ROM refreshes it in ResetWatchDog by writing 3Ch then C3h to SFR 0x11; if that stops happening the real chip resets through the WDT vector. Off by default -- turning it on is how you exercise the WDT recovery path deliberately.
    public const ushort SfrWdt = 0x11;
    public bool WatchdogEnabled;
    public uint WatchdogTimeoutCycles = (uint)(200 * 1000 * CyclesPerUs); // 200ms
    public uint WatchdogCyclesRemaining;
    public bool WatchdogTripped;
    private byte _wdtSequence;

    // Serial datalogging UART buffers
    public System.Collections.Generic.List<byte> SerialRxQueue = new();
    public System.Collections.Generic.List<byte> SerialTxQueue = new();

    public Bus()
    {
        Array.Fill(Rom, (byte)0xFF);
        Array.Fill(AdcInputs, (ushort)512); // ~2.5V mid-scale default
        Array.Fill(P28MuxInputs[0], (ushort)512);
        Array.Fill(P28MuxInputs[1], (ushort)512);
        WriteDataU16(SfrAssp, 0x07FE);
    }

    public void LoadRomFile(string path)
    {
        var data = File.ReadAllBytes(path);
        byte[] image;
        if (data.Length == RomSize) image = data;
        else if (data.Length == RomSize + 1 && data[RomSize] == 0) image = data[..RomSize];
        else throw new InvalidDataException(
            $"expected a {RomSize}-byte ROM image (optionally followed by one 00 byte), got {data.Length} bytes");
        Array.Copy(image, Rom, RomSize);
    }

    public void LoadRomBytes(byte[] image)
    {
        if (image.Length == RomSize) Array.Copy(image, Rom, RomSize);
        else if (image.Length == RomSize + 1 && image[RomSize] == 0) Array.Copy(image, Rom, RomSize);
        else throw new InvalidDataException(
            $"expected a {RomSize}-byte ROM image (optionally followed by one 00 byte), got {image.Length} bytes");
    }

    /// The P28 board's 8255 PPI on the external data bus (internal RAM ends at 047Fh): 0F00h port A, 1F00h port B, 2F00h port C, 3F00h control (A12-A13 select the register). The ROMs write control word 90h (A input, B and C output), copy P0 to port B and P1 to port C (reading them back to verify), and read switch inputs from port A.
    public readonly Ppi8255 Ppi = new();
    public static bool IsPpi(ushort addr) => addr >= 0x0480 && (addr & 0x0FFF) == 0x0F00;

    // Code space read (ROM)
    public byte ReadCodeU8(ushort addr) => Rom[addr & (RomSize - 1)];

    /// ROM data reads made by instructions (LC/LCB and the other code-space operands: the table and constant fetches), per byte: how many, and the machine cycle of the last one. Opcode fetches are not counted here (Coverage has those).
    public readonly uint[] RomReadCount = new uint[RomSize];
    public readonly ulong[] RomReadAt = new ulong[RomSize];
    /// The most recent ROM data reads, oldest overwritten first: (address, instruction PC).
    public readonly (ushort Address, ushort Pc)[] RomReadLog = new (ushort, ushort)[4096];
    /// Total ROM data reads so far; RomReadLog[(n - 1) % Length] is the latest.
    public long RomReadTotal;
    /// Cycle count of the CPU, kept current by the simulator so reads can be time-stamped.
    public ulong NowCycles;

    public void NoteRomRead(ushort addr, int len)
    {
        for (int i = 0; i < len; i++)
        {
            int a = (addr + i) & (RomSize - 1);
            if (RomReadCount[a] < uint.MaxValue) RomReadCount[a]++;
            RomReadAt[a] = NowCycles;
        }
        RomReadLog[RomReadTotal++ % RomReadLog.Length] = ((ushort)(addr & (RomSize - 1)), CurrentPc);
    }

    public void ClearRomReads()
    {
        Array.Clear(RomReadCount); Array.Clear(RomReadAt); RomReadTotal = 0;
    }

    public ushort ReadCodeU16(ushort addr)
    {
        ushort l = ReadCodeU8(addr);
        ushort h = ReadCodeU8((ushort)(addr + 1));
        return (ushort)(l | (h << 8));
    }

    // Data space read (RAM & SFRs)
    public byte ReadDataU8(ushort addr)
    {
        int idx = addr & (RamSize - 1);
        OnDataRead?.Invoke(addr);

        if (IsPpi(addr)) return Ppi.Read((addr >> 12) & 3);
        if (addr == SfrSrbuf)
        {
            if (SerialRxQueue.Count > 0)
            {
                byte b = SerialRxQueue[0];
                SerialRxQueue.RemoveAt(0);
                return b;
            }
        }
        else if (addr == SfrP2Sf)
        {
            // P2SF bits 0..2 are hardwired; reset value 07H, and the ROM's
            // periodic integrity check requires it to read back 007h.
            return (byte)(Ram[SfrP2Sf] | 0x07);
        }

        for (int p = 0; p < Ports.Length; p++)
        {
            if (Ports[p].Data == addr) return ReadPort(p);
        }

        return Ram[idx];
    }

    /// Read a port the way the silicon does, one bit at a time:
    /// * secondary function enabled -> the on-chip peripheral drives the pin
    /// * else configured as output  -> the port's own output latch
    /// * else                       -> the external level on the pin
    public byte ReadPort(int port)
    {
        var def = Ports[port];
        byte latch = Ram[def.Data];
        byte dir = Ram[def.Mode];
        byte sfBits = 0;
        if (def.Sf is ushort sfAddr)
        {
            byte raw = Ram[sfAddr];
            // P2SF bits 0..2 are unimplemented: they read back as 1 (see
            // ReadDataU8) but P2.0-P2.2 have no secondary function, so the pins
            // stay ordinary port bits. Treating them as SF-enabled made every
            // read of P2 -- including the read half of the ROM's ANDB/ORB P2
            // read-modify-writes -- return the external level instead of the
            // latch, which shut injectors 1-3 the moment they were opened.
            sfBits = sfAddr == SfrP2Sf ? (byte)(raw & 0xF8) : raw;
        }
        byte pins = PortPins[port];

        byte v = 0;
        for (int bit = 0; bit < 8; bit++)
        {
            byte m = (byte)(1 << bit);
            bool level;
            if ((sfBits & m) != 0)
            {
                // Secondary function enabled. If the on-chip peripheral
                // drives the pin (PWM out), take its level. Otherwise the
                // secondary function is an INPUT one -- TM0CK/TM1CK on
                // P4.0/P4.1, TRNS0-3 on P4.4-7 -- and the pin is still being
                // driven from outside, so read the external level. Falling
                // back to the output latch here made every such pin read
                // back whatever the ROM last wrote to the port, which is why
                // P4.1 (the run/power-good sense) read high and sent the ROM
                // into its shutdown path on every boot.
                level = SecondaryFnLevel(port, bit)
                        ?? InputLevel(port, bit)
                        ?? ((pins & m) != 0);
            }
            else if ((dir & m) != 0)
            {
                level = (latch & m) != 0;
            }
            else
            {
                level = InputLevel(port, bit) ?? ((pins & m) != 0);
            }
            if (level) v |= m;
        }
        return v;
    }

    /// Named external inputs, for pins whose harness signal this model tracks as a field rather than as a raw bit in PortPins. Only consulted when the ROM has left the pin configured as an input.
    private bool? InputLevel(int port, int bit)
    {
        if (Board != null) return Board.InputLevel(port, bit);
        return (port, bit) switch { (4, 6) => !VtecPressureSwitch, _ => null };
    }

    /// Level driven by the on-chip peripheral assigned to a pin. Port 4's map: P4.0/TM0CK, P4.1/TM1CK, P4.2/PWM0, P4.3/PWM1, P4.4-7/TRNS0-3. Only the two PWM outputs are driven from inside the chip in this model.
    private bool? SecondaryFnLevel(int port, int bit) =>
        (port, bit) switch
        {
            (Port4, 2) => PwmOut[0],
            (Port4, 3) => PwmOut[1],
            _ => null,
        };

    public ushort ReadDataU16(ushort addr)
    {
        ushort l = ReadDataU8(addr);
        ushort h = ReadDataU8((ushort)(addr + 1));
        return (ushort)(l | (h << 8));
    }

    // Data space write (RAM & SFRs)
    public void WriteDataU8(ushort addr, byte val)
    {
        // ADCR0..ADCR7 are read-only. Conversion completion updates their
        // backing latches directly in TriggerAdcConversion.
        if (addr >= SfrAdcr0 && addr < SfrAdcr0 + 16) return;

        if (IsPpi(addr))
        {
            int reg = (addr >> 12) & 3;
            byte prev = Ppi.Read(reg);
            Ppi.Write(reg, val);
            OnDataWrite?.Invoke(addr, prev, val);
            return;
        }
        int idx = addr & (RamSize - 1);
        byte old = Ram[idx];
        Ram[idx] = val;
        OnDataWrite?.Invoke(addr, old, val);


        if (addr == SfrAdscan)
        {
            // ADSCAN.4 is the start/scan bit.
            AdcCyclesRemaining = (val & 0x10) != 0 ? AdcConversionCycles : (uint?)null;
        }
        else if (addr is >= SfrP0 and <= SfrP4Sf)
        {
            UpdatePins();
        }
        else if (addr == SfrStbuf)
        {
            SerialTxQueue.Add(val);
            if (SerialTxQueue.Count > 8192) SerialTxQueue.RemoveRange(0, SerialTxQueue.Count - 4096);
            // The byte is in flight; TickTimers raises the transmit-complete
            // interrupt when it lands.
            SerialTxCyclesRemaining = SerialByteCycles;
        }
        else if (addr == SfrWdt)
        {
            // ResetWatchDog writes 3Ch then (after SWAPB) C3h. Either half of
            // the sequence restarts the timer in this model -- the ROM never
            // writes the register any other way.
            if (val == 0x3C) _wdtSequence = 0x3C;
            else if (val == 0xC3 && _wdtSequence == 0x3C) _wdtSequence = 0;
            WatchdogCyclesRemaining = WatchdogTimeoutCycles;
            WatchdogTripped = false;
        }
    }

    /// Re-evaluate every port pin's driven level and log any change.
    void UpdatePins()
    {
        for (int p = 0; p < Ports.Length; p++)
            Pins.Update(p, ReadPort(p), Ram[Ports[p].Mode], ElapsedCycles, CurrentPc);
        for (int n = 0; n < 4; n++)
        {
            if (!IsOutput(2, n)) continue;
            if (Pins.JustFell(2, n)) _injSelectedAt[n] = ElapsedCycles;
            else if (Pins.JustRose(2, n) && _injSelectedAt[n] is ulong at)
            {
                // At higher load the ROM selects two injectors on one edge and releases one
                // straight away; that partner never injects. At light load the single
                // selected line is also released early but that one is the real event.
                for (int m = 0; m < 4; m++)
                    if (m != n && _injSelectedAt[m] == at && InjectorOpen(m)) { _injSelectedAt[n] = null; break; }
            }
        }
    }

    /// A TM0 match ends one injection event. If any selected line is still held low, the event is the oldest held one: int_timer_0 chains close events in firing order, so when pulses overlap (longer than a TDC interval) the earliest select closes first. If no line is held (light load: the ROM releases the select line at once), the event belongs to the newest select and anything older is a leftover partner.
    void EndInjectorPulses()
    {
        int pick = -1;
        for (int n = 0; n < 4; n++)
            if (_injSelectedAt[n] is ulong t && InjectorOpen(n) && (pick < 0 || t < _injSelectedAt[pick]!.Value)) pick = n;
        if (pick < 0)
        {
            for (int n = 0; n < 4; n++)
                if (_injSelectedAt[n] is ulong t && (pick < 0 || t > _injSelectedAt[pick]!.Value)) pick = n;
            if (pick < 0) return;
            ulong newest = _injSelectedAt[pick]!.Value;
            for (int n = 0; n < 4; n++)
                if (n != pick && _injSelectedAt[n] is ulong t && t < newest) _injSelectedAt[n] = null;
        }
        ulong start = _injSelectedAt[pick]!.Value;
        _injSelectedAt[pick] = null;
        ulong cycles = ElapsedCycles - start;
        if (cycles > CpuHz / 2) return;   // stale select (engine stopped), not a pulse
        InjectorPulseUs[pick] = InjectorPulseWidthUs = (uint)(cycles / CyclesPerUs);
        InjectorEvents[pick]++;
        InjectorLastEventAt[pick] = start;
        // Injector-drive feedback on TRNS2: the ROMs clear it when they open an
        // injector ("ANDB TRNSIT, #0FBh") and check it afterwards.
        Ram[SfrTrns] |= 0x04;
    }

    public void WriteDataU16(ushort addr, ushort val)
    {
        WriteDataU8(addr, (byte)(val & 0xFF));
        WriteDataU8((ushort)(addr + 1), (byte)((val >> 8) & 0xFF));
    }

    /// A/D conversion result for a channel, in the layout the ROM expects: the 10-bit result left-justified in a 16-bit register (bits 15..6).
    public ushort AdcResult(int channel) => (ushort)((AdcInput(channel) & 0x03FF) << 6);

    /// Resolve the voltage present at an MCU analog pin. The ROM drives the shared P28 mux select through P2.5..P2.7.
    public ushort AdcInput(int channel)
    {
        if (channel is 0 or 1)
        {
            int select = (ReadPort(2) >> 5) & 0x07;
            return P28MuxInputs[channel][select];
        }
        return AdcInputs[channel];
    }

    public void TriggerAdcConversion()
    {
        for (int i = 0; i < 8; i++)
        {
            ushort val = AdcResult(i);
            ushort addr = (ushort)(SfrAdcr0 + i * 2);
            Ram[addr] = (byte)(val & 0xFF);
            Ram[addr + 1] = (byte)(val >> 8);
        }
    }

    /// Latch a CYP (cylinder-#1) transition on TRNS0, exactly as the transition detector does when the distributor's CYP signal edges on P4.4. The ROM read-clears SFR_TRNS bit 0 in its TDC ISR.
    public void SignalCyp() => Ram[SfrTrns] |= 0x01;

    /// TM2 capture: the crank-angle (CKP) edge latches the free-running TM2 count into TMR2. TMR2 is therefore a capture register on this board, not a compare register, and timer 2 raises no compare-match interrupt.
    public void CaptureTm2()
    {
        Ram[SfrTmr2] = Ram[SfrTm2];
        Ram[SfrTmr2 + 1] = Ram[SfrTm2 + 1];
    }

    public ushort PushSerialRxByte(byte b)
    {
        SerialRxQueue.Add(b);
        return 1 << IrqSerialRx;
    }

    // Bytes on their way in over the serial line, each arriving at its machine-cycle time
    // (the receive interrupt is raised as each one lands, like the real UART).
    readonly Queue<(byte B, ulong At)> _rxIncoming = new();
    ulong _rxLastAt;

    /// Send bytes to the ROM's serial port, as a datalogging tool on the other end of the cable would: one every `cyclesPerByte` (10 bit times at the link's baud rate).
    public void QueueSerialRx(IEnumerable<byte> bytes, uint cyclesPerByte)
    {
        ulong t = Math.Max(ElapsedCycles, _rxLastAt);
        foreach (var b in bytes) { t += cyclesPerByte; _rxIncoming.Enqueue((b, t)); }
        _rxLastAt = t;
    }

    /// Everything the ROM has transmitted since the last call.
    public byte[] TakeSerialTx()
    {
        var b = SerialTxQueue.ToArray();
        SerialTxQueue.Clear();
        return b;
    }

    // Hardware timer step
    public ushort TickTimers(uint cycles)
    {
        ElapsedCycles += cycles;

        // (counter SFR, reload SFR, control SFR, IRQ bit)
        var timers = new (ushort tm, ushort tmr, ushort tcon, int irq)[]
        {
            (SfrTm0, SfrTmr0, SfrTcon0, IrqTm0),
            (SfrTm1, SfrTmr1, SfrTcon1, IrqTm1),
            (SfrTm2, SfrTmr2, SfrTcon2, IrqTm2),
            (SfrTm3, SfrTmr3, SfrTcon3, IrqTm3),
        };

        ushort irqFlags = 0;

        // 16-bit PWM: the counter counts up, and on overflow reloads from the
        // PWM register and flips the output pin.
        var pwmRegs = new (ushort c, ushort r)[] { (SfrPwmc0, SfrPwmr0), (SfrPwmc1, SfrPwmr1) };
        bool pwmToggled = false;
        for (int i = 0; i < pwmRegs.Length; i++)
        {
            var (c, r) = pwmRegs[i];
            // Rust truncates `cycles` to u16 before the add (overflowing_add
            // on a u16 counter); mirror that so multi-instruction batches
            // wrap identically.
            ushort cyclesU16 = (ushort)cycles;
            uint sum0 = (uint)ReadDataU16(c) + cyclesU16;
            bool overflow = sum0 > 0xFFFF;
            ushort wrapped = (ushort)sum0;
            ushort v;
            if (overflow)
            {
                PwmOut[i] = !PwmOut[i];
                pwmToggled = true;
                irqFlags |= (ushort)(1 << IrqPwm);
                v = (ushort)(ReadDataU16(r) + wrapped);
            }
            else
            {
                v = wrapped;
            }
            Ram[c] = (byte)(v & 0xFF);
            Ram[c + 1] = (byte)(v >> 8);
        }

        if (pwmToggled) UpdatePins();

        while (_rxIncoming.Count > 0 && _rxIncoming.Peek().At <= ElapsedCycles)
        {
            SerialRxQueue.Add(_rxIncoming.Dequeue().B);
            irqFlags |= (ushort)(1 << IrqSerialRx);
        }

        if (SerialTxCyclesRemaining is uint txLeft)
        {
            if (cycles >= txLeft)
            {
                SerialTxCyclesRemaining = null;
                irqFlags |= (ushort)(1 << IrqSerialTx);
            }
            else
            {
                SerialTxCyclesRemaining = txLeft - cycles;
            }
        }

        if (WatchdogEnabled)
        {
            if (WatchdogCyclesRemaining == 0) WatchdogCyclesRemaining = WatchdogTimeoutCycles;
            if (cycles >= WatchdogCyclesRemaining)
            {
                WatchdogTripped = true;
                WatchdogCyclesRemaining = WatchdogTimeoutCycles;
            }
            else
            {
                WatchdogCyclesRemaining -= cycles;
            }
        }

        if (AdcCyclesRemaining is uint remaining)
        {
            if (cycles >= remaining)
            {
                TriggerAdcConversion();
                irqFlags |= (ushort)(1 << IrqAdc);
                AdcCyclesRemaining = (Ram[SfrAdscan] & 0x10) != 0 ? AdcConversionCycles : (uint?)null;
            }
            else
            {
                AdcCyclesRemaining = remaining - cycles;
            }
        }

        for (int i = 0; i < timers.Length; i++)
        {
            var (tmSfr, tmrSfr, tconSfr, irqBit) = timers[i];
            byte tcon = Ram[tconSfr];
            // TCON bit 4 is the run bit; a stopped timer neither counts nor
            // toggles its pin.
            if ((tcon & (1 << 4)) == 0) continue;

            // Prescaler (in machine cycles). Only encodings 00b (/8) and 01b (/2,
            // timer 1's 4x-faster rate) are attested by the P28 ROMs.
            uint div = ((tcon >> 5) & 0x03) switch
            {
                0b00 => 8u,
                0b01 => 2u,
                var other => (uint)(8 >> Math.Min(other, 3)),
            };
            // One prescaler feeds every timer, so timers on the same division tick on the
            // same machine cycles (the ROMs' boot self-test checks TM2 and TM3 agree).
            uint steps = (uint)(ElapsedCycles / div - (ElapsedCycles - cycles) / div);
            if (steps == 0) continue;

            ushort tm = ReadDataU16(tmSfr);
            ushort tmr = ReadDataU16(tmrSfr);
            // Rust truncates `steps` to u16 before the add; mirror that.
            ushort stepsU16 = (ushort)steps;
            uint sum = (uint)tm + stepsU16;
            bool overflow = sum > 0xFFFF;
            ushort newTm = (ushort)sum;
            // TMR is a compare register, not a reload value; TM keeps free
            // running after a match.
            bool matched = overflow ? (tm < tmr || newTm >= tmr) : (tm < tmr && newTm >= tmr);
            WriteDataU16(tmSfr, newTm);

            // TMR2 holds the CKP capture (see CaptureTm2), so timer 2 has no
            // compare event of its own; its interrupt comes from the capture.
            if (matched && i != 2) irqFlags |= (ushort)(1 << irqBit);
            if (matched && i == 0) EndInjectorPulses();
            // Igniter feedback: each timer-3 compare fires the coil, and the
            // igniter's confirmation pulse comes back on TRNS1. The ROMs test
            // "RB TRNSIT.1" once per TDC and log code 15 (ignition output)
            // when it has not latched.
            if (matched && i == 3) { Ram[SfrTrns] |= 0x02; IgnitionEvents++; LastIgnitionAt = ElapsedCycles; }
            // Every timer also raises a counter-overflow interrupt on the even
            // bit just below its event bit.
            if (overflow) irqFlags |= (ushort)(1 << (irqBit - 1));
        }

        if (irqFlags != 0)
        {
            ushort irq = (ushort)(Ram[SfrIrq] | (Ram[SfrIrq + 1] << 8) | irqFlags);
            Ram[SfrIrq] = (byte)(irq & 0xFF);
            Ram[SfrIrq + 1] = (byte)(irq >> 8);
        }

        return irqFlags;
    }
}

/// Per-pin history for P0..P4, updated whenever a port, its direction or its secondary-function register is written (and when a PWM output toggles).
public sealed class PinActivity
{
    public readonly byte[] Level = new byte[5];
    public readonly byte[] Direction = new byte[5];
    public readonly ulong[,] LastChange = new ulong[5, 8];
    public readonly ulong[,] LastHighCycles = new ulong[5, 8];
    public readonly ulong[,] LastLowCycles = new ulong[5, 8];
    public readonly long[,] Changes = new long[5, 8];
    public readonly ushort[,] LastDriverPc = new ushort[5, 8];
    readonly bool[,] _rose = new bool[5, 8];
    readonly bool[,] _fell = new bool[5, 8];

    internal void Update(int port, byte level, byte dir, ulong now, ushort pc)
    {
        byte diff = (byte)(level ^ Level[port]);
        Direction[port] = dir;
        for (int b = 0; b < 8; b++)
        {
            _rose[port, b] = false;
            _fell[port, b] = false;
            if ((diff >> b & 1) == 0) continue;
            ulong held = now - LastChange[port, b];
            bool nowHigh = (level >> b & 1) != 0;
            if (nowHigh) { LastLowCycles[port, b] = held; _rose[port, b] = true; }
            else { LastHighCycles[port, b] = held; _fell[port, b] = true; }
            LastChange[port, b] = now;
            Changes[port, b]++;
            LastDriverPc[port, b] = pc;
        }
        Level[port] = level;
    }

    internal bool JustRose(int port, int bit) => _rose[port, bit];
    internal bool JustFell(int port, int bit) => _fell[port, bit];
}

/// Intel 8255 programmable peripheral interface, as far as the P28 uses it (mode 0).
public sealed class Ppi8255
{
    /// Port A pins as the board drives them (switch inputs). Bits 3-5 read inverted by the ROM (XOR 38h), so 38h is "all switches off".
    public byte PortAInput = 0x38;
    public byte PortB, PortC;
    public byte Control = 0x9B;           // reset: every port an input
    public long Writes;

    bool AIn => (Control & 0x10) != 0;

    public byte Read(int reg) => reg switch
    {
        0 => AIn ? PortAInput : PortA,
        1 => PortB,
        2 => PortC,
        _ => 0xFF,                         // the control register cannot be read back
    };
    byte PortA;

    public void Write(int reg, byte v)
    {
        Writes++;
        switch (reg)
        {
            case 0: PortA = v; break;
            case 1: PortB = v; break;
            case 2: PortC = v; break;
            case 3:
                if ((v & 0x80) != 0) { Control = v; PortA = PortB = PortC = 0; }       // mode set clears the outputs
                else                                                                     // bit set/reset on port C
                {
                    int bit = (v >> 1) & 7;
                    PortC = (byte)((v & 1) != 0 ? PortC | (1 << bit) : PortC & ~(1 << bit));
                }
                break;
        }
    }
}
