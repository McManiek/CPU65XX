unit CPU65xx;

{
  8-bit 65xx family CPU core: NMOS 6502, Ricoh 2A03, 65SC02, R65C02, W65C02S.
  See CPU65xxOpcodes for the variant list.

  Behaviour that differs between variants:
    - opcode map, cycle counts                         (opcode tables)
    - BCD arithmetic: NMOS flags / CMOS flags + 1 cycle / none on 2A03
    - JMP ($xxFF) page wrap bug                        (NMOS only)
    - BRK / IRQ / NMI clear the D flag                 (CMOS only)
    - WAI / STP                                        (WDC only)
    - undocumented opcodes                             (NMOS only, UseIllegalOpcodes)

  Copyright (c) 2026 McManiek
  License: MIT (see LICENSE)
}

interface

uses
  System.SysUtils, CPUMemory, CPU65xxOpcodes;

const
  STATUS_REGISTER_FLAG_NEGATIVE = 7;
  STATUS_REGISTER_FLAG_OVERFLOW = 6;
  STATUS_REGISTER_FLAG_UNUSED = 5;
  STATUS_REGISTER_FLAG_BREAK = 4;
  STATUS_REGISTER_FLAG_DECIMAL = 3;
  STATUS_REGISTER_FLAG_INTERRUPT = 2;
  STATUS_REGISTER_FLAG_ZERO = 1;
  STATUS_REGISTER_FLAG_CARRY = 0;

  VECTOR_NMI = $FFFA;
  VECTOR_RESET = $FFFC;
  VECTOR_IRQ = $FFFE;

  INTERRUPT_CYCLES = 7;

  // "magic" constant of the unstable ANE / LXA opcodes; it differs between
  // individual chips, $EE is the most commonly observed value
  DEFAULT_ILLEGAL_MAGIC = $EE;

type
  TCPU65xxState = (
    csRunning,
    csWaiting, // WAI - until IRQ / NMI / reset
    csStopped, // STP - until reset
    csJammed   // NMOS JAM (illegal opcode) - until reset
  );

  T65xxCPU = class
  strict private
    //registers
    FPC: Word;
    FA: Byte;
    FX: Byte;
    FY: Byte;
    FSR: Byte;
    FSP: Byte;
    FCycles: UInt64;
    FMemory: TCPUMemory;
    FVariant: TCPU65xxVariant;
    FState: TCPU65xxState;
    FUseIllegalOpcodes: Boolean;
    FIllegalMagic: Byte;

    function GetFlag(const ABit: Integer): Boolean; inline;
    procedure SetFlag(const ABit: Integer; const AValue: Boolean); inline;

    function SR_N: Boolean;
    function SR_V: Boolean;
    function SR_B: Boolean;
    function SR_D: Boolean;
    function SR_I: Boolean;
    function SR_Z: Boolean;
    function SR_C: Boolean;

    function ReadByte: Byte;
    function ReadWord: Word;
    function ReadMemWord(const AAddress: Word): Word;

    procedure PushByte(Value: Byte);
    function PopByte: Byte;
    procedure PushWord(Value: Word);
    function PopWord: Word;

    procedure SetZeroFlag(Value: Byte);
    procedure SetNegativeFlag(Value: Byte);
    procedure SetCarryFlag(Value: Boolean);
    procedure SetNZ(Value: Byte);

    function ReadZPWord(Address: Byte): Word;
    function ReadIndirectWord(Address: Word): Word;
    function Assemble(PInstr: P65xxInstrDescriptor): String;
    procedure ResolveOperand(PInstr: P65xxInstrDescriptor);
    procedure ExecuteInstruction(var I: T65xxInstructionDescriptor);
    procedure Branch(var I: T65xxInstructionDescriptor; const ACondition: Boolean);
    procedure Interrupt(const AVector: Word; const ABreak: Boolean);
    procedure ADC(var I: T65xxInstructionDescriptor; const M: Byte);
    procedure SBC(var I: T65xxInstructionDescriptor; const M: Byte);
    procedure Compare(const AReg, AValue: Byte);
    procedure ARR(const M: Byte);
    procedure StoreHighAnd(const I: T65xxInstructionDescriptor; const AValue: Byte);
  public
    //registers
    property PC: Word read FPC write FPC;
    property A: Byte read FA write FA;
    property X: Byte read FX write FX;
    property Y: Byte read FY write FY;
    property SR: Byte read FSR write FSR;
    property SP: Byte read FSP write FSP;

    //flags
    property N: Boolean read SR_N;
    property V: Boolean read SR_V;
    property B: Boolean read SR_B;
    property D: Boolean read SR_D;
    property I: Boolean read SR_I;
    property Z: Boolean read SR_Z;
    property C: Boolean read SR_C;

    property Cycles: UInt64 read FCycles;
    property Memory: TCPUMemory read FMemory;
    property Variant: TCPU65xxVariant read FVariant;
    property State: TCPU65xxState read FState;
    // NMOS only (6502 / 2A03): execute undocumented opcodes (SLO, LAX, DCP, JAM, ...).
    // When False (default) an undocumented opcode raises an exception.
    // No effect on CMOS variants - there every opcode is documented.
    property UseIllegalOpcodes: Boolean read FUseIllegalOpcodes write FUseIllegalOpcodes;
    // constant used by the unstable ANE ($8B) and LXA ($AB) opcodes
    property IllegalMagic: Byte read FIllegalMagic write FIllegalMagic;

    procedure Reset;
    // executes one instruction and returns the number of cycles it took;
    // returns 0 when the CPU is waiting (WAI) or stopped (STP)
    function Step: Integer;
    // hardware interrupts; return the number of cycles taken (0 when ignored)
    function IRQ: Integer;
    function NMI: Integer;

    constructor Create(AMemory: TCPUMemory; const AVariant: TCPU65xxVariant = cv6502);
    destructor Destroy; override;
  end;

