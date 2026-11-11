# T650X — 8-bit 65xx Family CPU Core Emulation Library for Delphi

A small, dependency-free Delphi library that emulates the instruction set of the
8-bit 65xx processor family — from the original NMOS 6502 through the CMOS
65C02 variants. You give it memory, it runs code: instruction-accurate, with
cycle counts per instruction, interrupts, and optional support for the
undocumented NMOS opcodes.

It is meant to be the CPU heart of your own emulator (Apple-1, Apple II,
Commodore, Atari, NES, homebrew SBC, ...): the library does the processor, you
do the rest of the machine by mapping I/O into memory.

## Supported processors

| Variant      | Chip(s)                                   | Notes |
|--------------|-------------------------------------------|-------|
| `cv6502`     | MOS 6502, 6507, 6510, 8500, 8502          | NMOS core. 6507/6510/85xx share the ISA; their differences (address bus width, on-chip I/O port at `$00/$01`) belong to the memory map. |
| `cv2A03`     | Ricoh 2A03 / 2A07 (NES)                   | NMOS core with BCD arithmetic disabled (the D flag is stored but ignored). |
| `cv65SC02`   | 65SC02 (Synertek, GTE, ...)               | CMOS: `BRA`, `PHX/PHY/PLX/PLY`, `STZ`, `TRB/TSB`, `(zp)` mode, `JMP (abs,X)`, `BIT #imm/zp,X/abs,X`, `INC A/DEC A`. |
| `cvR65C02`   | Rockwell R65C02                           | 65SC02 + `RMB0-7`, `SMB0-7`, `BBR0-7`, `BBS0-7`. |
| `cvW65C02`   | WDC W65C02S                               | R65C02 + `WAI`, `STP`. |

The 16-bit 65C816/65802 are **not** supported — they are a different architecture.

## Repository contents

| File                  | Unit             | What it contains |
|-----------------------|------------------|------------------|
| `CPU65xx.pas`         | `CPU65xx`        | `T65xxCPU` — the processor: registers, flags, fetch / decode / execute, addressing modes, BCD arithmetic, stack, interrupts (`IRQ`, `NMI`, `BRK`), run states (`WAI`, `STP`, `JAM`). |
| `CPU65xxOpcodes.pas`  | `CPU65xxOpcodes` | Per-variant opcode tables (instruction, addressing mode, base cycles, page-cross / branch penalties, illegal flag), mnemonics and descriptions, `Instr()` decoder and variant helper functions. No CPU state — usable on its own, e.g. for a disassembler. |
| `CPUMemory.pas`       | `CPUMemory`      | `TCPUMemory` — a flat byte array the CPU reads and writes. `ReadByte` / `WriteByte` are virtual: override them to add I/O, ROM, banking or mirroring. |

Dependencies: `CPU65xx` → `CPU65xxOpcodes`, `CPUMemory`. Only RTL units are used
(`System.*`; `CPUMemory` also uses `Winapi.Windows`, so the library targets Windows
as-is).

## Quick start

Add the three `.pas` files to your project, then:

```pascal
uses
  CPUMemory, CPU65xxOpcodes, CPU65xx;

var
  Mem: TCPUMemory;
  Cpu: T65xxCPU;
begin
  Mem := TCPUMemory.Create($10000, $00);          // 64 KB, filled with $00
  Cpu := T65xxCPU.Create(Mem, cvW65C02);           // pick the variant
  try
    Mem.LoadBytes(TFile.ReadAllBytes('rom.bin'), $E000);
    Cpu.Reset;                                     // PC := word at $FFFC

    while Cpu.State = csRunning do
      Cpu.Step;                                    // one instruction, returns cycles
  finally
    Cpu.Free;
    Mem.Free;
  end;
end;
```

> `T65xxCPU.Create` calls `Reset` itself, which reads the reset vector — if you
> load the program *after* creating the CPU, call `Cpu.Reset` again.

