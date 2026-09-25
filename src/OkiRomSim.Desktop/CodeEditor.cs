// Copyright (c) bmgjet. All rights reserved.
using System.Xml;
using Avalonia.Controls;
using Avalonia.Media;
using AvaloniaEdit;
using AvaloniaEdit.Highlighting;
using AvaloniaEdit.Highlighting.Xshd;
using AvaloniaEdit.Rendering;

namespace OkiRomSim.Desktop;

/// Thin wrapper around AvaloniaEdit so the rest of the UI does not depend on its API surface. If the AvaloniaEdit package ever gets in the way, this is the only file that needs changing (a plain TextBox with AcceptsReturn works, just without highlighting or fast large files).
public sealed class CodeEditor : UserControl
{
    readonly TextEditor _ed = new()
    {
        ShowLineNumbers = true,
        FontFamily = MainWindow.MonoFont,
        FontSize = 13,
        WordWrap = false,
    };

    public CodeEditor()
    {
        _ed.Options.ConvertTabsToSpaces = false;
        _ed.Options.IndentationSize = 8;
        _ed.Options.HighlightCurrentLine = true;
        try
        {
            using var reader = XmlReader.Create(new StringReader(Xshd));
            _ed.SyntaxHighlighting = HighlightingLoader.Load(reader, HighlightingManager.Instance);
        }
        catch { /* highlighting is a nicety; plain text is fine */ }
        _ed.TextArea.TextView.BackgroundRenderers.Add(_hits);
        _ed.TextArea.TextView.BackgroundRenderers.Add(_marks);
        _ed.TextChanged += (_, _) => TextChanged?.Invoke(this, EventArgs.Empty);
        _ed.TextArea.DoubleTapped += (_, _) =>
        {
            // AvaloniaEdit selects the word under the pointer on a double-click
            var word = _ed.SelectedText?.Trim() ?? "";
            if (word.Length > 0) WordDoubleClicked?.Invoke(word, CaretLine);
        };
        Content = _ed;
    }

    /// Raised whenever the user (or code) changes the text.
    public event EventHandler? TextChanged;
    /// Raised with the word (label, number) the user double-clicked, and its line.
    public event Action<string, int>? WordDoubleClicked;

    readonly HitMarks _hits = new();
    static Color _hitCode = Color.FromRgb(60, 200, 90), _hitData = Color.FromRgb(70, 140, 255);

    public static void SetHitColours(Color code, Color data) { _hitCode = code; _hitData = data; }
    public void SetFontSize(double size) => _ed.FontSize = Math.Clamp(size, 6, 48);

    /// Hit tracer colouring: line -> (true = code ran / false = data read, 0..1 recency).
    public void SetHits(Dictionary<int, (bool Code, double Heat)>? lines)
    {
        _hits.Lines = lines;
        _ed.TextArea.TextView.InvalidateLayer(KnownLayer.Background);
    }