implementation

function UsesResolvedAddress(const AInstruction: T65xxInstr): Boolean;
begin
  case AInstruction of
    iSTA, iSTX, iSTY, iSTZ, iJSR, iJMP,
    iSAX, iSHA, iSHX, iSHY, iTAS,
    iBEQ, iBNE, iBCC, iBCS, iBMI, iBPL, iBVS, iBVC, iBRA:
      Result := True;
  else
    Result := False;
  end;
end;

function T65xxCPU.GetFlag(const ABit: Integer): Boolean;
begin
  Result := (FSR and (1 shl ABit)) <> 0;
end;

procedure T65xxCPU.SetFlag(const ABit: Integer; const AValue: Boolean);
begin
  if AValue then
    FSR := FSR or (1 shl ABit)
  else
    FSR := FSR and not (1 shl ABit);
end;

procedure T65xxCPU.SetZeroFlag(Value: Byte);
begin
  SetFlag(STATUS_REGISTER_FLAG_ZERO, Value = 0);
end;

procedure T65xxCPU.SetNegativeFlag(Value: Byte);
begin
  SetFlag(STATUS_REGISTER_FLAG_NEGATIVE, (Value and $80) <> 0);
end;

procedure T65xxCPU.SetCarryFlag(Value: Boolean);
begin
  SetFlag(STATUS_REGISTER_FLAG_CARRY, Value);
end;

procedure T65xxCPU.SetNZ(Value: Byte);
begin
  SetZeroFlag(Value);
  SetNegativeFlag(Value);
end;

function T65xxCPU.ReadByte: Byte;
begin
  Result := FMemory.ReadByte(self.PC);
  FPC := Word((Integer(FPC) + 1) and $FFFF);
end;

function T65xxCPU.ReadWord: Word;
var
  L, H: Byte;
begin
  L := ReadByte; H := ReadByte;
  Result := (H shl 8) + L;
end;

function T65xxCPU.ReadMemWord(const AAddress: Word): Word;
begin
  Result := FMemory.ReadByte(AAddress) or (FMemory.ReadByte(Word(AAddress + 1)) shl 8);
end;

function T65xxCPU.Assemble(PInstr: P65xxInstrDescriptor): String;
  function OperandByte: Byte;
  begin
    if PInstr^.AddressingMode in [mImm, mRel] then
      Result := Byte(PInstr^.Data and $FF)
    else
      Result := Byte(PInstr^.EffectiveAddress and $FF);
  end;
  function OperandWord: Word;
  begin
    if PInstr^.AddressingMode in [mImm, mRel, mInd, mAbXI] then
      Result := PInstr^.Data
    else
      Result := PInstr^.EffectiveAddress;
  end;