## API

### `T65xxCPU` (unit `CPU65xx`)

| Member | Description |
|--------|-------------|
| `Create(AMemory: TCPUMemory; AVariant: TCPU65xxVariant = cv6502)` | Creates the CPU and resets it. The CPU does **not** own the memory — free it yourself. |
| `Reset` | `A=X=Y=0`, `SP=$FF`, `SR=$24` (I set, D clear), `State=csRunning`, cycle counter cleared, `PC` loaded from `$FFFC`. |
| `Step: Integer` | Fetches and executes one instruction and returns the cycles it took (base + page-cross / branch / CMOS-decimal penalties). Returns `0` and does nothing when the CPU is not `csRunning`. Raises an exception on an opcode it may not execute (see *Illegal opcodes*), with the opcode, address and variant in the message. |
| `IRQ: Integer` | Maskable interrupt request. Ignored when the `I` flag is set (but it still wakes the CPU from `WAI`). Returns 7 when taken, otherwise 0. |
| `NMI: Integer` | Non-maskable interrupt. Returns 7 (0 when stopped / jammed). |
| `PC`, `A`, `X`, `Y`, `SP`, `SR` | Registers — readable and writable (debuggers, save states, test harnesses). |
| `N`, `V`, `B`, `D`, `I`, `Z`, `C` | Read-only flag views of `SR`. |
| `Cycles: UInt64` | Total cycles executed since the last `Reset`. |
| `Variant` | The emulated variant. |
| `State` | `csRunning`, `csWaiting` (after `WAI`, until IRQ/NMI/reset), `csStopped` (after `STP`, until reset), `csJammed` (after an NMOS `JAM`, until reset). |
| `UseIllegalOpcodes: Boolean` | NMOS only — execute undocumented opcodes. Default `False`. |
| `IllegalMagic: Byte` | The chip-dependent constant used by the unstable `ANE`/`LXA` opcodes. Default `$EE`. |
| `Memory` | The memory the CPU is attached to. |

The `STATUS_REGISTER_FLAG_*` constants give the bit numbers of the flags in `SR`;
`VECTOR_NMI`, `VECTOR_RESET`, `VECTOR_IRQ` the vector addresses.

### `TCPUMemory` (unit `CPUMemory`)

| Member | Description |
|--------|-------------|
| `Create(ASize: Integer; APatternFill: Byte)` | Allocates `ASize` bytes (use `$10000`) filled with `APatternFill`. |
| `ReadByte(Addr)` / `WriteByte(Addr, Value)` | **Virtual.** The only way the CPU touches memory — override them to emulate hardware. |
| `ReadWord` / `WriteWord` | Little-endian helpers (direct access, not routed through the virtual methods). |
| `LoadBytes(Data, Address)` | Copies data straight into memory, bypassing overrides — the way to put ROM images into read-only areas. |
| `LoadFromFile(FileName)` / `SaveToFile(FileName)` | Load / dump a raw image starting at `$0000` (`LoadFromFile` resets memory first). |
| `Reset` | Refills memory with the pattern byte. |
| `ByteAtAddress[Addr]` (default) | Direct read, bypassing overrides — handy for debuggers / memory viewers (no I/O side effects). |

### `CPU65xxOpcodes`

| Member | Description |
|--------|-------------|
| `Instr(Variant, OpCode): T65xxInstructionDescriptor` | Decodes an opcode: instruction, mnemonic (`'LDA'`, `'BBR3'`, ...), description, addressing mode (+ human-readable form), base and extra cycles, `Illegal` flag. |
| `VariantName(Variant)` | `'NMOS 6502'`, `'WDC W65C02S'`, ... |
| `IsCMOS`, `HasDecimalMode`, `HasBitInstructions`, `HasWaiStp` | Variant feature queries. |

