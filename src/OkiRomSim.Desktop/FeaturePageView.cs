// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// One feature of the ECU on a page of its own, laid out the way the established tuning software lays it out: the input and output it is wired to in one box, the window of conditions that switches it in a two-column Minimum / Maximum grid, and the options as tick boxes underneath. Each row is bound to one of the ROM's definitions. That binding is what makes the page work on any ROM: the names in a disassembled image are not the ones a page could look for, so the page says what it needs ("the minimum rpm for GPO 1") and the binding says where that lives. The first time a page is opened the bindings are guessed from the names, and every row shows - and can change - the definition behind it.
public sealed class FeaturePageView : UserControl
{
    readonly SimHost _host;
    readonly CalPage _page;
    readonly Action<string> _status;
    readonly Action<ItemDef> _openTable;

    public FeaturePageView(SimHost host, CalPage page, Action<string> status, Action<ItemDef> openTable)
    {
        _host = host; _page = page; _status = status; _openTable = openTable;
        Build();
    }

    /// Rebuild the page (a binding changed, or a value was written from elsewhere).
    public void Refresh() => Build();

    void Build()
    {
        var root = new StackPanel { Margin = new Thickness(10, 4, 8, 8) };
        root.Children.Add(new TextBlock
        {
            Text = _page.Name, FontWeight = FontWeight.Bold, FontSize = 14, Margin = new Thickness(0, 4, 0, 2),
        });
        root.Children.Add(new TextBlock
        {
            Text = _page.Blurb, FontSize = 11.5, Opacity = 0.8, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6),
        });