begin
  Result := '';

  if not Assigned(PInstr) then
    Exit;

  case PInstr^.AddressingMode of
    mNull:
      raise Exception.Create('Invalid addressing mode!');

    mImp:
      Result := Format('%s', [PInstr^.InstructionName]);
    mInX:
      Result := Format('%s ($%.2X, X)', [PInstr^.InstructionName, OperandByte]);
    mZpg:
      Result := Format('%s $%.2X', [PInstr^.InstructionName, OperandByte]);
    mImm:
      Result := Format('%s #$%.2X', [PInstr^.InstructionName, OperandByte]);
    mAbs:
      Result := Format('%s $%.4X', [PInstr^.InstructionName, OperandWord]);
    mAcc:
      Result := Format('%s A', [PInstr^.InstructionName]);
    mRel:
      Result := Format('%s $%.4X', [PInstr^.InstructionName, OperandWord]);
    mInY:
      Result := Format('%s ($%.2X), Y', [PInstr^.InstructionName, OperandByte]);
    mZpX:
      Result := Format('%s $%.2X, X', [PInstr^.InstructionName, OperandByte]);
    mZpY:
      Result := Format('%s $%.2X, Y', [PInstr^.InstructionName, OperandByte]);
    mAbY:
      Result := Format('%s $%.4X, Y', [PInstr^.InstructionName, OperandWord]);
    mAbX:
      Result := Format('%s $%.4X, X', [PInstr^.InstructionName, OperandWord]);
    mInd:
      Result := Format('%s ($%.4X)', [PInstr^.InstructionName, OperandWord]);
    mZpI:
      Result := Format('%s ($%.2X)', [PInstr^.InstructionName, OperandByte]);
    mAbXI:
      Result := Format('%s ($%.4X, X)', [PInstr^.InstructionName, OperandWord]);
    mZpRel:
      Result := Format('%s $%.2X, $%.4X', [PInstr^.InstructionName, OperandByte, PInstr^.Data]);
  end;
end;

function T65xxCPU.ReadZPWord(Address: Byte): Word;
begin
  Result := FMemory.ReadByte(Address) or (FMemory.ReadByte((Address + 1) and $FF) shl 8);
end;

function T65xxCPU.ReadIndirectWord(Address: Word): Word;
begin
  // NMOS bug: JMP ($xxFF) takes the high byte from $xx00 instead of $xx00 + $100
  if (not IsCMOS(FVariant)) and ((Address and $FF) = $FF) then
    Result := FMemory.ReadByte(Address) or (FMemory.ReadByte(Address and $FF00) shl 8)
  else
    Result := ReadMemWord(Address);
end;

procedure CheckPageCross(PInstr: P65xxInstrDescriptor; const ABase, AAddress: Word);
begin
  // ExtraCycles is non-zero only for instructions that pay for a page cross
  if ((ABase xor AAddress) and $FF00) <> 0 then
    PInstr^.AddedCycles := PInstr^.ExtraCycles;
end;

procedure T65xxCPU.ResolveOperand(PInstr: P65xxInstrDescriptor);
var
  Address, Base: Word;
  Rel: ShortInt;
  ZPAddr: Byte;
  HasAddress: Boolean;
begin
  if not Assigned(PInstr) then
    Exit;

  if PInstr^.Instruction = iNull then
    raise Exception.Create(Format('Invalid instruction [%.2x]!', [PInstr^.OpCode]));
  PInstr^.Data := 0;
  PInstr^.EffectiveAddress := 0;
  PInstr^.BaseAddress := 0;
  HasAddress := True;
  Address := 0;
  Base := 0;

  case PInstr^.AddressingMode of
    mNull:
      raise Exception.Create('Invalid addressing mode!');

    mImp, mAcc:
      HasAddress := False; // no operand

    mImm:
    begin
      PInstr^.Data := Self.ReadByte;
      HasAddress := False;
    end;
    mZpg:
      Address := Self.ReadByte;
    mZpX:
      Address := (Self.ReadByte + Self.X) and $FF;
    mZpY:
      Address := (Self.ReadByte + Self.Y) and $FF;
    mAbs:
      Address := Self.ReadWord;
    mAbX:
    begin
      Base := Self.ReadWord;
      Address := (Base + Self.X) and $FFFF;
      CheckPageCross(PInstr, Base, Address);
    end;
    mAbY:
    begin
      Base := Self.ReadWord;
      Address := (Base + Self.Y) and $FFFF;
      CheckPageCross(PInstr, Base, Address);
    end;
    mInX:
    begin
      ZPAddr := (Self.ReadByte + Self.X) and $FF;
      Address := ReadZPWord(ZPAddr);
    end;
    mInY:
    begin
      ZPAddr := Self.ReadByte;
      Base := ReadZPWord(ZPAddr);
      Address := (Base + Self.Y) and $FFFF;
      CheckPageCross(PInstr, Base, Address);
    end;
    mZpI:
    begin
      ZPAddr := Self.ReadByte;
      Address := ReadZPWord(ZPAddr);
    end;

    mInd: // JMP only
    begin
      PInstr^.Data := ReadIndirectWord(Self.ReadWord);
      HasAddress := False;
    end;
    mAbXI: // JMP only
    begin
      Base := Self.ReadWord;
      PInstr^.Data := ReadMemWord(Word(Base + Self.X));
      HasAddress := False;
    end;

    mRel:
    begin
      Rel := ShortInt(Self.ReadByte);
      PInstr^.Data := Word((Integer(Self.PC) + Rel) and $FFFF);
      HasAddress := False;
    end;
    mZpRel: // BBR / BBS: EffectiveAddress = tested zp address, Data = branch target
    begin
      PInstr^.EffectiveAddress := Self.ReadByte;
      Rel := ShortInt(Self.ReadByte);
      PInstr^.Data := Word((Integer(Self.PC) + Rel) and $FFFF);
      HasAddress := False;
    end;
  end;

  if HasAddress then
  begin
    PInstr^.EffectiveAddress := Address;
    if PInstr^.AddressingMode in [mAbX, mAbY, mInY] then
      PInstr^.BaseAddress := Base
    else
      PInstr^.BaseAddress := Address;
    if UsesResolvedAddress(PInstr^.Instruction) then
      PInstr^.Data := Address
    else
      PInstr^.Data := FMemory.ReadByte(Address);
  end;
