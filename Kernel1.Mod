MODULE Kernel;  (*module Kernel for a boot file containing the entire Oberon system / AP 2.2.20 Extended Oberon System*)
IMPORT SYSTEM, SysDef;

CONST VERSION* = "Kernel (standalone) AP 2.2.20";
	SectorLength* = 1024;
	mapsize = 10000H; (*1K sectors, 64MB; WS not sure what it is...*)
	timer   = SysDef.TIMER ;    (* -64; *)
	spiData = SysDef.SPIDATA ;  (* -48; *)
	spiCtrl = SysDef.SPICTRL ;  (* -44; *)
	CARD0   = SysDef.CARD0 ;    (*  1;  *)
	SPIFAST = SysDef.SPIFAST ;  (*  4;  *)
	STKSIZ  = SysDef.STACKSIZE; (*WS taken from Kernel.Init and copied to SysDef*)
	FSoffset= SysDef.FSoffset;  (* 80000H; 256MB in 512-byte blocks (???)*)
	LNK     = SysDef.LNK;       (*RISC5 register 15*)
	
  (* PO.Applications, chapter 14.1, page 74; RISC5.Update page 2 *)
  SysStartAdr = SysDef.SysStartAdr; (* =  0;*)
  IntVecAdr   = SysDef.IntVecAdr;   (* =  4; *)
  MemLimAdr   = SysDef.MemLimAdr;   (* = 12; *)
  ModAllocAdr = SysDef.ModAllocAdr; (* = 16; *)
  ModRootAdr  = SysDef.ModRootAdr;  (* = 20; *)
  ModLimAdr   = SysDef.ModLimAdr;   (* = 24; *)
	
  TYPE Sector* = ARRAY SectorLength OF BYTE;
    Handler* = PROCEDURE(src, dst: LONGINT; s: ARRAY OF CHAR; VAR continue: BOOLEAN): INTEGER;

  VAR allocated*, NofSectors*: INTEGER;
    heapOrg*, heapLim*: INTEGER; 
    stackOrg*, stackSize*, MemLim*: INTEGER;
    clock: INTEGER;
    list0, list1, list2, list3: INTEGER;  (*lists of free blocks of size n*256, 128, 64, 32 bytes*)
    data: INTEGER; (*SPI data in*)
    sectorMap: ARRAY mapsize DIV 32 OF SET;
    