Addressing modes (`T65xxInstrAddrMode`): `mImp`, `mAcc`, `mImm`, `mZpg`, `mZpX`,
`mZpY`, `mAbs`, `mAbX`, `mAbY`, `mInd`, `mInX`, `mInY`, `mRel`, and the CMOS
`mZpI` `(zp)`, `mAbXI` `(abs,X)`, `mZpRel` `zp,rel`.

## Behaviour per variant

| Behaviour                              | NMOS 6502 | 2A03 | 65SC02 | R65C02 | W65C02S |
|----------------------------------------|:---------:|:----:|:------:|:------:|:-------:|
| BCD arithmetic (`SED`)                 | yes, NMOS flags | no | yes, valid N/Z, +1 cycle | same | same |
| `JMP ($xxFF)` page-wrap bug            | yes       | yes  | fixed (6 cycles) | fixed | fixed |
| `BRK`/`IRQ`/`NMI` clear D              | no        | no   | yes    | yes    | yes     |
| CMOS instructions & `(zp)` mode        | –         | –    | yes    | yes    | yes     |
| `RMB`/`SMB`/`BBR`/`BBS`                | –         | –    | –      | yes    | yes     |
| `WAI`/`STP`                            | –         | –    | –      | –      | yes     |
| Undocumented opcodes                   | optional  | optional | defined NOPs | defined NOPs | defined NOPs |

### Illegal (undocumented) opcodes

On NMOS chips 105 of the 256 opcodes are undocumented. They are fully described
in the opcode tables (`Illegal = True`) and implemented:

`SLO RLA SRE RRA SAX LAX DCP ISC ANC ALR ARR SBX ANE LXA LAS TAS SHA SHX SHY`,
`SBC #imm ($EB)`, all multi-byte `NOP`s and the 12 `JAM` opcodes (the CPU enters
`csJammed`).

Whether they run is your choice:

```pascal
Cpu.UseIllegalOpcodes := False; // default: an illegal opcode raises an exception
Cpu.UseIllegalOpcodes := True;  // run them like the real silicon (C64 / NES software needs this)
```

On CMOS variants every opcode is documented (unused ones are NOPs with defined
length and timing), so the property has no effect there.

## Timing model

The core is **instruction-stepped**: `Step` executes a whole instruction and
returns its cycle count, including page-crossing penalties, taken-branch
penalties and the CMOS decimal-mode cycle. That is enough to pace an emulator
in real time or to drive timers / video per instruction. It does not model
individual bus cycles (dummy reads/writes), so hardware that depends on the
exact cycle within an instruction is out of scope.

Pacing at 1 MHz, for example:

```pascal
Budget := 0;
repeat
  Inc(Budget, 1000000 div 60);                 // cycles per 1/60 s frame
  while (Budget > 0) and (Cpu.State = csRunning) do
    Dec(Budget, Cpu.Step);
  WaitForNextFrame;                            // your timing / rendering
until Quit;
```

## Example: an Apple-1 in ~50 lines

The Apple-1 is about the simplest 6502 computer there is: RAM, the 256-byte
Woz Monitor ROM at `$FF00`, and a 6821 PIA with four registers for the keyboard
and the terminal:

| Address | Register | Meaning |
|---------|----------|---------|
| `$D010` | KBD      | Last key, bit 7 set. Reading it clears the "key ready" flag. |
| `$D011` | KBDCR    | Bit 7 = a key is waiting. |
| `$D012` | DSP      | Write a character to the screen. Bit 7 on read = terminal busy. |
| `$D013` | DSPCR    | Control register (configured by Woz Monitor, can be ignored). |

All of the hardware is a `TCPUMemory` descendant:

```pascal
type
  TApple1Memory = class(TCPUMemory)
  public
    KeyBuffer: String;                          // keystrokes waiting for the CPU
    function ReadByte(const AAddr: Word): Byte; override;
    procedure WriteByte(const Addr: Word; const AByte: Byte); override;
  end;

function TApple1Memory.ReadByte(const AAddr: Word): Byte;
begin
  case AAddr of
    $D010:                                      // KBD: take the key
      if KeyBuffer <> '' then
      begin
        Result := Ord(UpCase(KeyBuffer[1])) or $80;
        Delete(KeyBuffer, 1, 1);
      end else
        Result := $80;
    $D011:                                      // KBDCR: key waiting?
      if KeyBuffer <> '' then Result := $80 else Result := 0;
    $D012:                                      // DSP: terminal never busy
      Result := 0;
  else
    Result := inherited ReadByte(AAddr);
  end;
end;

procedure TApple1Memory.WriteByte(const Addr: Word; const AByte: Byte);
begin
  if Addr = $D012 then                          // DSP: print the character
  begin
    case AByte and $7F of
      $0D:       Writeln;
      $20..$7E:  Write(Chr(AByte and $7F));
    end;
  end
  else if Addr < $FF00 then                     // $FF00-$FFFF is ROM
    inherited WriteByte(Addr, AByte);
end;
```

And the machine itself:

```pascal
Mem := TApple1Memory.Create($10000, 0);
Cpu := T65xxCPU.Create(Mem, cv6502);
Mem.LoadBytes(TFile.ReadAllBytes('wozmon.bin'), $FF00);   // 256-byte Woz Monitor
// optional: Mem.LoadBytes(TFile.ReadAllBytes('basic.rom'), $E000);  // Integer BASIC, run with E000R
Cpu.Reset;                                                // reset vector -> $FF00

loop
  if KeyPressed then
    Mem.KeyBuffer := Mem.KeyBuffer + ReadKey;             // your console / GUI input
  Cpu.Step;
  (pace to ~1 MHz, see "Timing model")
end loop
```

Typing `FF00.FF0F`, then `0:A9 41 20 EF FF 4C 00 00` and `0R` gives:

```
\
FF00.FF0F

FF00: D8 58 A0 7F 8C 12 D0 A9
FF08: A7 8D 11 D0 8D 13 D0 C9
0:A9 41 20 EF FF 4C 00 00

0000: 00
0R

0000: A9AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA...
```

(`LDA #'A' / JSR ECHO / JMP 0` — the "hello world" of the Apple-1.)

## Testing

The core has been verified with:

- **Klaus Dormann's 6502/65C02 functional tests**
  ([Klaus2m5/6502_65C02_functional_tests](https://github.com/Klaus2m5/6502_65C02_functional_tests)):
  `6502_functional_test` passes on NMOS 6502, 65SC02, R65C02 and W65C02S
  (on the 2A03 it stops in the decimal-mode section, as the real chip would);
  `65C02_extended_opcodes_test` passes on R65C02 and W65C02S.
- **Tom Harte's SingleStepTests**
  ([SingleStepTests/65x02](https://github.com/SingleStepTests/65x02)) — a sample of
  ~90 tests per opcode for all 256 opcodes on every variant, comparing registers,
  flags, memory and cycle counts. NMOS 6502 and 2A03 (including all
  undocumented opcodes) pass completely. On the CMOS sets everything documented
  passes; the only differences are a few undocumented CMOS NOPs (`$5C`, Rockwell
  `$CB/$DB`, 65SC02 `$x7/$xF`), where this library follows the WDC datasheet and
  Bruce Clark's 65C02 notes instead.

## Limitations

- Instruction-level, not bus-cycle-level, emulation (see *Timing model*).
- `TCPUMemory` is flat RAM; ROM protection, I/O, banking and mirroring are done
  by overriding `ReadByte`/`WriteByte`.
- The 6510/8500/8502 on-chip I/O port and the 6507's 13-bit address bus are
  memory-map details — implement them in your memory class.
- `IRQ` is edge-style: call it when your device asserts the line (and again
  while it stays asserted, if the handler re-enables interrupts).
- No 65C816 / 65802.

## License

MIT License, Copyright (c) 2026 McManiek. See [LICENSE](LICENSE).