end;

procedure T65xxCPU.PushByte(Value: Byte);
begin
  FMemory.WriteByte($0100 + FSP, Value);
  FSP := Byte((Integer(FSP) - 1) and $FF);
end;

function T65xxCPU.PopByte: Byte;
begin
  FSP := Byte((Integer(FSP) + 1) and $FF);
  Result := FMemory.ReadByte($0100 + FSP);
end;

procedure T65xxCPU.PushWord(Value: Word);
begin
  PushByte((Value shr 8) and $FF);
  PushByte(Value and $FF);
end;

function T65xxCPU.PopWord: Word;
var
  L, H: Byte;
begin
  L := PopByte;
  H := PopByte;
  Result := (H shl 8) or L;
end;

procedure T65xxCPU.Interrupt(const AVector: Word; const ABreak: Boolean);
begin
  PushWord(FPC);
  if ABreak then
    PushByte(FSR or $30)
  else
    PushByte((FSR or $20) and not $10);
  SetFlag(STATUS_REGISTER_FLAG_INTERRUPT, True);
  if IsCMOS(FVariant) then
    SetFlag(STATUS_REGISTER_FLAG_DECIMAL, False);
  FPC := ReadMemWord(AVector);
end;

procedure T65xxCPU.ADC(var I: T65xxInstructionDescriptor; const M: Byte);
var
  A, R, Lo, Hi, C: Integer;
begin
  A := FA;
  C := Ord(SR_C);

  if SR_D and HasDecimalMode(FVariant) then
  begin
    Lo := (A and $0F) + (M and $0F) + C;
    if Lo > 9 then
      Inc(Lo, 6);
    Hi := (A shr 4) + (M shr 4) + Ord(Lo > $0F);
    R := (Hi shl 4) or (Lo and $0F);
    // V (and N on NMOS) from the intermediate result
    SetFlag(STATUS_REGISTER_FLAG_OVERFLOW, (((A xor M) and $80) = 0) and (((A xor R) and $80) <> 0));
    if Hi > 9 then
      Inc(Hi, 6);
    SetCarryFlag(Hi > $0F);
    FA := Byte((Hi shl 4) or (Lo and $0F));

    if IsCMOS(FVariant) then
    begin
      // CMOS: N and Z valid for the decimal result, one extra cycle
      SetNZ(FA);
      Inc(I.AddedCycles);
    end else
    begin
      // NMOS: Z from the binary sum, N from the intermediate result
      SetZeroFlag(Byte(A + M + C));
      SetNegativeFlag(Byte(R));
    end;
    Exit;
  end;

  R := A + M + C;
  SetCarryFlag(R > $FF);
  SetFlag(STATUS_REGISTER_FLAG_OVERFLOW, (((A xor M) and $80) = 0) and (((A xor R) and $80) <> 0));
  FA := Byte(R);
  SetNZ(FA);
end;

procedure T65xxCPU.SBC(var I: T65xxInstructionDescriptor; const M: Byte);
var
  A, R, Lo, Hi, C: Integer;
