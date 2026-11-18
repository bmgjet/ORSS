// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;
namespace OkiRomSim.Tests;
/// MSM66207 user manual, printed pp. 96-110. Both channels and all clock selectors.
/// Free-run follows the 16-bit description on p. 108. PWM0 was tested on an ECU.
static class PwmTests
{
    public static void Run()
    {
        ProcessorProfile.Msm66207().Apply();
        foreach (int ch in new[] { 0, 1 })
        {
            ushort counter = (ushort)(0x70 + 4 * ch), reload = (ushort)(counter + 2), control = (ushort)(0x78 + 2 * ch);
            var stopped = new Bus(); stopped.WriteDataU16(counter, 0x1234); stopped.TickTimers(4096); T.Check($"PWM{ch}: RUN=0 freezes count", stopped.ReadDataU16(counter) == 0x1234);
            foreach (int sel in new[] { 0, 1, 2, 3 })
            {
                int width = new[] { 8, 10, 12, 16 }[sel]; uint tap = 1u << width; ushort mask = (ushort)(tap - 1);
                var free = new Bus(); free.WriteDataU8(control, (byte)(0x54 | sel)); free.WriteDataU16(counter, 0xFFFF); free.WriteDataU16(reload, 0x1234);
                T.Check($"PWM{ch} free selector{sel}: selected TBC tap, no early clock", (free.TickTimers(tap - 1) & 0x2000) == 0 && free.ReadDataU16(counter) == 0xFFFF);
                T.Check($"PWM{ch} free selector{sel}: 16-bit overflow without reload", (free.TickTimers(1) & 0x2000) != 0 && free.ReadDataU16(counter) == 0 && (free.ReadDataU8(control) & 0x80) != 0);
                var phase = new Bus(); phase.TickTimers(tap - 1); phase.WriteDataU8(control, (byte)(0x14 | sel)); phase.TickTimers(1); T.Check($"PWM{ch} free selector{sel}: shared TBC phase survives RUN", phase.ReadDataU16(counter) == 1);
                var disabled = new Bus(); disabled.WriteDataU8(control, (byte)(0x14 | sel)); disabled.WriteDataU16(counter, 0xFFFF); T.Check($"PWM{ch} free selector{sel}: ERQ gates shared IRQ", (disabled.TickTimers(tap) & 0x2000) == 0 && disabled.ReadDataU16(counter) == 0);
                var auto = new Bus(); auto.WriteDataU8(control, (byte)(0x50 | sel)); auto.WriteDataU16(counter, mask); auto.WriteDataU16(reload, (ushort)(mask - 2)); auto.TickTimers(tap); T.Check($"PWM{ch} auto selector{sel}: selected width reloads", auto.ReadDataU16(counter) == mask - 2 && (auto.ReadDataU8(control) & 0x80) != 0);
                auto.TickTimers(tap * 8); T.Check($"PWM{ch} auto selector{sel}: repeated reloads preserve remainder", auto.ReadDataU16(counter) == mask);
                ushort old = auto.ReadDataU16(counter); auto.WriteDataU16(reload, 3); T.Check($"PWM{ch} auto selector{sel}: reload write does not reload counter", auto.ReadDataU16(counter) == old);
                auto.WriteDataU16(reload, 0x0012); T.Check($"PWM{ch} selector{sel}: unused PWMR bits read one", auto.ReadDataU16(reload) == (ushort)(0x12 | ~mask));
                foreach (bool invert in new[] { false, true })
                {
                    var pwm = new Bus(); pwm.WriteDataU8(control, (byte)(0x58 | sel | (invert ? 0x20 : 0))); pwm.WriteDataU16(counter, 7); pwm.WriteDataU16(reload, (ushort)(tap / 2)); pwm.TickTimers(tap);
                    T.Check($"PWM{ch} selector{sel} invert{invert}: period loads counter and starts active pulse", pwm.ReadDataU16(counter) == tap / 2 && pwm.PwmOut[ch] != invert);
                    pwm.TickTimers(tap / 2); T.Check($"PWM{ch} selector{sel} invert{invert}: overflow ends pulse", pwm.ReadDataU16(counter) == 0 && pwm.PwmOut[ch] == invert);
                }
            }
        }
        foreach (int ch in new[] { 0, 1 }) foreach (int sel in new[] { 0, 1, 2, 3 })
        {
            ushort c = (ushort)(0x70 + 4 * ch), r = (ushort)(c + 2), con = (ushort)(0x78 + 2 * ch); uint period = 1u << new[] { 8, 10, 12, 16 }[sel];
            var batched = new Bus(); var stepped = new Bus(); foreach (var b in new[] { batched, stepped }) { b.WriteDataU8(con, (byte)(0x58 | sel)); b.WriteDataU16(c, 13); b.WriteDataU16(r, (ushort)(period / 3)); }
            ushort irqA = batched.TickTimers(period * 3 + 17), irqB = 0; for (uint n = 0; n < period * 3 + 17; n++) irqB |= stepped.TickTimers(1);
            T.Check($"PWM{ch} selector{sel}: batching preserves counter, status and output", batched.ReadDataU16(c) == stepped.ReadDataU16(c) && batched.ReadDataU8(con) == stepped.ReadDataU8(con) && batched.PwmOut[ch] == stepped.PwmOut[ch] && irqA == irqB);
            var zero = new Bus(); zero.WriteDataU8(con, (byte)(0x18 | sel)); zero.WriteDataU16(r, 0); zero.TickTimers(period * 3); T.Check($"PWM{ch} selector{sel}: zero reload stays inactive at coincident boundary overflow", !zero.PwmOut[ch]);
            var snap = StateSnapshot.Capture(batched); var restored = new Bus(); Array.Copy(batched.Ram, restored.Ram, batched.Ram.Length); StateSnapshot.Restore(restored, snap); batched.TickTimers(period / 2); restored.TickTimers(period / 2); T.Check($"PWM{ch} selector{sel}: snapshot restores output flip-flop and phase", batched.PwmOut[ch] == restored.PwmOut[ch] && batched.ReadDataU16(c) == restored.ReadDataU16(c));
        }
        Chip.SetCrystal(10, 4); var divided = new Bus(); divided.WriteDataU8(0x7A, 0x55); divided.TickTimers(512); T.Check("PWM clock follows oscillator when instruction divider differs", divided.ReadDataU16(0x74) == 1); ProcessorProfile.Msm66207().Apply();
        var split = new Bus(); split.WriteDataU8(0x78, 0x54); split.WriteDataU8(0x7A, 0x55); split.WriteDataU16(0x70, 0xFFFF); split.WriteDataU16(0x74, 0xFFFF); split.TickTimers(256); T.Check("PWM sources retain separate status", (split.ReadDataU8(0x78) & 0x80) != 0 && (split.ReadDataU8(0x7A) & 0x80) == 0);
    }
}