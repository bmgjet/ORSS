// Copyright (c) bmgjet. All rights reserved.
using System.Runtime.InteropServices;

namespace OkiRomSim.Desktop;

/// Windows sleeps in steps of about 15 ms unless a program asks for finer ones, so the simulator's `Thread.Sleep(1)` between its 4 ms slices really slept 10-15 ms: three quarters of the time, at "unlimited" speed, was spent waiting. While the simulation runs the program asks for 1 ms steps (and gives them back when it stops, so an idle program does not keep the clock ticking). Elsewhere the call does nothing: Linux and macOS already sleep for about a millisecond.
static class HiResTimer
{
    [DllImport("winmm.dll", ExactSpelling = true)] static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll", ExactSpelling = true)] static extern uint timeEndPeriod(uint ms);

    public static void Begin()
    {
        if (!OperatingSystem.IsWindows()) return;
        try { timeBeginPeriod(1); } catch { }
    }

    public static void End()
    {
        if (!OperatingSystem.IsWindows()) return;
        try { timeEndPeriod(1); } catch { }
    }
}