begin
  A := FA;
  C := Ord(SR_C);

  // C and V are the same as in binary mode on every variant
  R := A - M - (1 - C);
  SetCarryFlag(R >= 0);
  SetFlag(STATUS_REGISTER_FLAG_OVERFLOW, (((A xor M) and $80) <> 0) and (((A xor R) and $80) <> 0));
  FA := Byte(R);

  if SR_D and HasDecimalMode(FVariant) then
  begin
    if IsCMOS(FVariant) then
    begin
      // CMOS: N and Z valid for the decimal result, one extra cycle
      Lo := (A and $0F) - (M and $0F) - (1 - C);
      if R < 0 then
        Dec(R, $60);
      if Lo < 0 then
        Dec(R, $06);
      FA := Byte(R);
      SetNZ(FA);
      Inc(I.AddedCycles);
      Exit;
    end;

    // NMOS: flags as in binary mode, only the result is adjusted
    SetNZ(FA);
    Lo := (A and $0F) - (M and $0F) - (1 - C);
    Hi := (A shr 4) - (M shr 4);
    if Lo < 0 then
    begin
      Dec(Lo, 6);
      Dec(Hi);
    end;
    if Hi < 0 then
      Dec(Hi, 6);
    FA := Byte(((Hi shl 4) or (Lo and $0F)) and $FF);
    Exit;
  end;

  SetNZ(FA);
end;

procedure T65xxCPU.Compare(const AReg, AValue: Byte);
begin
  SetCarryFlag(AReg >= AValue);
  SetNZ(Byte(AReg - AValue));
end;

procedure T65xxCPU.ARR(const M: Byte);
var
  T, R, AL, AH, C: Integer;
begin
  // AND #imm followed by ROR A, with its own flag logic
  T := FA and M;
  C := Ord(SR_C);
  R := (T shr 1) or (C shl 7);

  if SR_D and HasDecimalMode(FVariant) then
  begin
    AL := T and $0F;
    AH := T shr 4;
    SetFlag(STATUS_REGISTER_FLAG_NEGATIVE, C <> 0);
    SetZeroFlag(Byte(R));
    SetFlag(STATUS_REGISTER_FLAG_OVERFLOW, ((T xor R) and $40) <> 0);
    if (AL + (AL and 1)) > 5 then
      R := (R and $F0) or ((R + 6) and $0F);
    SetCarryFlag((AH + (AH and 1)) > 5);
    if SR_C then
      R := (R + $60) and $FF;
    FA := Byte(R);
    Exit;
  end;

  FA := Byte(R);
  SetNZ(FA);
  SetCarryFlag((FA and $40) <> 0);
  SetFlag(STATUS_REGISTER_FLAG_OVERFLOW, (((FA shr 6) xor (FA shr 5)) and 1) <> 0);
end;

procedure T65xxCPU.StoreHighAnd(const I: T65xxInstructionDescriptor; const AValue: Byte);
var
  Value: Byte;
  Address: Word;
begin
  // SHA / SHX / SHY / TAS: the value is ANDed with (high byte of the base address + 1);
  // when indexing crosses a page, that value also replaces the high byte of the address
  Value := AValue and Byte((I.BaseAddress shr 8) + 1);
  Address := I.Data;
  if ((I.BaseAddress xor Address) and $FF00) <> 0 then
    Address := (Value shl 8) or (Address and $FF);
  FMemory.WriteByte(Address, Value);
end;

procedure T65xxCPU.ExecuteInstruction(var I: T65xxInstructionDescriptor);
var
  M: Integer;
  C: Integer;
  Value: Byte;
  Mask: Byte;
