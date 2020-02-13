(*WS Clipboard probably runs only in the emulator. The addresses -20, -24 are not on the official list of devices PO.Computer page 13*)

MODULE Clipboard; (*AP 1.6.17*)
IMPORT SYSTEM, Texts, Viewers, Oberon, TextFrames;

CONST VERSION* = "Clipboard AP 1.6.1";
control = -24; (*WS Not in RISC5top.v*)
data = -20;    (*WS Not in RISC5top.v*)

  PROCEDURE Copy(T: Texts.Text; beg, end: INTEGER);
    VAR R: Texts.Reader;
      ch: CHAR;
  BEGIN
    Texts.OpenReader(R, T, beg);
    SYSTEM.PUT(control, end - beg);
    WHILE beg < end DO
      Texts.Read(R, ch);
      SYSTEM.PUT(data, ch);
      beg := beg + 1
    END
  END Copy;

  PROCEDURE CopySelection*;
    VAR T: Texts.Text;
      beg, end, time: INTEGER;
  BEGIN
    Oberon.GetSelection(T, beg, end, time);
    IF time >= 0 THEN Copy(T, beg, end) END
  END CopySelection;

  PROCEDURE CopyViewer*;
    VAR V: Viewers.Viewer;
      F: TextFrames.Frame;
  BEGIN
    V := Oberon.MarkedViewer();
    IF (V # NIL) & (V.dsc # NIL) & (V.dsc.next IS TextFrames.Frame) THEN
      F := V.dsc.next(TextFrames.Frame);
      Copy(F.text, 0, F.text.len)
    END
  END CopyViewer;

  PROCEDURE Paste*;
    VAR W: Texts.Writer;
      V: Viewers.Viewer;
      F: TextFrames.Frame;
      len, i: INTEGER;
      ch: CHAR;
  BEGIN
    V := Viewers.FocusViewer;
    IF (V # NIL) & (V.dsc # NIL) & (V.dsc.next IS TextFrames.Frame) THEN
      SYSTEM.GET(control, len);
      IF len > 0 THEN
        Texts.OpenWriter(W);
        FOR i := 1 TO len DO
          SYSTEM.GET(data, ch);
          Texts.Write(W, ch)
        END;
        F := V.dsc.next(TextFrames.Frame);
        Texts.Insert(F.text, F.carloc.pos, W.buf);
        TextFrames.SetCaret(F, F.carloc.pos + len)
      END
    END
  END Paste;

END Clipboard.
