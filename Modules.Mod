MODULE Modules;  (*Link and load on RISC; NW 20.10.2013 / 8.1.2019 / AP 2.2.20 Extended Oberon System*)
IMPORT SYSTEM, SysDef, Kernel, Files;
CONST VERSION* = "Modules AP 2.2.20";
versionkey = 1X; 
MT = SysDef.MT; (* 12; Module Table CPU register*)
(*WS warning. Most modules also hardwire MTOrg = 20H. But this module does not. It rather reads MTOrg from Register 12 (MT register). This is breaking the undocumented interface rules which other modules are following.*)
DescSize = 84; 
MnLength = 32;
noerr* = 0; nofile* = 1; badversion* = 2; badkey* = 3; badfile* = 4; nospace* = 5; nocmd* = 6; badcmd* = 7; nomod* = 8;
noref* = 0; clients* = 9; dyntypes* = 10; dynptrs* = 11; dynpvrs* = 12; statptrs* = 13; statpvrs* = 14;

(*WS warning. Undocumented hardwired address 0F7000000H in Load *)

  TYPE Module* = POINTER TO ModDesc;
    Command* = PROCEDURE;
    ModuleName* = ARRAY MnLength OF CHAR;

    ModDesc* = RECORD
      name*: ModuleName;
      next*: Module;
      key*, num*, size*, refcnt*: INTEGER;
      data*, code*, imp*, cmd*, ent*, ptr*, pvr*: INTEGER;  (*addresses*)
      selected*, marked, hidden, sel: BOOLEAN
    END ;

    ClientHandler* = PROCEDURE(mod, imp: Module; VAR continue: BOOLEAN): INTEGER;
    RefHandler* = PROCEDURE(src, dst: LONGINT; s: ARRAY OF CHAR; VAR continue: BOOLEAN): INTEGER;

  VAR root*, M: Module;
    MTOrg*, AllocPtr*, res*: INTEGER; (*WS warning. Most modules hardwire MTOrg = 20H.*)
    importing*, imported*: ModuleName;
    limit, NofSelected*, NofHidden*: INTEGER;

  PROCEDURE ThisFile(name: ARRAY OF CHAR): Files.File;
    VAR i: INTEGER;
      filename: ModuleName;
  BEGIN i := 0;
    WHILE name[i] # 0X DO filename[i] := name[i]; INC(i) END ;
    filename[i] := "."; filename[i+1] := "r"; filename[i+2] := "s"; filename[i+3] := "c"; filename[i+4] := 0X;
    RETURN Files.Old(filename)
  END ThisFile;

  PROCEDURE error(n: INTEGER; name: ARRAY OF CHAR);
  BEGIN res := n; importing := name
  END error;

  PROCEDURE check(s: ARRAY OF CHAR);
    VAR i: INTEGER; ch: CHAR;
  BEGIN ch := s[0]; res := 1; i := 1;
    IF (ch >= "A") & (ch <= "Z") OR (ch >= "a") & (ch <= "z") THEN
      REPEAT ch := s[i]; INC(i)
      UNTIL ~((ch >= "0") & (ch <= "9") OR (ch >= "A") & (ch <= "Z")
        OR (ch >= "a") & (ch <= "z") OR (ch = ".")) OR (i = MnLength);
      IF (i < MnLength) & (ch = 0X) THEN res := 0 END
    END
  END check;

  PROCEDURE Load*(name: ARRAY OF CHAR; VAR newmod: Module);
    (*search module in list; if not found, load module.
      res = noerr: already present or loaded;
      res = nofile: file not available;
      res = badversion: bad file version;
      res = badkey: key conflict;
      res = badfile: corrupted file;
      res = nospace: insufficient space*)
    VAR mod, impmod: Module;
      i, n, key, impkey, mno, nofimps, size, tdx: INTEGER;
      p, u, v, w: INTEGER;  (*addresses*)
      ch: CHAR;
      body: Command;
      fixorgP, fixorgD, fixorgT, fixorgM: INTEGER;
      disp, adr, inst, pno, vno, dest, offset: INTEGER;
      name1, impname: ModuleName;
      F: Files.File; R: Files.Rider;
      import: ARRAY 64 OF Module;
  BEGIN mod := root; error(noerr, name); nofimps := 0;
    WHILE (mod # NIL) & (name # mod.name) DO mod := mod.next END ;
    IF mod = NIL THEN (*load*)
      check(name);
      IF res = noerr THEN F := ThisFile(name) ELSE F := NIL END ;
      IF F # NIL THEN
        Files.Set(R, F, 0); Files.ReadString(R, name1); Files.ReadInt(R, key); Files.Read(R, ch);
        Files.ReadInt(R, size); importing := name1;
        IF ch = versionkey THEN
          Files.ReadString(R, impname);   (*imports*)
          WHILE (impname[0] # 0X) & (res = noerr) DO
            Files.ReadInt(R, impkey);
            Load(impname, impmod); import[nofimps] := impmod; importing := name1;
            IF res = noerr THEN
              IF impmod.key = impkey THEN INC(impmod.refcnt); INC(nofimps)
              ELSE error(badkey, name1); imported := impname
              END
            END ;
            Files.ReadString(R, impname)
          END
        ELSE error(badversion, name1)
        END
      ELSE error(nofile, name)
      END ;
      IF res = noerr THEN (*search for a hole in the list allocate and link*)
        INC(size, DescSize); mod := root;
        WHILE (mod # NIL) & ~((mod.name[0] = 0X) & (mod.size >= size)) DO mod := mod.next END ;
        IF mod = NIL THEN (*no large enough hole was found*)
          IF AllocPtr + size < limit THEN (*allocate*)
            p := AllocPtr; mod := SYSTEM.VAL(Module, p);
            AllocPtr := (p + size + 3) DIV 4 * 4; mod.size := AllocPtr - p;
            IF root = NIL THEN mod.num := 1 ELSE mod.num := root.num + 1 END ;
            mod.next := root; root := mod
          ELSE error(nospace, name1)
          END
        ELSE (*fill hole*) p := SYSTEM.VAL(INTEGER, mod)
        END
      END ;
      IF res = noerr THEN (*read file*)
        INC(p, DescSize); (*allocate descriptor*)
        mod.name := name; mod.key := key; mod.refcnt := 0;
        mod.selected := FALSE; mod.hidden := FALSE; mod.marked := FALSE; mod.sel := FALSE;
        mod.data := p;  (*data*)
        SYSTEM.PUT(mod.num * 4 + MTOrg, p);  (*module table entry*)
        Files.ReadInt(R, n);
        WHILE n > 0 DO SYSTEM.PUT(p, 0); INC(p, 4); DEC(n, 4) END ;  (*variable space*)
        Files.ReadInt(R, n);
        WHILE n > 0 DO Files.Read(R, ch); SYSTEM.PUT(p, ch); INC(p); DEC(n) END ;   (*strings*)
        tdx := p;  (*type descriptors*)
        Files.ReadInt(R, n);
        WHILE n > 0 DO Files.ReadInt(R, w); SYSTEM.PUT(p, w); INC(p, 4); DEC(n, 4) END ;
        mod.code := p;  (*program*)
        Files.ReadInt(R, n);
        WHILE n > 0 DO Files.ReadInt(R, w); SYSTEM.PUT(p, w); INC(p, 4); DEC(n) END ;  (*program code*)
        mod.imp := p;  (*copy imports*)
        i := 0;
        WHILE i < nofimps DO
          SYSTEM.PUT(p, import[i]); INC(p, 4); INC(i)
        END ;
        mod.cmd := p;  (*commands*) Files.Read(R, ch);
        WHILE ch # 0X DO
          REPEAT SYSTEM.PUT(p, ch); INC(p); Files.Read(R, ch) UNTIL ch = 0X;
          REPEAT SYSTEM.PUT(p, 0X); INC(p) UNTIL p MOD 4 = 0;
          Files.ReadInt(R, n); SYSTEM.PUT(p, n); INC(p, 4); Files.Read(R, ch)
        END ;
        REPEAT SYSTEM.PUT(p, 0X); INC(p) UNTIL p MOD 4 = 0;
        mod.ent := p;  (*entries*)
        Files.ReadInt(R, n);
        WHILE n > 0 DO Files.ReadInt(R, w); SYSTEM.PUT(p, w); INC(p, 4); DEC(n) END ;
        mod.ptr := p;  (*pointer references*)
        Files.ReadInt(R, w);
        WHILE w >= 0 DO SYSTEM.PUT(p, mod.data + w); INC(p, 4); Files.ReadInt(R, w) END ;
        SYSTEM.PUT(p, 0); INC(p, 4);
        mod.pvr := p;  (*procedure variable references*)
        Files.ReadInt(R, w);
        WHILE w >= 0 DO SYSTEM.PUT(p, mod.data + w); INC(p, 4); Files.ReadInt(R, w) END ;
        SYSTEM.PUT(p, 0); INC(p, 4);
        Files.ReadInt(R, fixorgP); Files.ReadInt(R, fixorgD);
        Files.ReadInt(R, fixorgT); Files.ReadInt(R, fixorgM);
        Files.ReadInt(R, w); body := SYSTEM.VAL(Command, mod.code + w);
        Files.Read(R, ch);
        IF ch # "O" THEN mod := NIL; error(badfile, name) END
      END ;
      IF res = noerr THEN (*fixup of BL*)
        adr := mod.code + fixorgP*4;
        WHILE adr # mod.code DO
          SYSTEM.GET(adr, inst);
          mno := inst DIV 400000H MOD 40H;
          pno := inst DIV 4000H MOD 100H;
          disp := inst MOD 4000H;
          SYSTEM.GET(mod.imp + (mno-1)*4, impmod);
          SYSTEM.GET(impmod.ent + pno*4, dest); dest := dest + impmod.code;
          offset := (dest - adr - 4) DIV 4;
          SYSTEM.PUT(adr, (offset MOD 1000000H) + 0F7000000H); (*WS warning. Undocumented hardwired address*)
          adr := adr - disp*4
        END ;
        (*fixup of LDR/STR/ADD*)
        adr := mod.code + fixorgD*4;
        WHILE adr # mod.code DO
          SYSTEM.GET(adr, inst);
          mno := inst DIV 10000H MOD 100H;
          disp := inst MOD 10000H;
          IF mno = 0 THEN (*global*)
            SYSTEM.PUT(adr, (inst DIV 1000000H * 10H + MT) * 100000H + mod.num * 4)
          ELSE (*import*)
            SYSTEM.GET(mod.imp + (mno-1)*4, impmod); v := impmod.num;
            SYSTEM.PUT(adr, (inst DIV 1000000H * 10H + MT) * 100000H + v*4);
            SYSTEM.GET(adr+4, inst); vno := inst MOD 100H;
            SYSTEM.GET(impmod.ent + vno*4, offset);
            IF ODD(inst DIV 100H) THEN offset := offset + impmod.code - impmod.data END ;
            SYSTEM.PUT(adr+4, inst DIV 10000H * 10000H + offset)
          END ;
          adr := adr - disp*4
        END ;
        (*fixup of type descriptors*)
        adr := tdx + fixorgT*4;
        WHILE adr # tdx DO
          SYSTEM.GET(adr, inst);
          mno := inst DIV 1000000H;
          vno := inst DIV 1000H MOD 1000H;
          disp := inst MOD 1000H;
          IF mno = 0 THEN (*global*) inst := tdx + vno
          ELSE (*import*)
            SYSTEM.GET(mod.imp + (mno-1)*4, impmod);
            SYSTEM.GET(impmod.ent + vno*4, offset);
            inst := impmod.data + offset
          END ;
          SYSTEM.PUT(adr, inst); adr := adr - disp*4
        END ;
        (*fixup of method tables*)
        adr := tdx + fixorgM*4;
        WHILE adr # tdx DO
          SYSTEM.GET(adr, inst);
          mno := inst DIV 1000000H;
          vno := inst DIV 400H MOD 4000H;
          disp := inst MOD 400H;
          IF mno = 0 THEN (*global*) inst := mod.code + vno*4
          ELSE (*import*)
            SYSTEM.GET(mod.imp + (mno-1)*4, impmod);
            SYSTEM.GET(impmod.ent + vno*4, offset);
            inst := impmod.code + offset
          END ;
          SYSTEM.PUT(adr, inst); adr := adr - disp*4
        END ;
        body   (*initialize module*)
      ELSIF res >= badkey THEN importing := name;
        WHILE nofimps > 0 DO DEC(nofimps); DEC(import[nofimps].refcnt) END
      END
    END ;
    newmod := mod
  END Load;

  PROCEDURE ThisCommand*(mod: Module; name: ARRAY OF CHAR): Command;
    (*return the command named 'name' from module 'mod'.
      res = noerr: command found;
      res = nocmd: command not found*)
    VAR k, adr, w: INTEGER; ch: CHAR;
      s: ARRAY 32 OF CHAR;
  BEGIN res := nocmd; w := 0;
    IF mod # NIL THEN
      adr := mod.cmd; SYSTEM.GET(adr, ch);
      WHILE (ch # 0X) & (res # noerr) DO k := 0; (*read command name*)
        REPEAT s[k] := ch; INC(k); INC(adr); SYSTEM.GET(adr, ch) UNTIL ch = 0X;
        s[k] := 0X;
        REPEAT INC(adr) UNTIL adr MOD 4 = 0;
        SYSTEM.GET(adr, k); INC(adr, 4);
        IF s = name THEN res := noerr; w := mod.code + k ELSE SYSTEM.GET(adr, ch) END
      END
    END
    RETURN SYSTEM.VAL(Command, w)
  END ThisCommand;

  PROCEDURE Call*(name: ARRAY OF CHAR);
    (*call the command named 'name' of the form M.P, where M is either a module name or
      a module number; if M is not loaded, load module hierarchy M* before calling P.
      res = noerr: module loaded, command found and executed;
      res = nofile: file not available;
      res = badversion: bad file version;
      res = badkey: key conflict;
      res = badfile: corrupted file;
      res = nospace: insufficient space;
      res = nocmd: command not found;
      res = badcmd: invalid command;
      res = nomod: module not found in module list*)
    VAR mod: Module; P: Command;
      i, j: INTEGER; ch: CHAR;
      Mname, Cname: ModuleName;
  BEGIN i := 0; ch := name[0];
    IF ("0" <= ch) & (ch <= "9") THEN (*module number*) j := 0;
      REPEAT j := 10*j + (ORD(ch) - 30H); INC(i); ch := name[i] UNTIL (ch < "0") OR (ch > "9");
      IF ch = "." THEN INC(i); mod := root;
        WHILE (mod # NIL) & (mod.name[0] # 0X) & (mod.num # j) DO mod := mod.next END ;
        IF (mod # NIL) & (mod.name[0] # 0X) THEN res := noerr; j := 0;
          REPEAT ch := mod.name[j]; Mname[j] := ch; INC(j) UNTIL ch = 0X
        ELSE res := nomod
        END
      ELSE res := badcmd
      END
    ELSIF (ch >= "A") & (ch <= "Z") OR (ch >= "a") & (ch <= "z") OR (ch = "*") THEN (*module name*)
      REPEAT Mname[i] := ch; INC(i); ch := name[i] UNTIL (ch = ".") OR (ch = 0X);
      IF ch = "." THEN Mname[i] := 0X; INC(i); Load(Mname, mod) ELSE res := badcmd END
    ELSE res := badcmd
    END ;
    IF res = noerr THEN
      j := 0; ch := name[i]; INC(i);
      WHILE ch # 0X DO Cname[j] := ch; INC(j); ch := name[i]; INC(i) END ;
      Cname[j] := 0X;
      P := ThisCommand(mod, Cname);
      IF res = noerr THEN P END
    END
  END Call;

  (*--------------------------- selections ---------------------------*)

  PROCEDURE select(mod: Module; clients, imports: BOOLEAN);
    VAR imp, m: Module; p, q: INTEGER;
  BEGIN (*~mod.sel & mod.name[0] # 0X*) mod.sel := TRUE;
    IF clients THEN m := root;
      WHILE m # NIL DO
        IF (m.name[0] # 0X) & (m # mod) & ~m.sel THEN p := m.imp; q := m.cmd;
          WHILE p < q DO (*imports*) SYSTEM.GET(p, imp);
            IF imp = mod THEN select(m, clients, imports); p := q ELSE INC(p, 4) END
          END
        END ;
        m := m.next
      END
    END ;
    IF imports THEN p := mod.imp; q := mod.cmd;
      WHILE p < q DO (*imports*) SYSTEM.GET(p, imp); INC(p, 4);
        IF (imp.name[0] # 0X) & ~imp.sel THEN select(imp, clients, imports) END
      END
    END
  END select;

  PROCEDURE Select*(name: ARRAY OF CHAR; on, this, clients, imports: BOOLEAN);
    VAR mod, m: Module;
  BEGIN mod := root; m := NIL;
    WHILE mod # NIL DO mod.sel := FALSE;
      IF (mod.name[0] # 0X) & (mod.name = name) THEN m := mod END ;
      mod := mod.next
    END ;
    IF m # NIL THEN select(m, clients, imports); mod := root;
      WHILE mod # NIL DO
        IF mod.sel & ((mod # m) OR this) THEN
          IF on THEN
            IF ~mod.selected THEN mod.selected := TRUE; INC(NofSelected) END
          ELSIF mod.selected THEN mod.selected := FALSE; DEC(NofSelected)
          END
        END ;
        mod := mod.next
      END
    END
  END Select;

  PROCEDURE Deselect*; (*all modules*)
    VAR mod: Module;
  BEGIN mod := root; NofSelected := 0;
    WHILE mod # NIL DO mod.selected := FALSE; mod := mod.next END
  END Deselect;

  (*--------------------------- reference checking ---------------------------*)

  PROCEDURE FindClients*(client: ClientHandler; VAR res: INTEGER);
    VAR mod, imp, m: Module; p, q: INTEGER; continue: BOOLEAN;
  BEGIN res := noref; m := root; continue := client # NIL;
    WHILE continue & (m # NIL) DO
      IF (m.name[0] # 0X) & m.selected & (m.refcnt > 0) THEN mod := root;
        WHILE continue & (mod # NIL) DO
          IF (mod.name[0] # 0X) & ~mod.selected THEN p := mod.imp; q := mod.cmd;
            WHILE p < q DO (*imports*) SYSTEM.GET(p, imp);
              IF imp = m THEN INC(res, client(mod, imp, continue)); p := q ELSE INC(p, 4) END
            END
          END ;
          mod := mod.next
        END
      END ;
      m := m.next
    END
  END FindClients;

  PROCEDURE FindDynamicReferences*(typ, ptr, pvr: RefHandler; VAR resTyp, resPtr, resPvr: INTEGER; all: BOOLEAN);
    VAR mod: Module;
  BEGIN mod := root;
    WHILE mod # NIL DO
      IF (mod.name[0] # 0X) & ~mod.selected THEN Kernel.Mark(mod.ptr);
        IF ~all THEN Kernel.Scan(typ, ptr, pvr, mod.name, resTyp, resPtr, resPvr) END
      END ;
      mod := mod.next
    END ;
    IF all THEN Kernel.Scan(typ, ptr, pvr, "", resTyp, resPtr, resPvr) END
  END FindDynamicReferences;

  PROCEDURE FindStaticReferences*(ptr, pvr: RefHandler; VAR resPtr, resPvr: INTEGER);
    VAR mod: Module; pref, pvadr, r: LONGINT; continue: BOOLEAN;
  BEGIN resPtr := noref; resPvr := noref; mod := root; continue := (ptr # NIL) OR (pvr # NIL);
    WHILE continue & (mod # NIL) DO
      IF (mod.name[0] # 0X) & ~mod.selected THEN
        IF ptr # NIL THEN pref := mod.ptr; SYSTEM.GET(pref, pvadr);
          WHILE continue & (pvadr # 0) DO (*pointers*) SYSTEM.GET(pvadr, r);
            INC(resPtr, ptr(pvadr, r, mod.name, continue));
            INC(pref, 4); SYSTEM.GET(pref, pvadr)
          END
        END ;
        IF pvr # NIL THEN pref := mod.pvr; SYSTEM.GET(pref, pvadr);
          WHILE continue & (pvadr # 0) DO (*procedures*) SYSTEM.GET(pvadr, r);
            INC(resPvr, pvr(pvadr, r, mod.name, continue));
            INC(pref, 4); SYSTEM.GET(pref, pvadr)
          END
        END
      END ;
      mod := mod.next
    END
  END FindStaticReferences;

  PROCEDURE HandleClient(mod, imp: Module; VAR continue: BOOLEAN): INTEGER;
  BEGIN (*mod imports imp*) continue := FALSE; RETURN 1
  END HandleClient;

  PROCEDURE HandleRef(src, dst: LONGINT; s: ARRAY OF CHAR; VAR continue: BOOLEAN): INTEGER;
    VAR mod: Module; i: INTEGER;
  BEGIN i := 0;
    IF (dst > 0) & (dst < AllocPtr) THEN mod := root;
      WHILE (mod # NIL) & ~((mod.name[0] # 0X) & mod.selected & (mod.data <= dst) & (dst < mod.imp)) DO mod := mod.next END ;
      IF mod # NIL THEN (*src references mod*) i := 1; continue := FALSE END
    END ;
    RETURN i
  END HandleRef;

  PROCEDURE Check*(VAR res: INTEGER);
    (*check whether external client, type, pointer or procedure variable references to selected modules exist.
      res = noref: no client, type, pointer or procedure variables references;
      res = clients: clients exist;
      res = dyntypes: types in use in dynamically allocated objects;
      res = dynptrs: static module data referenced by pointer variables in dynamically allocated objects;
      res = dynpvrs: procedures in use in dynamically allocated objects;
      res = statptrs: static module data referenced by global pointer variables;
      res = statpvrs: procedures in use in global procedure variables*)
    VAR resTyp, resPtr, resPvr: INTEGER;
  BEGIN FindClients(HandleClient, res);
    IF res > noref THEN res := clients
    ELSE FindDynamicReferences(HandleRef, HandleRef, HandleRef, resTyp, resPtr, resPvr, TRUE);
      IF resTyp > noref THEN res := dyntypes
      ELSIF resPtr > noref THEN res := dynptrs
      ELSIF resPvr > noref THEN res := dynpvrs
      ELSE FindStaticReferences(HandleRef, HandleRef, resPtr, resPvr);
        IF resPtr > noerr THEN res := statptrs ELSIF resPvr > 0 THEN res := statpvrs END
      END
    END
  END Check;

  (*--------------------------- unloading ---------------------------*)

  PROCEDURE Unload(mod: Module); (*module and selected imports from memory*)
    VAR imp: Module; p, q: INTEGER;
  BEGIN (*mod.refcnt = 0 & mod.name[0] # 0X*)
    mod.name[0] := 0X; p := mod.imp; q := mod.cmd;
    WHILE p < q DO (*imports*) SYSTEM.GET(p, imp); DEC(imp.refcnt); INC(p, 4);
      IF (imp.name[0] # 0X) & imp.selected & (imp.refcnt = 0) THEN Unload(imp) END
    END ;
    IF mod.hidden THEN mod.hidden := FALSE; DEC(NofHidden) END ;
    IF mod.selected THEN mod.selected := FALSE; DEC(NofSelected) END ;
    IF mod = root THEN (*increase size of available module space*)
      p := mod.size; mod := mod.next;
      WHILE (mod # NIL) & (mod.name[0] = 0X) DO INC(p, mod.size); mod := mod.next END ;
      AllocPtr := AllocPtr - p; root := mod
    END
  END Unload;

  PROCEDURE Hide(mod: Module); (*module from module list*)
    VAR i: INTEGER;
  BEGIN (*~mod.hidden & mod.name[0] # 0X*) i := 0;
    WHILE mod.name[i] # 0X DO INC(i) END ;
    IF i = MnLength-1 THEN DEC(i) ELSE mod.name[i+1] := 0X END ;
    WHILE i > 0 DO DEC(i); mod.name[i+1] := mod.name[i] END ;
    mod.name[0] := "*"; mod.hidden := TRUE; INC(NofHidden)
  END Hide;

  PROCEDURE FreeSelection*(hide: BOOLEAN); (*unload or hide selected modules; res is set by Check*)
    VAR mod: Module;
  BEGIN res := noref;
    IF NofSelected > 0 THEN Check(res);
      IF res = noref THEN (*unload*) mod := root;
        WHILE mod # NIL DO
          IF (mod.name[0] # 0X) & mod.selected & (mod.refcnt = 0) THEN Unload(mod) END ;
          mod := mod.next
        END
      ELSIF (res > clients) & hide THEN (*hide*) mod := root;
        WHILE mod # NIL DO
          IF (mod.name[0] # 0X) & mod.selected & ~mod.hidden THEN Hide(mod) END ;
          mod := mod.next
        END
      END
    END
  END FreeSelection;

  PROCEDURE Free*(name: ARRAY OF CHAR; hide: BOOLEAN); (*unload or hide specified module; res is set by Check*)
    VAR mod: Module;
  BEGIN mod := root; NofSelected := 0;
    WHILE mod # NIL DO
      IF (mod.name[0] # 0X) & (mod.name = name) THEN mod.selected := TRUE; INC(NofSelected)
      ELSE mod.selected := FALSE
      END ;
      mod := mod.next
    END ;
    FreeSelection(hide)
  END Free;

  (*--------------------------- garbage collection ---------------------------*)

  PROCEDURE Collect*; (*no longer referenced hidden modules*)
    VAR mod, m, m1: Module; continue: BOOLEAN;
      p, q, k, res: INTEGER;
  BEGIN
    IF NofHidden > 0 THEN k := 0;
      IF NofSelected > 0 THEN (*save selection*) mod := root;
        WHILE mod # NIL DO mod.sel := mod.selected; mod.selected := FALSE; mod := mod.next END
      END ;
      WHILE k < NofHidden DO INC(k);
        mod := root; p := 0; continue := TRUE;
        WHILE mod # NIL DO (*set first selection of k modules among hidden modules*)
          IF (mod.name[0] # 0X) & mod.hidden THEN mod.selected := p < k; INC(p) END ;
          mod := mod.next
        END ;
        WHILE continue DO Check(res);
          IF res = noref THEN (*unload current selection of k modules and start over*)
            mod := root; k := 0; continue := FALSE;
            WHILE mod # NIL DO
              IF (mod.name[0] # 0X) & mod.hidden & mod.selected & (mod.refcnt = 0) THEN Unload(mod) END ;
              mod := mod.next
            END
          ELSIF k < NofHidden THEN
            mod := root; q := 0; m1 := NIL;
            WHILE mod # NIL DO (*determine whether there is a next selection of k modules*)
              IF (mod.name[0] # 0X) & mod.hidden THEN
                IF mod.selected THEN m := mod; INC(q) (*number of selected modules at end of list*)
                ELSIF q > 0 THEN q := 0; m1 := m (*last selected module before last unselected group*)
                END
              END ;
              mod := mod.next
            END ;
            IF m1 # NIL THEN (*if there is a next selection of k modules*)
              mod := m1.next; p := 0; m1.selected := FALSE;
              WHILE mod # NIL DO (*set next selection of k modules*)
                IF (mod.name[0] # 0X) & mod.hidden THEN mod.selected := p <= q; INC(p) END ;
                mod := mod.next
              END
            ELSE continue := FALSE (*otherwise continue with selections of k+1 modules*)
            END
          ELSE continue := FALSE (*all combinations of k modules chosen from n hidden modules checked*)
          END
        END
      END ;
      IF NofSelected > 0 THEN (*restore selection without re-selecting the just unloaded hidden modules*)
        mod := root; NofSelected := 0;
        WHILE mod # NIL DO
          IF mod.sel & (mod.name[0] # 0X) THEN mod.selected := TRUE; INC(NofSelected)
          ELSE mod.selected := FALSE
          END ;
          mod := mod.next
        END
      ELSE (*cleanup*) mod := root;
        WHILE mod # NIL DO
          IF mod.hidden THEN mod.selected := FALSE END ;
          mod := mod.next
        END
      END
    END
  END Collect;

PROCEDURE Init*;
BEGIN 
  Files.Init;
  MTOrg := SYSTEM.REG(MT);   (*WS MT is CPU register 12 *)
  SYSTEM.GET(16, AllocPtr);  (*WS magic memory location "16" to be documented*)
  SYSTEM.GET(20, root);      (*WS magic memory location "20" to be documented*)
  limit := Kernel.stackOrg - Kernel.stackSize; 
  NofHidden := 0; 
  Deselect
END Init;

BEGIN Init; Load("Oberon", M);
  LED(res); REPEAT UNTIL FALSE  (*only if load fails*)
END Modules.