begin
  C := Ord(SR_C);

  case I.Instruction of
    iBRK:
    begin
      FPC := Word((Integer(FPC) + 1) and $FFFF);
      Interrupt(VECTOR_IRQ, True);
    end;
    // =========================
    // LOAD / STORE (operand already resolved!)
    // =========================

    iLDA:
    begin
      FA := Byte(I.Data);
      SetNZ(FA);
    end;

    iLDX:
    begin
      FX := Byte(I.Data);
      SetNZ(FX);
    end;

    iLDY:
    begin
      FY := Byte(I.Data);
      SetNZ(FY);
    end;

    iSTA: FMemory.WriteByte(I.Data, FA);
    iSTX: FMemory.WriteByte(I.Data, FX);
    iSTY: FMemory.WriteByte(I.Data, FY);
    iSTZ: FMemory.WriteByte(I.Data, 0);

    // =========================
    // TRANSFERS
    // =========================

    iTAX:
    begin
      FX := FA;
      SetNZ(FX);
    end;

    iTXA:
    begin
      FA := FX;
      SetNZ(FA);
    end;

    iTAY:
    begin
      FY := FA;
      SetNZ(FY);
    end;

    iTYA:
    begin
      FA := FY;
      SetNZ(FA);
    end;

    iTSX:
    begin
      FX := FSP;
      SetNZ(FX);
    end;

    iTXS: FSP := FX;

    // =========================
    // STACK
    // =========================

    iPHA: PushByte(FA);
    iPHX: PushByte(FX);
    iPHY: PushByte(FY);
    iPHP: PushByte(FSR or $30);
    iPLA:
    begin
      FA := PopByte;
      SetNZ(FA);
    end;
    iPLX:
    begin
      FX := PopByte;
      SetNZ(FX);
    end;
    iPLY:
    begin
      FY := PopByte;
      SetNZ(FY);
    end;
    iPLP:
      FSR := (PopByte and $CF) or $20;

    // =========================
    // STACK CALLS
    // =========================

    iJSR:
    begin
      PushWord(Word(FPC - 1));
      FPC := I.Data;
    end;

    iRTS:
      FPC := Word(PopWord + 1);
    iRTI:
    begin
      FSR := (PopByte and $CF) or $20;
      FPC := PopWord;
    end;
    iJMP: FPC := I.Data;

    // =========================
    // BRANCH (I.Data = target PC from ResolveOperand)
    // =========================

    iBEQ: Branch(I, SR_Z);
    iBNE: Branch(I, not SR_Z);
    iBCC: Branch(I, not SR_C);
    iBCS: Branch(I, SR_C);
    iBMI: Branch(I, SR_N);
    iBPL: Branch(I, not SR_N);
    iBVS: Branch(I, SR_V);
    iBVC: Branch(I, not SR_V);
    iBRA: Branch(I, True);

    // =========================
    // BIT OPERATIONS (R65C02 / W65C02S)
    // =========================

    iRMB, iSMB:
    begin
      Mask := 1 shl ((I.OpCode shr 4) and 7);
      if I.Instruction = iRMB then
        Value := Byte(I.Data) and not Mask
      else
        Value := Byte(I.Data) or Mask;
      FMemory.WriteByte(I.EffectiveAddress, Value);
    end;
    iBBR, iBBS:
    begin
      Mask := 1 shl ((I.OpCode shr 4) and 7);
      Value := FMemory.ReadByte(I.EffectiveAddress);
      Branch(I, ((Value and Mask) <> 0) = (I.Instruction = iBBS));
    end;

    // =========================
    // LOGIC
    // =========================

    iAND:
    begin
      FA := FA and Byte(I.Data);
      SetNZ(FA);
    end;

    iORA:
    begin
      FA := FA or Byte(I.Data);
      SetNZ(FA);
    end;

    iEOR:
    begin
      FA := FA xor Byte(I.Data);
      SetNZ(FA);
    end;

    iBIT:
    begin
      M := Byte(I.Data);
      SetZeroFlag(FA and M);
      // BIT #imm (CMOS) only affects Z
      if I.AddressingMode <> mImm then
      begin
        SetFlag(STATUS_REGISTER_FLAG_NEGATIVE, (M and $80) <> 0);
        SetFlag(STATUS_REGISTER_FLAG_OVERFLOW, (M and $40) <> 0);
      end;
    end;

    iTSB, iTRB:
    begin
      M := Byte(I.Data);
      SetZeroFlag(FA and M);
      if I.Instruction = iTSB then
        Value := M or FA
      else
        Value := M and not FA;
      FMemory.WriteByte(I.EffectiveAddress, Value);
    end;

    // =========================
    // COMPARE
    // =========================

    iCMP: Compare(FA, Byte(I.Data));
    iCPX: Compare(FX, Byte(I.Data));
    iCPY: Compare(FY, Byte(I.Data));

    // =========================
    // SHIFTS
    // =========================

    iASL, iLSR, iROL, iROR:
    begin
      if I.AddressingMode = mAcc then
        Value := FA
      else
        Value := Byte(I.Data);

      case I.Instruction of
        iASL:
        begin
          SetCarryFlag((Value and $80) <> 0);
          Value := Byte(Value shl 1);
        end;
        iLSR:
        begin
          SetCarryFlag((Value and $01) <> 0);
          Value := Value shr 1;
        end;
        iROL:
        begin
          SetCarryFlag((Value and $80) <> 0);
          Value := Byte((Value shl 1) or C);
        end;
        iROR:
        begin
          SetCarryFlag((Value and $01) <> 0);
          Value := Byte((Value shr 1) or (C shl 7));
        end;
      end;

      if I.AddressingMode = mAcc then
        FA := Value
      else
        FMemory.WriteByte(I.EffectiveAddress, Value);
      SetNZ(Value);
    end;

    // =========================
    // ARITHMETIC
    // =========================

    iADC: ADC(I, Byte(I.Data));
    iSBC: SBC(I, Byte(I.Data));

    // =========================
    // FLAGS
    // =========================

    iCLC: SetFlag(STATUS_REGISTER_FLAG_CARRY, False);
    iSEC: SetFlag(STATUS_REGISTER_FLAG_CARRY, True);
    iCLD: SetFlag(STATUS_REGISTER_FLAG_DECIMAL, False);
    iSED: SetFlag(STATUS_REGISTER_FLAG_DECIMAL, True);
    iCLI: SetFlag(STATUS_REGISTER_FLAG_INTERRUPT, False);
    iSEI: SetFlag(STATUS_REGISTER_FLAG_INTERRUPT, True);
    iCLV: SetFlag(STATUS_REGISTER_FLAG_OVERFLOW, False);

    // =========================
    // INCREMENT / DECREMENT
    // =========================

    iDEY:
    begin
      FY := Byte(FY - 1);
      SetNZ(FY);
    end;
    iINY:
    begin
      FY := Byte(FY + 1);
      SetNZ(FY);
    end;
    iDEX:
    begin
      FX := Byte(FX - 1);
      SetNZ(FX);
    end;
    iINX:
    begin
      FX := Byte(FX + 1);
      SetNZ(FX);
    end;
    iDEC, iINC:
    begin
      if I.AddressingMode = mAcc then
        Value := FA
      else
        Value := Byte(I.Data);

      if I.Instruction = iINC then
        Value := Byte(Value + 1)
      else
        Value := Byte(Value - 1);

      if I.AddressingMode = mAcc then
        FA := Value
      else
        FMemory.WriteByte(I.EffectiveAddress, Value);
      SetNZ(Value);
    end;

    // =========================
    // CONTROL (W65C02S)
    // =========================

    iWAI: FState := csWaiting;
    iSTP: FState := csStopped;

    // =========================
    // NMOS UNDOCUMENTED (only reached when UseIllegalOpcodes = True)
    // =========================

    // read-modify-write combos
    iSLO, iRLA, iSRE, iRRA, iDCP, iISC:
    begin
      Value := Byte(I.Data);
      case I.Instruction of
        iSLO:
        begin
          SetCarryFlag((Value and $80) <> 0);
          Value := Byte(Value shl 1);
        end;
        iRLA:
        begin
          SetCarryFlag((Value and $80) <> 0);
          Value := Byte((Value shl 1) or C);
        end;
        iSRE:
        begin
          SetCarryFlag((Value and $01) <> 0);
          Value := Value shr 1;
        end;
        iRRA:
        begin
          SetCarryFlag((Value and $01) <> 0);
          Value := Byte((Value shr 1) or (C shl 7));
        end;
        iDCP: Value := Byte(Value - 1);
        iISC: Value := Byte(Value + 1);
      end;
      FMemory.WriteByte(I.EffectiveAddress, Value);

      case I.Instruction of
        iSLO:
        begin
          FA := FA or Value;
          SetNZ(FA);
        end;
        iRLA:
        begin
          FA := FA and Value;
          SetNZ(FA);
        end;
        iSRE:
        begin
          FA := FA xor Value;
          SetNZ(FA);
        end;
        iRRA: ADC(I, Value);
        iDCP: Compare(FA, Value);
        iISC: SBC(I, Value);
      end;
    end;

    iSAX: FMemory.WriteByte(I.Data, FA and FX);
    iLAX:
    begin
      FA := Byte(I.Data);
      FX := FA;
      SetNZ(FA);
    end;
    iANC:
    begin
      FA := FA and Byte(I.Data);
      SetNZ(FA);
      SetCarryFlag((FA and $80) <> 0);
    end;
    iALR:
    begin
      FA := FA and Byte(I.Data);
      SetCarryFlag((FA and $01) <> 0);
      FA := FA shr 1;
      SetNZ(FA);
    end;
    iARR: ARR(Byte(I.Data));
    iSBX:
    begin
      Value := FA and FX;
      SetCarryFlag(Value >= Byte(I.Data));
      FX := Byte(Value - Byte(I.Data));
      SetNZ(FX);
    end;
    iANE:
    begin
      FA := (FA or FIllegalMagic) and FX and Byte(I.Data);
      SetNZ(FA);
    end;
    iLXA:
    begin
      FA := (FA or FIllegalMagic) and Byte(I.Data);
      FX := FA;
      SetNZ(FA);
    end;
    iLAS:
    begin
      FA := Byte(I.Data) and FSP;
      FX := FA;
      FSP := FA;
      SetNZ(FA);
    end;
    iTAS:
    begin
      FSP := FA and FX;
      StoreHighAnd(I, FSP);
    end;
    iSHA: StoreHighAnd(I, FA and FX);
    iSHX: StoreHighAnd(I, FX);
    iSHY: StoreHighAnd(I, FY);
    iJAM: FState := csJammed;

    // =========================
    // NOP
    // =========================

    iNOP: ;

  else
    raise Exception.CreateFmt('Instruction not implemented: [%S] at [%.4X]', [I.InstructionName, self.PC]);
  end;
