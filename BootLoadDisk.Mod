MODULE* BootLoadDisk;  (*NW 20.10.2013 / PR 4.2.2014 / AP 1.11.2017 for use in Oberon0*)
  IMPORT SYSTEM, SysDef;
  (* sw0: init SD; sw1: line|disk*)
CONST VERSION* = "BootLoadDisk NW AP 1.11.2017 Oberon0";
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

  PROCEDURE ReadSD(src, dst, lim: INTEGER);
    VAR i, data: INTEGER;
  BEGIN SDShift(src); SPICmd(17, src); (*CMD17 read one block*)
    i := 0; (*wait for start data marker*)
    REPEAT SPI(-1); SYSTEM.GET(spiData, data); INC(i) UNTIL data = 254;
    SYSTEM.PUT(spiCtrl, SPIFAST + CARD0);
    i := 0;
    WHILE (i < 512) & (dst < lim) DO (*don't write beyond limit*)
      SYSTEM.PUT(spiData, -1);
      REPEAT UNTIL SYSTEM.BIT(spiCtrl, 0);
      SYSTEM.GET(spiData, data); SYSTEM.PUT(dst, data); INC(dst, 4); INC(i, 4)
    END;
    SPI(255); SPI(255); SPIIdle(1) (*may be a checksum; deselect card*)
  END ReadSD;

  PROCEDURE LoadFromDisk*;
    VAR src, dst, adr, lim: INTEGER;
  BEGIN src := FSoffset + 4;   (*start at boot block*)
    ReadSD(src, 0, 512); 
    SYSTEM.GET(ModAllocAdr, lim);  (*16*)
    INC(src); dst := 512;
    WHILE dst < lim DO ReadSD(src, dst, lim); INC(src); INC(dst, 512) END
  END LoadFromDisk;

BEGIN 
  SYSTEM.LDREG  (SP, stackOrg); 
  SYSTEM.LDREG  (MT, MTOrg);
  IF SYSTEM.REG (LNK) = 0 THEN (*cold start*) LED(80H); InitSPI END ;
  LED(82H); LoadFromDisk;
  SYSTEM.PUT(MemLimAdr, MemLim);   (*12*)
  SYSTEM.PUT(ModLimAdr, stackOrg); (*24*)
  LED(84H)
END BootLoadDisk.
