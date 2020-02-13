(*WS This file contains several separate independent modules *)
(*  ORP.Compile @
    ORX.WriteFile BootLoad.rsc 512 "D:/Verilog/RISC5/prom.mem"~ *)

MODULE* BootLoad;  (*NW 20.10.2013 / PR 4.2.2014; boot from SDHC disk or line*)
  IMPORT SYSTEM, SysDef;
  (* sw0: init SD; sw1: line|disk*)
CONST VERSION* = "BootLoad PR 4.2.2014";
(*WS this BootLoad does NOT use Register 13. The other BootLoad does. Why??*)
  MT     = SysDef.MT;         (* 12; *)
  SB     = SysDef.SB;         (* 13; not used in this module, why?*)
  SP     = SysDef.SP;         (* 14; *)
  LNK    = SysDef.LNK;        (* 15; *)
  MTOrg  = SysDef.MTOrg;      (* 20H; *)
  MemLim = SysDef.MEMLIM;     (* 0E7EF0H; *)
  stackOrg = SysDef.STACKORG; (* 80000H; *)
  FSoffset = SysDef.FSoffset; (* 80000H; *)   (*block offset*)
  swi     = SysDef.SWITCH;    (* -60; *) 
  led     = SysDef.LEDS;      (* -60; *) 
  rsData  = SysDef.RSDATA;    (* -56; *) 
  rsCtrl  = SysDef.RSCTRL;    (* -52; *)
  spiData = SysDef.SPIDATA;   (* -48; *) 
  spiCtrl = SysDef.SPICTRL;   (* -44; *)
  CARD0   = SysDef.CARD0;     (* 1; *) 
  SPIFAST = SysDef.SPIFAST;   (* 4; *)
  (* PO.Applications, chapter 14.1, page 74; RISC5.Update page 2 *)
  SysStartAdr = SysDef.SysStartAdr; (* =  0;*)
  IntVecAdr   = SysDef.IntVecAdr;   (* =  4; *)
  MemLimAdr   = SysDef.MemLimAdr;   (* = 12; *)
  ModAllocAdr = SysDef.ModAllocAdr; (* = 16; *)
  ModRootAdr  = SysDef.ModRootAdr;  (* = 20; *)
  ModLimAdr   = SysDef.ModLimAdr;   (* = 24; *)

  PROCEDURE RecInt(VAR x: INTEGER);
    VAR z, y, i: INTEGER;
  BEGIN z := 0;  i := 4;
    REPEAT i := i-1;
      REPEAT UNTIL SYSTEM.BIT(rsCtrl, 0);
      SYSTEM.GET(rsData, y); z := ROR(z+y, 8)
    UNTIL i = 0;
    x := z
  END RecInt;

  PROCEDURE LoadFromLine;
    VAR len, adr, dat: INTEGER;
  BEGIN RecInt(len);
    WHILE len > 0 DO
      RecInt(adr);
      REPEAT RecInt(dat); SYSTEM.PUT(adr, dat); adr := adr + 4; len := len - 4 UNTIL len = 0;
      RecInt(len)
    END
  END LoadFromLine;