end;

procedure T65xxCPU.Branch(var I: T65xxInstructionDescriptor; const ACondition: Boolean);
begin
  if not ACondition then
    Exit;

  // +1 cycle for a taken branch, +1 more if the target is on another page
  Inc(I.AddedCycles);
  if ((FPC xor I.Data) and $FF00) <> 0 then
    Inc(I.AddedCycles);
  FPC := I.Data;
end;

function T65xxCPU.Step: Integer;
var
  OpCode: Byte;
  StartPC: Word;
  tmpInstr: T65xxInstructionDescriptor;
begin
  if FState <> csRunning then
    Exit(0);

  StartPC := PC;
  OpCode := self.ReadByte;
  tmpInstr := Instr(FVariant, OpCode);

  try
    if tmpInstr.Illegal and not FUseIllegalOpcodes then
      raise Exception.CreateFmt('Illegal instruction [%s] (UseIllegalOpcodes = False)', [tmpInstr.InstructionName]);
    self.ResolveOperand(@tmpInstr);
    self.ExecuteInstruction(tmpInstr);
  except
    on E: Exception do
      raise Exception.CreateFmt('%s (opcode $%.2X at $%.4X, %s)',
        [E.Message, OpCode, StartPC, VariantName(FVariant)]);
  end;

  Result := tmpInstr.Cycles + tmpInstr.AddedCycles;
  Inc(self.FCycles, Result);