    /// Paints hit-tracer marks: a bar in the margin and a tint that is strongest for the most recent hits (green = executed, blue = read as data).
    sealed class HitMarks : IBackgroundRenderer
    {
        public Dictionary<int, (bool Code, double Heat)>? Lines;
        public KnownLayer Layer => KnownLayer.Background;
        public void Draw(TextView textView, DrawingContext dc)
        {
            if (Lines == null || Lines.Count == 0) return;
            foreach (var vl in textView.VisualLines)
            {
                if (!Lines.TryGetValue(vl.FirstDocumentLine.LineNumber, out var h)) continue;
                double y = vl.VisualTop - textView.ScrollOffset.Y;
                var baseColor = h.Code ? _hitCode : _hitData;
                byte tint = (byte)(18 + (70 * Math.Clamp(h.Heat, 0, 1)));
                dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(tint, baseColor.R, baseColor.G, baseColor.B)), null,
                    new Avalonia.Rect(0, y, Math.Max(textView.Bounds.Width, 2000), vl.Height));
                dc.DrawRectangle(new SolidColorBrush(Color.FromArgb((byte)(120 + (135 * Math.Clamp(h.Heat, 0, 1))), baseColor.R, baseColor.G, baseColor.B)), null,
                    new Avalonia.Rect(0, y, 4, vl.Height));
            }
        }
    }

    /// First line currently scrolled into view (1-based).
    public int FirstVisibleLine
    {
        get
        {
            // the visual lines are only valid after a layout pass; asking outside one (a restore point written on a timer, a background save) throws, and the answer is simply "wherever it was" - the top line is close enough and nothing depends on it
            try
            {
                var tv = _ed.TextArea.TextView;
                return field = tv.VisualLines.FirstOrDefault()?.FirstDocumentLine.LineNumber ?? 1;
            }
            catch { return field; }
        }
    } = 1;

    public void ScrollToLine(int line)
    {
        if (line >= 1 && _ed.Document != null && line <= _ed.Document.LineCount) _ed.ScrollToLine(line);
    }

    public string Text
    {
        // AvaloniaEdit hands back null before a document exists.
        get => _ed.Text ?? "";
        set { if ((_ed.Text ?? "") != value) _ed.Text = value ?? ""; }
    }

    public int CaretLine => _ed.TextArea.Caret.Line;

    public void SetReadOnly(bool ro) => _ed.IsReadOnly = ro;

    public void GoToLine(int line)
    {
        if (line < 1) return;
        var doc = _ed.Document;
        if (doc == null || line > doc.LineCount) return;
        var l = doc.GetLineByNumber(line);
        _ed.CaretOffset = l.Offset;
        _ed.ScrollToLine(line);
    }

    /// Put the caret on the line the simulator is stopped at and scroll it into view.
    public void HighlightLine(int line)
    {
        if (line < 1) return;
        var doc = _ed.Document;
        if (doc == null || line > doc.LineCount) return;
        var l = doc.GetLineByNumber(line);
        _ed.Select(l.Offset, l.Length);
        _ed.ScrollToLine(line);
    }

    readonly LineMarks _marks = new();

    /// Tint the lines that have build errors (red) or warnings (amber).
    public void SetDiagnostics(IReadOnlyList<(int Line, bool IsError)> diagnostics)
    {
        _marks.Lines.Clear();
        foreach (var (line, err) in diagnostics)
            if (!_marks.Lines.TryGetValue(line, out var e) || !e) _marks.Lines[line] = err;
        _ed.TextArea.TextView.InvalidateLayer(KnownLayer.Background);
    }

    /// Paints a band behind each marked line.
    sealed class LineMarks : IBackgroundRenderer
    {
        public readonly Dictionary<int, bool> Lines = [];
        static readonly IBrush Error = new SolidColorBrush(Color.FromArgb(90, 230, 40, 40));
        static readonly IBrush Warning = new SolidColorBrush(Color.FromArgb(60, 230, 170, 30));
        static readonly IPen ErrorPen = new Pen(new SolidColorBrush(Color.FromRgb(240, 70, 70)), 1.5);
        public KnownLayer Layer => KnownLayer.Background;
        public void Draw(TextView textView, DrawingContext dc)
        {
            if (Lines.Count == 0) return;
            foreach (var vl in textView.VisualLines)
            {
                if (!Lines.TryGetValue(vl.FirstDocumentLine.LineNumber, out var isError)) continue;
                double y = vl.VisualTop - textView.ScrollOffset.Y;
                var r = new Avalonia.Rect(0, y, Math.Max(textView.Bounds.Width, 2000), vl.Height);
                dc.DrawRectangle(isError ? Error : Warning, null, r);
                if (isError) dc.DrawLine(ErrorPen, new Avalonia.Point(0, y + vl.Height - 1), new Avalonia.Point(r.Width, y + vl.Height - 1));
            }
        }
    }

    // 66K assembly highlighting. Keyword lists are short on purpose: mnemonics are matched by a word rule so new ones do not need adding here.
    const string Xshd = """
<SyntaxDefinition name="oki66" xmlns="http://icsharpcode.net/sharpdevelop/syntaxdefinition/2008">
  <Color name="Comment" foreground="#6A9955" />
  <Color name="String" foreground="#CE9178" />
  <Color name="Number" foreground="#B5CEA8" />
  <Color name="Directive" foreground="#4EC9B0" />
  <Color name="Register" foreground="#C586C0" />
  <Color name="Mnemonic" foreground="#569CD6" fontWeight="bold" />
  <Color name="Label" foreground="#DCDCAA" />
  <RuleSet ignoreCase="true">
    <Span color="Comment" begin=";" />
    <Span color="String" begin="&quot;" end="&quot;" />
    <Rule color="Label">^[A-Za-z_][A-Za-z0-9_]*(?=:)</Rule>
    <Keywords color="Directive">
      <Word>org</Word><Word>db</Word><Word>dw</Word><Word>equ</Word><Word>include</Word>
      <Word>incbin</Word><Word>if</Word><Word>ifdef</Word><Word>ifndef</Word><Word>elseif</Word>
      <Word>else</Word><Word>endif</Word><Word>module</Word><Word>endmodule</Word><Word>ds</Word>
      <Word>align</Word><Word>assert</Word><Word>error</Word><Word>warning</Word><Word>define</Word>
      <Word>preload</Word><Word>romsize</Word><Word>off</Word>
    </Keywords>
    <Keywords color="Register">
      <Word>A</Word><Word>C</Word><Word>DP</Word><Word>X1</Word><Word>X2</Word><Word>USP</Word>
      <Word>SSP</Word><Word>LRB</Word><Word>PSWH</Word><Word>PSWL</Word>
      <Word>er0</Word><Word>er1</Word><Word>er2</Word><Word>er3</Word>
      <Word>r0</Word><Word>r1</Word><Word>r2</Word><Word>r3</Word><Word>r4</Word><Word>r5</Word>
      <Word>r6</Word><Word>r7</Word>
    </Keywords>
    <Keywords color="Mnemonic">
      <Word>L</Word><Word>LB</Word><Word>LC</Word><Word>LCB</Word><Word>ST</Word><Word>STB</Word>
      <Word>MOV</Word><Word>MOVB</Word><Word>ADD</Word><Word>ADDB</Word><Word>SUB</Word><Word>SUBB</Word>
      <Word>ADC</Word><Word>ADCB</Word><Word>SBC</Word><Word>SBCB</Word><Word>CMP</Word><Word>CMPB</Word>
      <Word>AND</Word><Word>ANDB</Word><Word>OR</Word><Word>ORB</Word><Word>XOR</Word><Word>XORB</Word>
      <Word>INC</Word><Word>INCB</Word><Word>DEC</Word><Word>DECB</Word><Word>CLR</Word><Word>CLRB</Word>
      <Word>SB</Word><Word>RB</Word><Word>MB</Word><Word>MBR</Word><Word>TBR</Word><Word>TRB</Word>
      <Word>J</Word><Word>SJ</Word><Word>CAL</Word><Word>SCAL</Word><Word>VCAL</Word><Word>RT</Word>
      <Word>RTI</Word><Word>RC</Word><Word>SC</Word><Word>NOP</Word><Word>BRK</Word>
      <Word>JEQ</Word><Word>JNE</Word><Word>JLT</Word><Word>JGE</Word><Word>JGT</Word><Word>JLE</Word>
      <Word>JBS</Word><Word>JBR</Word><Word>JRNZ</Word><Word>DJNZ</Word>
      <Word>MUL</Word><Word>DIV</Word><Word>EXTND</Word><Word>SLL</Word><Word>SRL</Word><Word>SLLB</Word>
      <Word>SRLB</Word><Word>ROL</Word><Word>ROR</Word><Word>SWAPB</Word><Word>PUSHS</Word><Word>POPS</Word>
      <Word>PUSHU</Word><Word>POPU</Word>
    </Keywords>
    <Rule color="Number">\b[0-9][0-9A-Fa-f]*[hH]?\b</Rule>
  </RuleSet>
</SyntaxDefinition>
""";
}