(* ---------- disk ------------*)

  PROCEDURE SPIIdle(n: INTEGER); (*send n FFs slowly with no card selected*)
  BEGIN SYSTEM.PUT(spiCtrl, 0);
    WHILE n > 0 DO DEC(n); SYSTEM.PUT(spiData, -1);
      REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0)
    END
  END SPIIdle;

  PROCEDURE SPI(n: INTEGER); (*send&rcv byte slowly with card selected*)
  BEGIN SYSTEM.PUT(spiCtrl, CARD0); SYSTEM.PUT(spiData, n);
    REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0)
  END SPI;

  PROCEDURE SPICmd(n, arg: INTEGER);
    VAR i, data, crc: INTEGER;
  BEGIN (*send cmd*)
    REPEAT SPIIdle(1); SYSTEM.GET(spiData, data) UNTIL data = 255; (*flush while unselected*)
    REPEAT SPI(255); SYSTEM.GET(spiData, data) UNTIL data = 255; (*flush while selected*)
    IF n = 8 THEN crc := 135 ELSIF n = 0 THEN crc := 149 ELSE crc := 255 END;
    SPI(n MOD 64 + 64); (*send command*)
    FOR i := 24 TO 0 BY -8 DO SPI(ROR(arg, i)) END; (*send arg*)
    SPI(crc); i := 32;
    REPEAT SPI(255); SYSTEM.GET(spiData, data); DEC(i) UNTIL (data < 80H) OR (i = 0)
  END SPICmd;

  PROCEDURE InitSPI;
    VAR res, data: INTEGER;
  BEGIN SPIIdle(9); (*first, idle for at least 80 clks*)
    SPICmd(0, 0); (*CMD0 when card selected, sets MMC SPI mode*)
    SPICmd(8, 1AAH); SPI(-1); SPI(-1); SPI(-1); (*CMD8 for SD cards*)
    REPEAT (*until card becomes ready*)
      (*ACMD41, optionally with high-capacity (HCS) bit set, starts init*)
      SPICmd(55, 0); (*APP cmd follows*)
      SPICmd(41, LSL(1(*HCS*), 30));
      SYSTEM.GET(spiData, res);
      SPI(-1); SPI(-1); SPI(-1); (*flush response*)
      SPIIdle(10000)
    UNTIL res = 0;
    (*CMD16 set block size as a precaution (should default)*)
    SPICmd(16, 512); SPIIdle(1)
  END InitSPI;

  PROCEDURE SDShift(VAR n: INTEGER);
    VAR data: INTEGER;
  BEGIN SPICmd(58, 0);  (*CMD58 get card capacity bit*)
    SYSTEM.GET(spiData, data); SPI(-1);
    IF (data # 0) OR ~SYSTEM.BIT(spiData, 6) THEN n := n * 512 END ;  (*non-SDHC card*)
    SPI(-1); SPI(-1); SPIIdle(1)  (*flush response*)
  END SDShift;

  PROCEDURE ReadSD(src, dst: INTEGER);
    VAR i, data: INTEGER;
  BEGIN SDShift(src); SPICmd(17, src); (*CMD17 read one block*)
    i := 0; (*wait for start data marker*)
    REPEAT SPI(-1); SYSTEM.GET(spiData, data); INC(i) UNTIL data = 254;
    SYSTEM.PUT(spiCtrl, SPIFAST + CARD0);
    FOR i := 0 TO 508 BY 4 DO
      SYSTEM.PUT(spiData, -1);
      REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0);
      SYSTEM.GET(spiData, data); SYSTEM.PUT(dst, data); INC(dst, 4)
    END;
    SPI(255); SPI(255); SPIIdle(1) (*may be a checksum; deselect card*)
  END ReadSD;

  PROCEDURE LoadFromDisk;
    VAR src, dst, adr, lim: INTEGER;
  BEGIN src := FSoffset + 4;   (*start at boot block*)
    ReadSD(src, 0); 
    SYSTEM.GET(ModAllocAdr, lim);  (*16*)
    INC(src); dst := 512;
    WHILE dst < lim DO ReadSD(src, dst); INC(src); INC(dst, 512) END
  END LoadFromDisk;

BEGIN SYSTEM.LDREG(SP, stackOrg); 
  SYSTEM.LDREG(MT, MTOrg);
  IF SYSTEM.REG(LNK) = 0 THEN (*cold start*)
    LED(80H); InitSPI;
    IF SYSTEM.BIT(swi, 0) THEN LED(81H); LoadFromLine ELSE LED(82H); LoadFromDisk END ;
  ELSIF SYSTEM.BIT(swi, 0) THEN LED(81H); LoadFromLine
  END ;
  SYSTEM.PUT(MemLimAdr, MemLim);   (*12*)
  SYSTEM.PUT(ModLimAdr, stackOrg); (*24*)
  LED(84H)
END BootLoad. (*WS Loader version 1, for SD card and line*)

ORP.Compile @  ORG.Decode
ORX.WriteFile BootLoad.rsc "Spartan" "D:/Verilog/RISC/scripts/ins1.mem"~
ORG.WriteFile BootLoad.rsc "Spartan" "D:/Verilog/RISC3/scripts/ins1.mem" ~
ORG.WriteFile BootLoad.rsc "Spartan" "D:/Verilog/RISC5/scripts/ins1.mem"~
(*WS ----------------------------------------------------------------------*)

MODULE* BootLoad;  (*NW 10.2.2013, boot from line only*)
  IMPORT SYSTEM, SysDef;