end;

function T65xxCPU.IRQ: Integer;
begin
  Result := 0;
  if FState in [csStopped, csJammed] then
    Exit;

  // WAI resumes on IRQ even when interrupts are disabled (execution continues after WAI)
  if FState = csWaiting then
    FState := csRunning;

  if SR_I then
    Exit;

  Interrupt(VECTOR_IRQ, False);
  Result := INTERRUPT_CYCLES;
  Inc(FCycles, Result);
end;

function T65xxCPU.NMI: Integer;
begin
  Result := 0;
  if FState in [csStopped, csJammed] then
    Exit;

  FState := csRunning;
  Interrupt(VECTOR_NMI, False);
  Result := INTERRUPT_CYCLES;
  Inc(FCycles, Result);
end;

procedure T65xxCPU.Reset;
begin
  FSP := $FF;
  FA := 0;
  FX := 0;
  FY := 0;
  FSR := $24; // I set, bit 5 always on (D is also cleared, which is guaranteed on CMOS)
  FCycles := 0;
  FState := csRunning;

  if Assigned(FMemory) then
    FPC := ReadMemWord(VECTOR_RESET)
  else
    FPC := 0;
end;

function T65xxCPU.SR_N: Boolean;
begin
  Result := GetFlag(STATUS_REGISTER_FLAG_NEGATIVE);
end;

function T65xxCPU.SR_V: Boolean;
begin
  Result := GetFlag(STATUS_REGISTER_FLAG_OVERFLOW);
end;

function T65xxCPU.SR_B: Boolean;
begin
  Result := GetFlag(STATUS_REGISTER_FLAG_BREAK);
end;

function T65xxCPU.SR_D: Boolean;
begin
  Result := GetFlag(STATUS_REGISTER_FLAG_DECIMAL);
end;

function T65xxCPU.SR_I: Boolean;
begin
  Result := GetFlag(STATUS_REGISTER_FLAG_INTERRUPT);
end;

function T65xxCPU.SR_Z: Boolean;
begin
  Result := GetFlag(STATUS_REGISTER_FLAG_ZERO);
end;

function T65xxCPU.SR_C: Boolean;
begin
  Result := GetFlag(STATUS_REGISTER_FLAG_CARRY);
end;

constructor T65xxCPU.Create(AMemory: TCPUMemory; const AVariant: TCPU65xxVariant = cv6502);
begin
  inherited Create;
  FMemory := AMemory;
  FVariant := AVariant;
  FUseIllegalOpcodes := False;
  FIllegalMagic := DEFAULT_ILLEGAL_MAGIC;
  Self.Reset;
end;

destructor T65xxCPU.Destroy;
begin
  inherited Destroy;
end;

end.