(* ---------- New: heap allocation ----------*)

  PROCEDURE GetBlock(VAR p: LONGINT; len: LONGINT);
    (*len is multiple of 256*)
    VAR q0, q1, q2, size: LONGINT; done: BOOLEAN;
  BEGIN q0 := 0; q1 := list0; done := FALSE;
    WHILE ~done & (q1 # 0) DO
      SYSTEM.GET(q1, size); SYSTEM.GET(q1+8, q2);
      IF size < len THEN (*no fit*) q0 := q1; q1 := q2
      ELSIF size = len THEN (*extract -> p*)
        done := TRUE; p := q1;
        IF q0 # 0 THEN SYSTEM.PUT(q0+8, q2) ELSE list0 := q2 END
      ELSE (*reduce size*)
        done := TRUE; p := q1; q1 := q1 + len;
        SYSTEM.PUT(q1, size-len); SYSTEM.PUT(q1+4, -1); SYSTEM.PUT(q1+8, q2);
        IF q0 # 0 THEN SYSTEM.PUT(q0+8, q1) ELSE list0 := q1 END
      END
    END ;
    IF ~done THEN p := 0 END
  END GetBlock;

  PROCEDURE GetBlock128(VAR p: LONGINT);
    VAR q: LONGINT;
  BEGIN
    IF list1 # 0 THEN p := list1; SYSTEM.GET(list1+8, list1)
    ELSE GetBlock(q, 256);
      IF q # 0 THEN SYSTEM.PUT(q+128, 128); SYSTEM.PUT(q+132, -1); SYSTEM.PUT(q+136, list1); list1 := q + 128 END ;
      p := q
    END
  END GetBlock128;

  PROCEDURE GetBlock64(VAR p: LONGINT);
    VAR q: LONGINT;
  BEGIN
    IF list2 # 0 THEN p := list2; SYSTEM.GET(list2+8, list2)
    ELSE GetBlock128(q);
      IF q # 0 THEN SYSTEM.PUT(q+64, 64); SYSTEM.PUT(q+68, -1); SYSTEM.PUT(q+72, list2); list2 := q + 64 END ;
      p := q
    END
  END GetBlock64;

  PROCEDURE GetBlock32(VAR p: LONGINT);
    VAR q: LONGINT;
  BEGIN
    IF list3 # 0 THEN p := list3; SYSTEM.GET(list3+8, list3)
    ELSE GetBlock64(q);
      IF q # 0 THEN SYSTEM.PUT(q+32, 32); SYSTEM.PUT(q+36, -1); SYSTEM.PUT(q+40, list3); list3 := q + 32 END ;
      p := q
    END
  END GetBlock32;

  PROCEDURE New*(VAR ptr: LONGINT; tag, len, elemsize: LONGINT);
    (*called by NEW via MT[0]; ptr is a pointer; tag (or tag-1) is a pointer or blktyp; len and elemsize describe arrays*)
    VAR p, size, lim: LONGINT;
  BEGIN
    IF tag MOD 4 = 0 THEN (*record block*)
      SYSTEM.GET(tag, size);  (*size already converted for heap allocation with 8 byte prefix*)
      IF size = 32 THEN GetBlock32(p)
      ELSIF size = 64 THEN GetBlock64(p)
      ELSIF size = 128 THEN GetBlock128(p)
      ELSE GetBlock(p, (size+255) DIV 256 * 256)
      END ;
      IF p = 0 THEN ptr := 0
      ELSE ptr := p+8; SYSTEM.PUT(p, tag); lim := p + size; INC(p, 4); INC(allocated, size);
        WHILE p < lim DO SYSTEM.PUT(p, 0); INC(p, 4) END
      END
    ELSE (*array block*)
      size := len*elemsize;  (*convert size for heap allocation with 24 byte prefix*)
      IF size <= 8 THEN size := 32; GetBlock32(p)
      ELSIF size <= 40 THEN size := 64; GetBlock64(p)
      ELSIF size <= 104 THEN size := 128; GetBlock128(p)
      ELSE size := (size+279) DIV 256 * 256; GetBlock(p, size)
      END ;
      IF p = 0 THEN ptr := 0
      ELSE ptr := p+8; SYSTEM.PUT(p, tag); SYSTEM.PUT(p+4, 0); SYSTEM.PUT(p+8, len);
        SYSTEM.PUT(p+12, elemsize); SYSTEM.PUT(p+16, size); lim := p + size; INC(p, 20); INC(allocated, size);
        WHILE p < lim DO SYSTEM.PUT(p, 0); INC(p, 4) END
      END
    END
  END New;

(* ---------- Garbage collector ----------*)

  PROCEDURE Mark*(pref: LONGINT);
    VAR pvadr, offadr, offset, tag, p, q, r, pos, len, elemsize, blktyp: LONGINT;
  BEGIN SYSTEM.GET(pref, pvadr); (*pointers < heapOrg considered NIL*)
    WHILE pvadr # 0 DO
      SYSTEM.GET(pvadr, p); SYSTEM.GET(p-4, offadr);
      IF (p >= heapOrg) & (offadr = 0) THEN q := p;  (*mark elements in data structure with root p*)
        REPEAT SYSTEM.GET(p-4, offadr); SYSTEM.GET(p-8, tag); blktyp := tag MOD 4;
          IF blktyp = 0 THEN (*record*) pos := p;
            IF offadr = 0 THEN offadr := tag + 16 ELSE INC(offadr, 4) END ;
            SYSTEM.PUT(p-4, offadr); SYSTEM.GET(offadr, offset)
          ELSIF blktyp = 1 THEN (*array of record*)
            IF offadr = 0 THEN offadr := tag + 15; pos := p + 16; SYSTEM.PUT(p+12, pos) ELSE INC(offadr); SYSTEM.GET(p+12, pos) END ;
            SYSTEM.GET(offadr, offset);
            IF offset = -1 THEN SYSTEM.GET(p, len); SYSTEM.GET(p+4, elemsize); INC(pos, elemsize);
              IF pos < p + 16 + len*elemsize THEN offadr := tag + 15; SYSTEM.GET(offadr, offset); SYSTEM.PUT(p+12, pos) END
            END ;
            SYSTEM.PUT(p-4, offadr)
          ELSIF blktyp = 2 THEN (*array of pointer*) pos := p + 16;
            IF offadr = 0 THEN offset := 0; SYSTEM.PUT(p-4, p+12) (*offadr*)
            ELSE SYSTEM.GET(p, len); SYSTEM.GET(p+12, offset); INC(offset, 4);
              IF offset >= len*4 THEN offset := -1 END
            END ;
            SYSTEM.PUT(p+12, offset)
          ELSE (*array of basic type (tag = 3) or array of procedure (tag = 7)*)
            offset := -1; SYSTEM.PUT(p+12, -1); SYSTEM.PUT(p-4, p+12) (*offadr*)
          END ;
          IF offset # -1 THEN (*down*)
            SYSTEM.GET(pos+offset, r); SYSTEM.GET(r-4, offadr);
            IF (r >= heapOrg) & (offadr = 0) THEN SYSTEM.PUT(pos+offset, q); q := p; p := r END
          ELSE (*up*) SYSTEM.GET(q-4, offadr); SYSTEM.GET(offadr, offset);
            IF p # q THEN SYSTEM.GET(q-8, tag); blktyp := tag MOD 4;
              IF blktyp = 0 THEN pos := q ELSIF blktyp = 1 THEN SYSTEM.GET(q+12, pos) ELSE pos := q + 16 END ;
              SYSTEM.GET(pos+offset, r); SYSTEM.PUT(pos+offset, p); p := q; q := r
            END
          END
        UNTIL (p = q) & (offset = -1)
      END ;
      INC(pref, 4); SYSTEM.GET(pref, pvadr)
    END
  END Mark;

  PROCEDURE Collect*;
    VAR p, q, mark, tag, size: LONGINT;
  BEGIN p := heapOrg;
    REPEAT SYSTEM.GET(p+4, mark); q := p;
      WHILE mark = 0 DO SYSTEM.GET(p, tag);
        IF tag MOD 4 = 0 THEN (*record*) SYSTEM.GET(tag, size) ELSE (*array*) SYSTEM.GET(p+16, size) END ;
        INC(p, size); SYSTEM.GET(p+4, mark)
      END ;
      size := p - q; DEC(allocated, size);  (*size of free block*)
      IF size > 0 THEN
        IF size MOD 64 # 0 THEN
          SYSTEM.PUT(q, 32); SYSTEM.PUT(q+4, -1); SYSTEM.PUT(q+8, list3); list3 := q; INC(q, 32); DEC(size, 32)
        END ;
        IF size MOD 128 # 0 THEN
          SYSTEM.PUT(q, 64); SYSTEM.PUT(q+4, -1); SYSTEM.PUT(q+8, list2); list2 := q; INC(q, 64); DEC(size, 64)
        END ;
        IF size MOD 256 # 0 THEN
          SYSTEM.PUT(q, 128); SYSTEM.PUT(q+4, -1); SYSTEM.PUT(q+8,  list1); list1 := q; INC(q, 128); DEC(size, 128)
        END ;
        IF size > 0 THEN
          SYSTEM.PUT(q, size); SYSTEM.PUT(q+4, -1); SYSTEM.PUT(q+8, list0); list0 := q; INC(q, size)
        END
      END ;
      IF mark > 0 THEN SYSTEM.GET(p, tag);
        IF tag MOD 4 = 0 THEN (*record*) SYSTEM.GET(tag, size) ELSE (*array*) SYSTEM.GET(p+16, size) END ;
        SYSTEM.PUT(p+4, 0); INC(p, size);
      ELSE (*free*) SYSTEM.GET(p, size); INC(p, size)
      END
    UNTIL p >= heapLim
  END Collect;

(* ---------- Generic heap scan ----------*)

  PROCEDURE Scan*(typ, ptr, pvr: Handler; s: ARRAY OF CHAR; VAR resTyp, resPtr, resPvr: INTEGER);
    VAR offadr, offset, p, r, mark, tag, size, pos, len, elemsize, blktyp: LONGINT; continue: BOOLEAN;
  BEGIN p := heapOrg; resTyp := 0; resPtr := 0; resPvr := 0; continue := (typ # NIL) OR (ptr # NIL) OR (pvr # NIL);
    REPEAT SYSTEM.GET(p+4, mark);
      IF mark < 0 THEN (*free*) SYSTEM.GET(p, size)
      ELSE (*allocated*) SYSTEM.GET(p, tag); blktyp := tag MOD 4;
        IF blktyp = 0 THEN (*record*) SYSTEM.GET(tag, size) ELSE (*array*) SYSTEM.GET(p+16, size) END ;
        IF mark > 0 THEN (*marked*) SYSTEM.PUT(p+4, 0);
          IF continue THEN
            IF blktyp = 0 THEN (*record*)
              IF typ # NIL THEN INC(resTyp, typ(p, tag, s, continue)) END ;
              IF continue & ((ptr # NIL) OR (pvr # NIL)) THEN offadr := tag + 16; SYSTEM.GET(offadr, offset);
                WHILE continue & (offset # -1) DO (*pointers*)
                  IF ptr # NIL THEN SYSTEM.GET(p+8+offset, r); INC(resPtr, ptr(p+8+offset, r, s, continue)) END ;
                  INC(offadr, 4); SYSTEM.GET(offadr, offset)
                END ;
                IF continue & (pvr # NIL) THEN INC(offadr, 4); SYSTEM.GET(offadr, offset);
                  WHILE continue & (offset # -1) DO (*procedures*) SYSTEM.GET(p+8+offset, r);
                    INC(resPvr, pvr(p+8+offset, r, s, continue));
                    INC(offadr, 4); SYSTEM.GET(offadr, offset)
                  END
                END
              END
            ELSIF blktyp = 1 THEN (*array of record*)
              IF typ # NIL THEN INC(resTyp, typ(p, tag-1, s, continue)) END ;
              IF continue & ((ptr # NIL) OR (pvr # NIL)) THEN offadr := tag + 15; SYSTEM.GET(offadr, offset);
                SYSTEM.GET(p+8, len); SYSTEM.GET(p+12, elemsize); len := p + 24 + len*elemsize;
                WHILE continue & (offset # -1) DO (*pointers*)
                  IF ptr # NIL THEN pos := p + 24;
                    WHILE continue & (pos < len) DO SYSTEM.GET(pos+offset, r);
                      INC(resPtr, ptr(pos+offset, r, s, continue)); INC(pos, elemsize)
                    END
                  END ;
                  INC(offadr, 4); SYSTEM.GET(offadr, offset)
                END ;
                IF continue & (pvr # NIL) THEN INC(offadr, 4); SYSTEM.GET(offadr, offset);
                  WHILE continue & (offset # -1) DO (*procedures*) pos := p + 24;
                    WHILE continue & (pos < len) DO SYSTEM.GET(pos+offset, r);
                      INC(resPvr, pvr(pos+offset, r, s, continue)); INC(pos, elemsize)
                    END ;
                    INC(offadr, 4); SYSTEM.GET(offadr, offset)
                  END
                END
              END
            ELSIF blktyp = 2 THEN (*array of pointer*)
              IF ptr # NIL THEN SYSTEM.GET(p+8, len); pos := p + 24; len := pos + len*4;
                WHILE continue & (pos < len) DO SYSTEM.GET(pos, r);
                  INC(resPtr, ptr(pos, r, s, continue)); INC(pos, 4)
                END
              END
            ELSIF (tag = 7) & (pvr # NIL) THEN (*array of procedure*)
              SYSTEM.GET(p+8, len); pos := p + 24; len := pos + len*4;
              WHILE continue & (pos < len) DO SYSTEM.GET(pos, r);
                INC(resPvr, pvr(pos, r, s, continue)); INC(pos, 4)
              END
            END
          END
        END
      END ;
      INC(p, size)
    UNTIL p >= heapLim
  END Scan;

(* ---------- Disk storage management ----------*)

  PROCEDURE SPIIdle(n: INTEGER); (*send n FFs slowly with no card selected*)
  BEGIN SYSTEM.PUT(spiCtrl, 0);
    WHILE n > 0 DO DEC(n); SYSTEM.PUT(spiData, -1);
      REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0);
      SYSTEM.GET(spiData, data)
    END
  END SPIIdle;

  PROCEDURE SPI(n: INTEGER); (*send&rcv byte slowly with card selected*)
  BEGIN SYSTEM.PUT(spiCtrl, CARD0); SYSTEM.PUT(spiData, n);
    REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0);
    SYSTEM.GET(spiData, data)
  END SPI;

  PROCEDURE SPICmd(n, arg: INTEGER);
    VAR i, crc: INTEGER;
  BEGIN (*send cmd*)
    REPEAT SPIIdle(1) UNTIL data = 255; (*flush while unselected*)
    REPEAT SPI(255) UNTIL data = 255; (*flush while selected*)
    IF n = 8 THEN crc := 135 ELSIF n = 0 THEN crc := 149 ELSE crc := 255 END;
    SPI(n MOD 64 + 64); (*send command*)
    FOR i := 24 TO 0 BY -8 DO SPI(ROR(arg, i)) END; (*send arg*)
    SPI(crc); i := 32;
    REPEAT SPI(255); DEC(i) UNTIL (data < 80H) OR (i = 0)
  END SPICmd;

  PROCEDURE SDShift(VAR n: INTEGER);
    VAR data: INTEGER;
  BEGIN SPICmd(58, 0);  (*CMD58 get card capacity bit*)
    SYSTEM.GET(spiData, data); SPI(-1);
    IF (data # 0) OR ~SYSTEM.BIT(spiData, 6) THEN n := n * 512 END ;  (*non-SDHC card*)
    SPI(-1); SPI(-1); SPIIdle(1)  (*flush response*)
  END SDShift;

  PROCEDURE ReadSD(src, dst: INTEGER);
    VAR i: INTEGER;
  BEGIN SDShift(src); SPICmd(17, src); ASSERT(data = 0); (*CMD17 read one block*)
    i := 0; (*wait for start data marker*)
    REPEAT SPI(-1); INC(i) UNTIL data = 254;
    SYSTEM.PUT(spiCtrl, SPIFAST + CARD0);
    FOR i := 0 TO 508 BY 4 DO
      SYSTEM.PUT(spiData, -1);
      REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0);
      SYSTEM.GET(spiData, data); SYSTEM.PUT(dst, data); INC(dst, 4)
    END;
    SPI(255); SPI(255); SPIIdle(1) (*may be a checksum; deselect card*)
  END ReadSD;

  PROCEDURE WriteSD(dst, src: INTEGER);
    VAR i, n: INTEGER; x: BYTE;
  BEGIN SDShift(dst); SPICmd(24, dst); ASSERT(data = 0); (*CMD24 write one block*)
    SPI(254); (*write start data marker*)
    SYSTEM.PUT(spiCtrl, SPIFAST + CARD0);
    FOR i := 0 TO 508 BY 4 DO
      SYSTEM.GET(src, n); INC(src, 4); SYSTEM.PUT(spiData, n);
      REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0)
    END;
    SPI(255); SPI(255); (*dummy checksum*) i := 0;
    REPEAT SPI(-1); INC(i); UNTIL (data MOD 32 = 5) OR (i = 10000);
    ASSERT(data MOD 32 = 5); SPIIdle(1) (*deselect card*)
  END WriteSD;

  PROCEDURE InitSecMap*;
    VAR i: INTEGER;
  BEGIN NofSectors := 0;
    FOR i := 0 TO 4 DO sectorMap[i] := {0 .. 31} END ;           (*mark blocks 0-159 (=5*32 = 160 blocks) as allocated*)
    FOR i := 5 TO mapsize DIV 32 - 1 DO sectorMap[i] := {} END   (*mark blocks 160-65536 (=64K-160 blocks) as unallocated*)
  END InitSecMap;

  PROCEDURE MarkSector*(sec: INTEGER);
  BEGIN sec := sec DIV 29; ASSERT(SYSTEM.H(0) = 0);
    INCL(sectorMap[sec DIV 32], sec MOD 32); INC(NofSectors)
  END MarkSector;

  PROCEDURE FreeSector*(sec: INTEGER);
  BEGIN sec := sec DIV 29; ASSERT(SYSTEM.H(0) = 0);
    EXCL(sectorMap[sec DIV 32], sec MOD 32); DEC(NofSectors)
  END FreeSector;

  PROCEDURE AllocSector*(hint: INTEGER; VAR sec: INTEGER);
    VAR s: INTEGER;
  BEGIN (*find free sector, starting after hint*)
    hint := hint DIV 29; ASSERT(SYSTEM.H(0) = 0); s := hint;
    REPEAT INC(s);
      IF s = mapsize THEN s := 1 END ;
    UNTIL ~(s MOD 32 IN sectorMap[s DIV 32]);
    INCL(sectorMap[s DIV 32], s MOD 32); INC(NofSectors); sec := s * 29
  END AllocSector;

  PROCEDURE GetSector*(src: INTEGER; VAR dst: Sector);
  BEGIN src := src DIV 29; ASSERT(SYSTEM.H(0) = 0);
    src := src * 2 + FSoffset;
    ReadSD(src, SYSTEM.ADR(dst)); ReadSD(src+1, SYSTEM.ADR(dst)+512) 
  END GetSector;
  
  PROCEDURE PutSector*(dst: INTEGER; VAR src: Sector);
  BEGIN dst := dst DIV 29; ASSERT(SYSTEM.H(0) =  0);
    dst := dst * 2 + FSoffset;
    WriteSD(dst, SYSTEM.ADR(src)); WriteSD(dst+1, SYSTEM.ADR(src)+512)
  END PutSector;

(*-------- Miscellaneous procedures----------*)

  PROCEDURE Time*(): INTEGER;
    VAR t: INTEGER;
  BEGIN SYSTEM.GET(timer, t); RETURN t
  END Time;

  PROCEDURE Clock*(): INTEGER;
  BEGIN RETURN clock
  END Clock;

  PROCEDURE SetClock*(dt: INTEGER);
  BEGIN clock := dt
  END SetClock;

  PROCEDURE Install*(Padr, at: INTEGER);
  (*WS See RISC5.Update page 2 *)
  BEGIN 
    SYSTEM.PUT(at, 0E7000000H + (Padr - at) DIV 4 -1)
    (*WS This calculation looks mysterious*)
  END Install;

  PROCEDURE Trap (VAR a: INTEGER; b, c, d: INTEGER);
    VAR u, v, w: INTEGER;
  BEGIN 
    u := SYSTEM.REG(LNK); (*WS REG15 holds return address LNK *)
    SYSTEM.GET(u - 4, v); 
    w := v DIV 10H MOD 10H; (*trap number*)
    IF w = 0 THEN 
       New(a, b, c, d)
    ELSE (*stop*) LED(w + 192); 
    REPEAT UNTIL FALSE
    END
  END Trap;

PROCEDURE Init*;
BEGIN 
  Install(SYSTEM.ADR(Trap), 20H);  (*install temporary trap*)
  SYSTEM.GET(MemLimAdr, MemLim);  (*12*)
  SYSTEM.GET(ModLimAdr, heapOrg); (*24*)
  stackOrg := heapOrg; 
  stackSize := STKSIZ;   (*WS 8000H was hardwired here *)
  heapLim := MemLim;
  list1 := 0; list2 := 0; list3 := 0; 
  list0 := heapOrg;
  SYSTEM.PUT(list0 + 0, heapLim - heapOrg); 
  SYSTEM.PUT(list0 + 4, -1); 
  SYSTEM.PUT(list0 + 8,  0);
  allocated := 0; 
  clock := 0; 
  InitSecMap
END Init;

END Kernel.