CONST VERSION* = "BootLoad NW 10.2.2013, boot from line only";
  MTOrg  = SysDef.MTOrg;   (* 20H; *)
  MT     = SysDef.MT;      (* 12; *)
  SB     = SysDef.SB;      (* 13; it is used in this module, but not in the other*)
  SP     = SysDef.SP;      (* 14; *)
  LNK    = SysDef.LNK;     (* 15; not used here, but used in the other module*)
  StkOrg = 0FFFE7F00H;     (*WS Different from the other BootLoad!*)
  swi  = SysDef.SWITCH;    (* -60; *) 
  led  = SysDef.LEDS;      (* -60; *) 
  data = SysDef.RSDATA;    (* -56; *) 
  stat = SysDef.RSCTRL;    (* -52; *)
  (* PO.Applications, chapter 14.1, page 74; RISC5.Update page 2 *)
  SysStartAdr = SysDef.SysStartAdr; (* =  0;*)
  IntVecAdr   = SysDef.IntVecAdr;   (* =  4; *)
  MemLimAdr   = SysDef.MemLimAdr;   (* = 12; *)
  ModAllocAdr = SysDef.ModAllocAdr; (* = 16; *)
  ModRootAdr  = SysDef.ModRootAdr;  (* = 20; *)
  ModLimAdr   = SysDef.ModLimAdr;   (* = 24; *)

  PROCEDURE RecInt(VAR x: INTEGER);
    VAR z, y, i: INTEGER;
  BEGIN z := 0;  i := 4;
    REPEAT i := i-1;
      REPEAT UNTIL SYSTEM.BIT(stat, 0);
      SYSTEM.GET(data, y); z := ROR(z+y, 8)
    UNTIL i = 0;
    x := z
  END RecInt;

  PROCEDURE Load;
    VAR len, adr, dat: INTEGER;
  BEGIN RecInt(len);
    WHILE len > 0 DO
      RecInt(adr);
      REPEAT 
         RecInt(dat); 
         SYSTEM.PUT(adr, dat); 
         adr := adr + 4; 
         len := len - 4 
      UNTIL len = 0;
      RecInt(len)
    END ;
    SYSTEM.GET  (IntVecAdr,  adr);  (*Mem 4: interrupt vector*)
    SYSTEM.LDREG(SB, adr);  (*Register 13: Static Base Address*)
    SYSTEM.LDREG(MT, MTOrg) (*Register 12: address of the Module Table*)
  END Load;

BEGIN 
  SYSTEM.LDREG(SP, StkOrg); 
  SYSTEM.LDREG(MT, MTOrg); 
  SYSTEM.PUT(led, 128); 
  IF ~SYSTEM.BIT(swi, 0) THEN Load END
END BootLoad. (*WS Loader version 2, for line only*)

ORP.Compile @  ORG.Decode
ORX.WriteFile Counter.rsc 2048 "D:/Verilog/RISC/prom.mem"~
ORX.WriteFile Shifter.rsc 2048 "D:/Verilog/RISC/prom.mem"~
ORX.WriteFile TestInt.rsc 2048 "D:/Verilog/RISC3/scripts/ins1.mem"~
ORX.WriteFile BootLoad.rsc 512 "D:/Verilog/RISC5/prom.mem"~
(*WS ----------------------------------------------------------------------*)

MODULE* Counter;
  VAR x, y, z: INTEGER;
BEGIN LED(1); z := 0;
  REPEAT LED(z); x := 1000;
     REPEAT y := 1000;
       REPEAT y := y-1 UNTIL y = 0;
       x := x-1
     UNTIL x = 0;
     z := z+1
   UNTIL FALSE
END Counter.
(*WS ----------------------------------------------------------------------*)

MODULE* Shifter;
  VAR x, y, z, d: INTEGER;
BEGIN  z := 1; d := 1;
  REPEAT LED(z); x := 1000;
     REPEAT y := 1000;
       REPEAT y := y-1 UNTIL y = 0;
       x := x-1
     UNTIL x = 0;
     IF z = 128 THEN d := -1 ELSIF z = 1 THEN d := 1 END ;
     IF d = 1 THEN z := LSL(z, 1) ELSE z := ASR(z, 1) END
   UNTIL FALSE
END Shifter.
(*WS ----------------------------------------------------------------------*)

(*WS Interrupts are described in RISC5.Update.pdf, page 2*)

MODULE* TestInt;       (*Test interrupts*)
  IMPORT SYSTEM, SysDef;
	CONST 
	  VERSION* = "TestInt NW 15.6.2018";
	  SWITCH    = SysDef.SWITCH;      (* -60 *)
    IntVecAdr = SysDef.IntVecAdr;   (* 4 *)

  VAR led, led1, cnt, cnt1: INTEGER;

  PROCEDURE* Int; (*interrupt every millisecond*)
  BEGIN INC(cnt1);
    IF cnt1 = 500 THEN led1 := 1 - led1; LED(led1); cnt1 := 0 END
  END Int;

BEGIN (*WS module init section*)
  led := 0; led1 := 0; cnt := 0; cnt1 := 0;

  (*WS Interrupt address, RISC5.Update.pdf, page 3*)
  SYSTEM.PUT(IntVecAdr, 0E7000000H + SYSTEM.ADR(Int) DIV 4 - 2);

  SYSTEM.LDPSR(1);  (*int enable*)
  REPEAT
    IF SYSTEM.BIT (SWITCH, 0) THEN  (* location -60 is SWITCH *)
      cnt := 100000;
      REPEAT DEC(cnt) UNTIL cnt = 0;
      LED(led); INC(led)
    END
  UNTIL FALSE;
END TestInt.
