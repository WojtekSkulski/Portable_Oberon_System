MODULE Blink;   (*NW 30.5.2013*)
  IMPORT SYSTEM, Oberon;
	CONST VERSION* = "Blink NW 30.5.2013";
  VAR z: INTEGER;
    T: Oberon.Task;
  
  PROCEDURE Run*;
  BEGIN Oberon.Install(T)
  END Run;

  PROCEDURE Stop*;
  BEGIN Oberon.Remove(T)
  END Stop;

  PROCEDURE Tick;
  BEGIN z := 1-z; LED(z)
  END Tick;

BEGIN z := 0; T := Oberon.NewTask(Tick, 500)
END Blink.
