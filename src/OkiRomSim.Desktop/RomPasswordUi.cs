// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The ROM's open password (RomPassword): asked for before a ROM that has one is opened, and set or removed on the Watermark page.
public static class RomPasswordUi
{
    /// The text each password block (its salt and hash, as hex) was opened with or set to this session: for the Watermark page to show. Opening a ROM always asks again.
    static readonly Dictionary<string, string> Unlocked = [];

    /// The text a password block was opened with (or set to) this session, or null.
    public static string? KnownText(byte[] block) => Unlocked.GetValueOrDefault(Convert.ToHexString(block));

    static TextBox Masked(string hint) => new() { PasswordChar = '●', Width = 260, Watermark = hint, FontFamily = MainWindow.MonoFont };

    /// A ROM about to be opened: when it has a password set, ask for it (three tries). False: do not open it.
    public static async Task<bool> Unlock(Window owner, byte[] rom, string name)
    {
        int at = RomPassword.Locked(rom);
        if (at < 0) return true;
        var block = rom.AsSpan(at, RomPassword.Bytes).ToArray();
        var key = Convert.ToHexString(block);
        for (int attempt = 1; attempt <= 3; attempt++)
        {
            var box = Masked("password");
            string msg = $"{name} is protected with a password.\n\nEnter it to open the ROM." +
                         (attempt > 1 ? $"\n\nThat was not the password (try {attempt} of 3)." : "");
            if (!await Dialogs.Prompt(owner, "Password", msg, box, "Open")) return false;
            var typed = box.Text ?? "";
            bool ok = await Task.Run(() => RomPassword.Check(block, typed));     // the hash takes a moment on purpose
            if (ok)
            {
                Unlocked[key] = typed;
                AppLog.Action("app", $"{name}: opened with its password");
                return true;
            }
            AppLog.Warn("app", $"{name}: wrong password");
        }
        return false;
    }

    /// A new password, typed twice. Null: cancelled or they did not match.
    public static async Task<string?> AskNew(Window owner)
    {
        var first = Masked("new password");
        var again = Masked("the same again");
        var panel = new StackPanel { Spacing = 6, Children = { first, again } };
        if (!await Dialogs.Prompt(owner, "Set the open password",
                "OkiRomSim will ask for this before it opens the ROM (the .bin, its source, or a project holding it).\n" +
                "Only a salted hash of it is kept in the ROM - it cannot be read back, so keep a note of it.", panel, "Set")) return null;
        if ((first.Text ?? "") != (again.Text ?? "")) { await Dialogs.Ask(owner, "Password", "The two did not match: nothing was changed.", "OK"); return null; }
        return first.Text ?? "";
    }