        var head = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Btn("Bind the rows", () =>
        {
            // a ROM opened from source without ";@" definitions has none until Detect has run
            string detected = "";
            if (_host.Defs().Items.Count == 0 && _host.DetectDefinitions() is string summary) detected = "Detect: " + summary + " - ";
            var rom = _host.RomCopy();
            int n = _host.EditDefinitions(d => HtsLayout.Apply(d, rom) + CalPage.GuessBindings(d, _page));
            _status(detected + (n == 0
                ? (_host.Defs().Items.Count == 0 ? "this ROM has no definitions yet - build it, then run Detect in the calibration editor"
                                                 : "nothing more to bind on this page")
                : HtsLayout.Version(rom) == 115 ? $"{n} row(s) bound from the HTS 1.15 layout" : $"{n} row(s) bound by name"));
            Build();
        }, "An HTS 1.15 / HTS120 ROM: bind every row from the HTS address layout. Any other ROM: bind the empty rows whose definition names match. Rows bound by hand on a non-HTS ROM are left alone."));
        head.Children.Add(Btn("Clear every binding", () =>
        {
            var slots = _page.Slots().ToHashSet(StringComparer.OrdinalIgnoreCase);
            int n = _host.EditDefinitions(d =>
            {
                int k = 0;
                foreach (var i in d.Items) if (i.RemoveSlots(slots.Contains)) k++;
                return k;
            });
            _status($"{n} binding(s) cleared on this page");
            Build();
        }, "Forget which definition each row on this page points at (the ROM values are not touched)."));
        root.Children.Add(head);

        foreach (var group in _page.Groups)
            root.Children.Add(group.Conditions ? Conditions(group) : Plain(group));

        Content = new ScrollViewer { Content = root };
    }

    // ------------------------------------------------------------------ groups

    static Border Box(string title, Control body) => new()
    {
        BorderBrush = new SolidColorBrush(Color.FromArgb(64, 255, 255, 255)),
        BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4),
        Margin = new Thickness(0, 0, 0, 10),
        Child = new StackPanel
        {
            Children =
            {
                new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 12, Margin = new Thickness(10, 6, 0, 0) },
                body,
            },
        },
    };

    Control Plain(PageGroup group)
    {
        var body = new StackPanel { Margin = new Thickness(10, 6, 8, 8) };
        foreach (var row in group.Rows) body.Children.Add(Row(row));
        return Box(group.Title, body);
    }

    /// The conditions grid: Minimum and Maximum down two columns, one row per quantity, exactly as the established tuning software draws it.
    Control Conditions(PageGroup group)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("120,150,150,54,*"),
            Margin = new Thickness(10, 6, 8, 8),
        };
        void Cell(Control c, int r, int col) { Grid.SetRow(c, r); Grid.SetColumn(c, col); grid.Children.Add(c); }
        grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        Cell(Head("Minimum"), 0, 1);
        Cell(Head("Maximum"), 0, 2);

        int line = 1;
        foreach (var row in group.Rows)
        {
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            Cell(new TextBlock
            {
                Text = row.Label + ":", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 3, 6, 3),
            }, line, 0);
            if (row.Kind == RowKind.MinMax)
            {
                Cell(Editor(row, row.Slot + ".min"), line, 1);
                Cell(Editor(row, row.Slot + ".max"), line, 2);
            }
            else Cell(Editor(row, row.Slot), line, 1);
            Cell(new TextBlock
            {
                Text = row.Unit, FontSize = 11, Opacity = 0.8, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0),
            }, line, 3);
            var binds = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            foreach (var (slot, _) in Slots(row)) binds.Children.Add(Bind(slot, row));
            Cell(binds, line, 4);
            if (row.Tip.Length > 0) ToolTip.SetTip(grid.Children[^1], row.Tip);
            line++;
        }
        return Box(group.Title, grid);
    }

    static TextBlock Head(string t) => new()
    {
        Text = t, FontSize = 11, Opacity = 0.75, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 2),
    };

    static IEnumerable<(string Slot, string Which)> Slots(PageRow row) =>
        row.Kind == RowKind.MinMax ? [(row.Slot + ".min", "min"), (row.Slot + ".max", "max")] : [(row.Slot, "")];

    // ------------------------------------------------------------------ one row

    Control Row(PageRow row)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("240,Auto,54,*"), Margin = new Thickness(0, 3) };
        var label = new TextBlock { Text = row.Label + (row.Kind == RowKind.Switch ? "" : ":"), VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(label, 0); g.Children.Add(label);
        var editor = Editor(row, row.Slot);
        Grid.SetColumn(editor, 1); g.Children.Add(editor);
        var unit = new TextBlock { Text = row.Unit, FontSize = 11, Opacity = 0.8, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        Grid.SetColumn(unit, 2); g.Children.Add(unit);
        var bind = Bind(row.Slot, row);
        Grid.SetColumn(bind, 3); g.Children.Add(bind);
        if (row.Tip.Length > 0) ToolTip.SetTip(g, row.Tip);
        return g;
    }

    /// The editor for one slot: a number box, a tick box, a choice, or a button that opens the table.
    Control Editor(PageRow row, string slot)
    {
        var defs = _host.Defs();
        var item = CalPage.Bound(defs, slot);
        if (item == null)
            return new TextBlock
            {
                Text = "—", Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center,
                Width = row.Kind == RowKind.Choice ? 220 : 130,
            };
        switch (row.Kind)
        {
            case RowKind.Table:
                {
                    var b = Btn($"{item.Name}  ({item.Rows}×{item.Cols})", () => _openTable(item),
                                "Open this table in the map editor.");
                    b.MinWidth = 220;
                    return b;
                }
            case RowKind.Switch:
                {
                    double raw;
                    try { raw = _host.ReadItem(item)[0].Raw; } catch { return Broken(item); }
                    bool On(ItemDef it, double r) => it.Type == CellType.Bit ? r != 0 : r != it.OffRaw;
                    var cb = new CheckBox
                    {
                        IsChecked = On(item, raw) ^ row.Inverted,
                        VerticalAlignment = VerticalAlignment.Center, MinWidth = 130,
                    };
                    cb.IsCheckedChanged += (_, _) =>
                    {
                        bool set = (cb.IsChecked == true) ^ row.Inverted;
                        // a setting kept in several places (a patch over two operands) is switched in all of them
                        foreach (var it in CalPage.BoundAll(defs, slot))
                            Write(it, it.Type == CellType.Bit ? (set ? 1 : 0) : set ? it.OnRaw : it.OffRaw, raw: true, cb.IsChecked == true ? "on" : "off");
                    };
                    ToolTip.SetTip(cb, Describe(item));
                    return cb;
                }
            case RowKind.Choice:
                {
                    var options = row.Options ?? [];
                    double raw;
                    try { raw = _host.ReadItem(item)[0].Raw; } catch { return Broken(item); }
                    // the raw value of each entry: its position, or the row's own list (one-hot inputs)
                    int RawOf(int i) => row.Values is { } v && i < v.Length ? v[i] : i;
                    int at = row.Values is { } vals ? Array.IndexOf(vals, (int)raw) : (int)raw;
                    var shown = options.ToList();
                    if (at < 0 || at >= options.Length) { shown.Add($"(raw {raw:0} - not one of these)"); at = shown.Count - 1; }
                    var box = new ComboBox { ItemsSource = shown, Width = 220, SelectedIndex = at };
                    box.SelectionChanged += (_, _) =>
                    {
                        if (box.SelectedIndex < 0 || box.SelectedIndex >= options.Length) return;
                        foreach (var it in CalPage.BoundAll(defs, slot))
                            Write(it, RawOf(box.SelectedIndex), raw: true, options[box.SelectedIndex]);
                    };
                    ToolTip.SetTip(box, Describe(item) + (row.Values != null
                        ? $"\nThe stored byte is {raw:0} (0x{(int)raw:X2}): one bit per input."
                        : $"\nThe stored byte is the position in this list (now {raw:0})."));
                    return box;
                }
            default:
                {
                    CellValue c;
                    FormulaDef f;
                    try { c = _host.ReadItem(item)[0]; f = defs.Formula(item.Formula); } catch { return Broken(item); }
                    var (lo, hi) = RomData.RawRange(item.Type);
                    double vlo = Math.Min(f.ToValue(lo), f.ToValue(hi)), vhi = Math.Max(f.ToValue(lo), f.ToValue(hi));
                    double step = Math.Abs(f.ToValue(lo + 1) - f.ToValue(lo));
                    if (step <= 0 || double.IsNaN(step) || double.IsInfinity(step)) step = 1;
                    var nud = new NumericUpDown
                    {
                        Width = 130, Minimum = (decimal)Math.Max(-1e9, vlo), Maximum = (decimal)Math.Min(1e9, vhi),
                        Increment = (decimal)Math.Round(step, 6), Value = (decimal)Math.Round(c.Value, 6),
                        FormatString = "0." + new string('#', Math.Clamp(f.Decimals, 0, 6)), FontFamily = MainWindow.MonoFont,
                    };
                    nud.ValueChanged += (_, e) =>
                    {
                        if (e.NewValue is not decimal d) return;
                        // a value the code reads from two copies is written to both
                        foreach (var it in CalPage.BoundAll(defs, slot))
                            Write(it, (double)d, raw: false, ((double)d).ToString("0.###", CultureInfo.InvariantCulture));
                    };
                    ToolTip.SetTip(nud, Describe(item));
                    return nud;
                }
        }
    }

    static Control Broken(ItemDef item) => new TextBlock
    {
        Text = "cannot read " + item.Name, Foreground = Brushes.OrangeRed, FontSize = 11,
        VerticalAlignment = VerticalAlignment.Center, Width = 130,
    };

    string Describe(ItemDef item)
    {
        string unit;
        try { unit = _host.Defs().Formula(item.Formula).Unit; } catch { unit = ""; }
        return $"{item.Name} @ {item.Address:X4}  {item.Type.ToString().ToLowerInvariant()}" +
               (unit.Length > 0 ? $"  [{unit}]" : "") +
               (item.Description.Length > 0 ? "\n" + item.Description : "") +
               "\nChanges the running ROM at once.";
    }

    void Write(ItemDef item, double value, bool raw, string what)
    {
        try
        {
            _host.WriteCells(item, new[] { (0, value) }, raw, raw ? $"raw {value}" : $"= {value}");
            var w = _host.ReadItem(item)[0];
            _status($"{_page.Name}: {item.Name} = {w.Display} ({what}) - patched in the running ROM");
            AppLog.Action("calibration", $"{_page.Name}: {item.Name} = {w.Display}");
        }
        catch (Exception ex) { _status(ex.Message); AppLog.Error("calibration", "feature page write failed", ex); }
    }

    // ------------------------------------------------------------------ binding

    /// The box beside a row that says which definition fills it, and lets it be pointed somewhere else: type part of a name, or a hex address (5FB3, 0x5FB3, 5FB3h), and pick from what matches.
    Control Bind(string slot, PageRow row)
    {
        var defs = _host.Defs();
        bool wantTable = row.Kind == RowKind.Table;
        var candidates = defs.Items
            .Where(i => (i.IsTable && i.Count > 1) == wantTable)
            .OrderBy(i => i.Name, StringComparer.OrdinalIgnoreCase).ToList();
        var bound = CalPage.BoundAll(defs, slot);
        string Show(ItemDef i) => $"{i.Name}  @{i.Address:X4}";
        const string None = "(not set)";
        var entries = new List<string> { None };
        entries.AddRange(candidates.Select(Show));
        // the filter has to be in place before FilterMode = Custom and before any Text: setting either refreshes the list
        var box = new AutoCompleteBox
        {
            ItemFilter = (search, o) => Matches(search, o as string),
            Width = 240, FontSize = 11, MinimumPrefixLength = 0, Watermark = "name or hex address",
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0), MaxDropDownHeight = 320,
        };
        box.FilterMode = AutoCompleteFilterMode.Custom;
        box.ItemsSource = entries;
        box.Text = bound.Count == 0 ? None : string.Join(" + ", bound.Select(Show));
        ToolTip.SetTip(box, $"Which definition of this ROM is '{row.Label}'" +
                            (slot.EndsWith(".min") ? " (minimum)" : slot.EndsWith(".max") ? " (maximum)" : "") +
                            ".\nType part of a name, or a hex address, then pick one." +
                            $"\nSlot '{slot}'. The choice is kept with the definitions, so it is exported, imported and saved with a project.");
        void Commit(string? text)
        {
            if (text == null) return;
            ItemDef? pick = null;
            if (text != None)
            {
                pick = candidates.FirstOrDefault(i => Show(i) == text)
                       // a bare address: the definition that starts there, else one that covers it
                       ?? (ParseAddress(text) is int a ? candidates.FirstOrDefault(i => i.Address == a) ?? candidates.FirstOrDefault(i => i.Contains(a)) : null)
                       ?? candidates.FirstOrDefault(i => i.Name.Equals(text.Trim(), StringComparison.OrdinalIgnoreCase));
                if (pick == null) return;
            }
            if (bound.Count == 1 && ReferenceEquals(bound[0], pick) || bound.Count == 0 && pick == null) return;
            _host.EditDefinitions(d =>
            {
                foreach (var it in d.Items) it.RemoveSlots(x => x.Equals(slot, StringComparison.OrdinalIgnoreCase));
                pick?.AddSlot(slot);
                return 0;
            });
            _status(pick == null ? $"'{row.Label}' is no longer bound" : $"'{row.Label}' now reads {pick.Name} @ {pick.Address:X4}");
            Build();
        }
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is string s) Commit(s); };
        box.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { Commit(box.SelectedItem as string ?? box.Text); e.Handled = true; } };
        box.GotFocus += (_, _) => { if (box.Text is { } t && (t == None || t.Contains('@'))) { box.Text = ""; box.IsDropDownOpen = true; } };
        box.LostFocus += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(box.Text)) box.Text = bound.Count == 0 ? None : string.Join(" + ", bound.Select(Show));
        };
        return box;
    }

    /// "5fb3", "0x5FB3", "5FB3h", "@5FB3" -> 0x5FB3.
    static int? ParseAddress(string text)
    {
        var t = text.Trim().TrimStart('@');
        if (t.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) t = t[2..];
        if (t.EndsWith('h') || t.EndsWith('H')) t = t[..^1];
        return t.Length is > 0 and <= 5 && int.TryParse(t, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int a) ? a : null;
    }

    /// A picker entry matches typed text by name (any part) or by address (a hex prefix of it).
    static bool Matches(string? search, string? entry)
    {
        if (entry == null) return false;
        if (string.IsNullOrWhiteSpace(search)) return true;
        var s = search.Trim();
        int at = entry.LastIndexOf('@');
        string name = at > 0 ? entry[..at].Trim() : entry, addr = at > 0 ? entry[(at + 1)..] : "";
        if (name.Contains(s, StringComparison.OrdinalIgnoreCase)) return true;
        var hex = s.TrimStart('@');
        if (hex.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) hex = hex[2..];
        if (hex.EndsWith('h') || hex.EndsWith('H')) hex = hex[..^1];
        return hex.Length > 0 && addr.StartsWith(hex, StringComparison.OrdinalIgnoreCase);
    }

    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(7, 2) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }
}