    /// The watermark: its text is the ROM's open password. What is typed is applied as it is typed (after a short pause, and at once on Enter or on leaving the box): the password block gets a salted hash of it and the old scrambled copy of the text is blanked, so the text cannot be read back out of the ROM. Empty: no password.
    public static Control WatermarkEditor(SimHost host, ItemDef wm, Func<Window?> owner, Action<string> status)
    {
        var box = new TextBox { Width = 190, MaxLength = WatermarkCodec.Length, FontFamily = MainWindow.MonoFont, VerticalAlignment = VerticalAlignment.Center };
        var state = new TextBlock { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
        var pause = new Avalonia.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
        ItemDef? Block() => host.Defs().Items.FirstOrDefault(i => i.Text == "password" && i.Address == wm.Address + WatermarkCodec.Bytes)
                            ?? CalPage.Bound(host.Defs(), "watermark.password");
        string applied = "";
        bool showing = false;
        void Show()
        {
            showing = true;
            if (Block() is { } pw && RomPassword.IsSet(host.RomBytes(pw.Address, RomPassword.Bytes)))
            {
                var text = KnownText(host.RomBytes(pw.Address, RomPassword.Bytes));
                box.Text = applied = text ?? "";
                box.Watermark = text == null ? "set (type to change it)" : "";
                state.Text = "password set - asked for when the ROM is opened";
                state.Foreground = Brushes.LimeGreen;
            }
            else
            {
                var (text, intact) = WatermarkCodec.Decode(host.RomBytes(wm.Address, WatermarkCodec.Bytes));
                box.Text = applied = text;
                box.Watermark = "none";
                state.Text = text.Length == 0 ? "no password" : intact ? "not a password yet: press Enter" : "modified outside the app";
                if (text.Length > 0 && !intact) state.Foreground = Brushes.OrangeRed; else state.ClearValue(TextBlock.ForegroundProperty);
                if (text.Length > 0) applied = "";                    // an old plain watermark: Enter makes it the password
            }
            showing = false;
        }
        async void Apply()
        {
            pause.Stop();
            var text = box.Text ?? "";
            if (text == applied) return;
            applied = text;
            var pw = Block();
            try
            {
                if (pw == null)
                {
                    // an older watermark module, without the password block: the text only
                    host.WriteCells(wm, [.. WatermarkCodec.Encode(text).Select((b, i) => (i, (double)b))], true, $"\"{text}\"");
                    status("watermark written - this ROM's watermark module is older and has no password: update its skeleton to have one");
                    return;
                }
                var block = text.Length == 0 ? RomPassword.Cleared() : await Task.Run(() => RomPassword.Create(text));
                if ((box.Text ?? "") != text) return;                 // typed on since: that is applied next
                host.WriteCells(wm, [.. WatermarkCodec.Encode("").Select((b, i) => (i, (double)b))], true, "watermark");
                host.WriteCells(pw, [.. block.Select((b, i) => (i, (double)b))], true, text.Length == 0 ? "password removed" : "password set");
                if (text.Length > 0) Unlocked[Convert.ToHexString(block)] = text;
                status(text.Length == 0 ? "watermark removed: the ROM opens without a password"
                                        : "watermark set: OkiRomSim asks for it before opening this ROM (save the .bin, or build, to keep it)");
                AppLog.Action("calibration", text.Length == 0 ? "watermark / password removed" : "watermark / password set");
            }
            catch (Exception ex) { status(ex.Message); }
            Show();
        }
        pause.Tick += (_, _) => Apply();
        box.TextChanged += (_, _) => { if (!showing) { pause.Stop(); pause.Start(); } };
        box.LostFocus += (_, _) => Apply();
        box.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) Apply(); };
        ToolTip.SetTip(box, "Up to 16 characters. This is the ROM's password: OkiRomSim asks for it before it opens the ROM. " +
                            "Only a salted hash of it is kept, so keep a note of it. Empty: no password.");
        Show();
        return new StackPanel { Orientation = Orientation.Horizontal, Children = { box, state } };
    }

    /// The Watermark page's editor for the password block: whether one is set, and buttons to set, change or remove it.
    public static Control Editor(SimHost host, ItemDef it, Func<Window?> owner, Action<string> status)
    {
        var state = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Width = 110, FontSize = 12 };
        var set = new Button { Content = "Set password…", Padding = new Thickness(8, 1), MinHeight = 0, Margin = new Thickness(0, 0, 4, 0) };
        var remove = new Button { Content = "Remove", Padding = new Thickness(8, 1), MinHeight = 0 };
        void Show()
        {
            bool on = RomPassword.IsSet(host.RomBytes(it.Address, RomPassword.Bytes));
            state.Text = on ? "set" : "none";
            state.Foreground = on ? Brushes.LimeGreen : null;
            set.Content = on ? "Change…" : "Set password…";
            remove.IsEnabled = on;
        }
        void Write(byte[] block, string what)
        {
            try
            {
                host.WriteCells(it, [.. block.Select((b, i) => (i, (double)b))], true, what);
                // this session opened it: no asking again straight away
                if (RomPassword.IsSet(block)) Unlocked[Convert.ToHexString(block)] = "";
                status($"open password {what} - patched in the running ROM (save the .bin, or build, to keep it)");
                AppLog.Action("calibration", "open password " + what);
            }
            catch (Exception ex) { status(ex.Message); }
            Show();
        }
        set.Click += async (_, _) =>
        {
            if (owner() is not { } w) return;
            var pw = await AskNew(w);
            if (pw == null) return;
            if (pw.Length == 0) { Write(RomPassword.Cleared(), "removed"); return; }
            var block = await Task.Run(() => RomPassword.Create(pw));
            Write(block, "set");
        };
        remove.Click += async (_, _) =>
        {
            if (owner() is not { } w) return;
            if (await Dialogs.Confirm(w, "Remove the password?", "The ROM will open without asking.", "Remove", "Keep it"))
                Write(RomPassword.Cleared(), "removed");
        };
        ToolTip.SetTip(set, "OkiRomSim asks for the password before it opens this ROM. Only a salted hash is kept in the ROM.");
        Show();
        return new StackPanel { Orientation = Orientation.Horizontal, Children = { state, set, remove } };
    }
}
