unit CPU65xxOpcodes;

{
  Opcode tables for the 8-bit 65xx family.

  Supported variants:
    cv6502    - MOS/NMOS 6502 (also 6507, 6510, 8500, 8502 - same core,
                the differences are in the bus / on-chip I/O port, not in the ISA)
    cv2A03    - Ricoh 2A03/2A07 (NES) - NMOS core without BCD arithmetic
    cv65SC02  - CMOS 65SC02 - 65C02 without bit instructions
    cvR65C02  - Rockwell R65C02 - 65SC02 + RMB/SMB/BBR/BBS
    cvW65C02  - WDC W65C02S - R65C02 + WAI/STP

  NMOS undocumented ("illegal") opcodes are described in the tables with
  Illegal = True; whether the CPU executes them is decided by
  T65xxCPU.UseIllegalOpcodes. On CMOS parts every unused opcode is a
  documented NOP with a defined length and cycle count.

  Copyright (c) 2026 McManiek
  License: MIT (see LICENSE)
}

interface

uses
  System.SysUtils;

type
  TCPU65xxVariant = (cv6502, cv2A03, cv65SC02, cvR65C02, cvW65C02);

  T65xxInstr = (
    iNull, //shouldnt happened - if occured means something is f*cked up!
    // NMOS 6502 instruction set
    iBRK, iORA, iASL, iPHP, iBPL, iCLC, iJSR, iBIT,
    iAND, iROL, iPLP, iBMI, iSEC, iLSR, iRTI, iEOR,
    iPHA, iJMP, iBVC, iCLI, iRTS, iROR, iADC, iPLA,
    iBVS, iSEI, iSTA, iSTY, iSTX, iDEY, iTXA, iBCC,
    iTYA, iTXS, iLDY, iLDA, iLDX, iTAY, iTAX, iBCS,
    iCLV, iTSX, iCPY, iCMP, iDEC, iINY, iDEX, iBNE,
    iCLD, iCPX, iINC, iSBC, iNOP, iINX, iBEQ, iSED,
    // CMOS 65SC02 / 65C02 additions
    iBRA, iPHX, iPHY, iPLX, iPLY, iSTZ, iTRB, iTSB,
    // Rockwell / WDC bit instructions (bit number = opcode bits 4..6)
    iRMB, iSMB, iBBR, iBBS,
    // WDC only
    iWAI, iSTP,
    // NMOS undocumented (illegal) instructions
    iSLO, iRLA, iSRE, iRRA, iSAX, iLAX, iDCP, iISC,
    iANC, iALR, iARR, iSBX, iANE, iLXA, iLAS, iTAS,
    iSHA, iSHX, iSHY, iJAM
  );

  T65xxInstructionStr = Array[T65xxInstr] of String;

  T65xxInstrAddrMode = (
    mNull, //shouldnt happened - if occured means something is f*cked up!
    mImp, mInX, mZpg, mImm, mAbs, mAcc, mRel,
    mInY, mZpX, mAbY, mAbX, mInd, mZpY,
    // CMOS additions
    mZpI,   // (zp)
    mAbXI,  // (abs, X) - JMP only
    mZpRel  // zp, rel  - BBR/BBS only
  );

  T65xxInstrAddrModeDescription = Array[T65xxInstrAddrMode] of String;

  P65xxInstrDescriptor = ^T65xxInstructionDescriptor;
  T65xxInstructionDescriptor = record
    OpCode: Byte;
    Instruction: T65xxInstr;
    InstructionName: String;
    InstructionDesc: String;
    AddressingMode: T65xxInstrAddrMode;
    AddressingModeDesc: String;
    Cycles: Byte;
    ExtraCycles: Byte;
    AddedCycles: Byte; // extra cycles actually spent (page cross / taken branch / CMOS decimal)
    Illegal: Boolean;  // NMOS undocumented opcode
    Data: Word;
    EffectiveAddress: Word;
    BaseAddress: Word; // address before indexing (indexed modes), otherwise = EffectiveAddress
  end;

  function Instr(const AVariant: TCPU65xxVariant; const AOpCode: Byte): T65xxInstructionDescriptor;

  function VariantName(const AVariant: TCPU65xxVariant): String;
  function IsCMOS(const AVariant: TCPU65xxVariant): Boolean;
  function HasDecimalMode(const AVariant: TCPU65xxVariant): Boolean;
  function HasBitInstructions(const AVariant: TCPU65xxVariant): Boolean;
  function HasWaiStp(const AVariant: TCPU65xxVariant): Boolean;

implementation

type
  TOpcodeInfo = record
    Instruction: T65xxInstr;
    AddressingMode: T65xxInstrAddrMode;
    Cycles: Byte;
    ExtraCycles: Byte;
    Illegal: Boolean;
  end;
  TOpcodeTable = Array[Byte] of TOpcodeInfo;

var
  OpcodeTables: Array[TCPU65xxVariant] of TOpcodeTable;

  {$REGION 'NMOS instruction table'}
  const NMOSInstructions: Array[Byte] of T65xxInstr = (
    iBRK, iORA, iNull, iNull, iNull, iORA, iASL, iNull,   // 00
    iPHP, iORA, iASL, iNull, iNull, iORA, iASL, iNull,    // 08
    iBPL, iORA, iNull, iNull, iNull, iORA, iASL, iNull,   // 10
    iCLC, iORA, iNull, iNull, iNull, iORA, iASL, iNull,   // 18
    iJSR, iAND, iNull, iNull, iBIT, iAND, iROL, iNull,    // 20
    iPLP, iAND, iROL, iNull, iBIT, iAND, iROL, iNull,     // 28
    iBMI, iAND, iNull, iNull, iNull, iAND, iROL, iNull,   // 30
    iSEC, iAND, iNull, iNull, iNull, iAND, iROL, iNull,   // 38
    iRTI, iEOR, iNull, iNull, iNull, iEOR, iLSR, iNull,   // 40
    iPHA, iEOR, iLSR, iNull, iJMP, iEOR, iLSR, iNull,     // 48
    iBVC, iEOR, iNull, iNull, iNull, iEOR, iLSR, iNull,   // 50
    iCLI, iEOR, iNull, iNull, iNull, iEOR, iLSR, iNull,   // 58
    iRTS, iADC, iNull, iNull, iNull, iADC, iROR, iNull,   // 60
    iPLA, iADC, iROR, iNull, iJMP, iADC, iROR, iNull,     // 68
    iBVS, iADC, iNull, iNull, iNull, iADC, iROR, iNull,   // 70
    iSEI, iADC, iNull, iNull, iNull, iADC, iROR, iNull,   // 78
    iNull, iSTA, iNull, iNull, iSTY, iSTA, iSTX, iNull,   // 80
    iDEY, iNull, iTXA, iNull, iSTY, iSTA, iSTX, iNull,    // 88
    iBCC, iSTA, iNull, iNull, iSTY, iSTA, iSTX, iNull,    // 90
    iTYA, iSTA, iTXS, iNull, iNull, iSTA, iNull, iNull,   // 98
    iLDY, iLDA, iLDX, iNull, iLDY, iLDA, iLDX, iNull,     // A0
    iTAY, iLDA, iTAX, iNull, iLDY, iLDA, iLDX, iNull,     // A8
    iBCS, iLDA, iNull, iNull, iLDY, iLDA, iLDX, iNull,    // B0
    iCLV, iLDA, iTSX, iNull, iLDY, iLDA, iLDX, iNull,     // B8
    iCPY, iCMP, iNull, iNull, iCPY, iCMP, iDEC, iNull,    // C0
    iINY, iCMP, iDEX, iNull, iCPY, iCMP, iDEC, iNull,     // C8
    iBNE, iCMP, iNull, iNull, iNull, iCMP, iDEC, iNull,   // D0
    iCLD, iCMP, iNull, iNull, iNull, iCMP, iDEC, iNull,   // D8
    iCPX, iSBC, iNull, iNull, iCPX, iSBC, iINC, iNull,    // E0
    iINX, iSBC, iNOP, iNull, iCPX, iSBC, iINC, iNull,     // E8
    iBEQ, iSBC, iNull, iNull, iNull, iSBC, iINC, iNull,   // F0
    iSED, iSBC, iNull, iNull, iNull, iSBC, iINC, iNull    // F8
  );
  {$ENDREGION}

  {$REGION 'NMOS instruction addressing modes'}
  const NMOSInstrAddressingModes: Array[Byte] of T65xxInstrAddrMode = (
    mImp, mInX, mNull, mInX, mZpg, mZpg, mZpg, mZpg,  // 00
    mImp, mImm, mAcc, mImm, mAbs, mAbs, mAbs, mAbs,   // 08
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpX, mZpX,  // 10
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbX, mAbX,   // 18
    mAbs, mInX, mNull, mInX, mZpg, mZpg, mZpg, mZpg,  // 20
    mImp, mImm, mAcc, mImm, mAbs, mAbs, mAbs, mAbs,   // 28
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpX, mZpX,  // 30
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbX, mAbX,   // 38
    mImp, mInX, mNull, mInX, mZpg, mZpg, mZpg, mZpg,  // 40
    mImp, mImm, mAcc, mImm, mAbs, mAbs, mAbs, mAbs,   // 48
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpX, mZpX,  // 50
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbX, mAbX,   // 58
    mImp, mInX, mNull, mInX, mZpg, mZpg, mZpg, mZpg,  // 60
    mImp, mImm, mAcc, mImm, mInd, mAbs, mAbs, mAbs,   // 68
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpX, mZpX,  // 70
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbX, mAbX,   // 78
    mImm, mInX, mImm, mInX, mZpg, mZpg, mZpg, mZpg,   // 80
    mImp, mImm, mImp, mImm, mAbs, mAbs, mAbs, mAbs,   // 88
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpY, mZpY,  // 90
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbY, mAbY,   // 98
    mImm, mInX, mImm, mInX, mZpg, mZpg, mZpg, mZpg,   // A0
    mImp, mImm, mImp, mImm, mAbs, mAbs, mAbs, mAbs,   // A8
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpY, mZpY,  // B0
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbY, mAbY,   // B8
    mImm, mInX, mImm, mInX, mZpg, mZpg, mZpg, mZpg,   // C0
    mImp, mImm, mImp, mImm, mAbs, mAbs, mAbs, mAbs,   // C8
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpX, mZpX,  // D0
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbX, mAbX,   // D8
    mImm, mInX, mImm, mInX, mZpg, mZpg, mZpg, mZpg,   // E0
    mImp, mImm, mImp, mImm, mAbs, mAbs, mAbs, mAbs,   // E8
    mRel, mInY, mNull, mInY, mZpX, mZpX, mZpX, mZpX,  // F0
    mImp, mAbY, mImp, mAbY, mAbX, mAbX, mAbX, mAbX    // F8
  );
  {$ENDREGION}

  {$REGION 'NMOS instruction cycles'}
  const NMOSInstructionCycles : Array[Byte] of Byte = (
    7, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 4, 4, 6, 6,  // 00
    2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,  // 10
    6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 4, 4, 6, 6,  // 20
    2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,  // 30
    6, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 3, 4, 6, 6,  // 40
    2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,  // 50
    6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 5, 4, 6, 6,  // 60
    2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,  // 70
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,  // 80
    2, 6, 0, 6, 4, 4, 4, 4, 2, 5, 2, 5, 5, 5, 5, 5,  // 90
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,  // A0
    2, 5, 0, 5, 4, 4, 4, 4, 2, 4, 2, 4, 4, 4, 4, 4,  // B0
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,  // C0
    2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,  // D0
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,  // E0
    2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7   // F0
  );
  {$ENDREGION}

  {$REGION 'NMOS instruction extra cycles'}
  const NMOSExtraCycles : Array[Byte] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 00
    2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0,  // 10
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 20
    2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0,  // 30
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 40
    2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0,  // 50
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 60
    2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0,  // 70
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 80
    2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 90
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // A0
    2, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1,  // B0
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // C0
    2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0,  // D0
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // E0
    2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0   // F0
  );
  {$ENDREGION}

  {$REGION 'instruction names'}
  const CPU65xxInstructionNames: T65xxInstructionStr = (
    'NULL', // iNull
    'BRK', 'ORA', 'ASL', 'PHP', 'BPL', 'CLC', 'JSR', 'BIT',
    'AND', 'ROL', 'PLP', 'BMI', 'SEC', 'LSR', 'RTI', 'EOR',
    'PHA', 'JMP', 'BVC', 'CLI', 'RTS', 'ROR', 'ADC', 'PLA',
    'BVS', 'SEI', 'STA', 'STY', 'STX', 'DEY', 'TXA', 'BCC',
    'TYA', 'TXS', 'LDY', 'LDA', 'LDX', 'TAY', 'TAX', 'BCS',
    'CLV', 'TSX', 'CPY', 'CMP', 'DEC', 'INY', 'DEX', 'BNE',
    'CLD', 'CPX', 'INC', 'SBC', 'NOP', 'INX', 'BEQ', 'SED',
    'BRA', 'PHX', 'PHY', 'PLX', 'PLY', 'STZ', 'TRB', 'TSB',
    'RMB', 'SMB', 'BBR', 'BBS',
    'WAI', 'STP',
    'SLO', 'RLA', 'SRE', 'RRA', 'SAX', 'LAX', 'DCP', 'ISC',
    'ANC', 'ALR', 'ARR', 'SBX', 'ANE', 'LXA', 'LAS', 'TAS',
    'SHA', 'SHX', 'SHY', 'JAM'
  );
  {$ENDREGION}

  {$REGION 'instruction descriptions'}
  const CPU65xxInstructionDescriptions: T65xxInstructionStr = (
    'NULL', // iNull
    'break / interrupt',  // iBRK
    'or with accumulator',  // iORA
    'arithmetic shift left',  // iASL
    'push processor status (SR)',  // iPHP
    'branch on plus (negative clear)',  // iBPL
    'clear carry',  // iCLC
    'jump subroutine',  // iJSR
    'bit test',  // iBIT
    'and (with accumulator)',  // iAND
    'rotate left',  // iROL
    'pull processor status (SR)',  // iPLP
    'branch on minus (negative set)',  // iBMI
    'set carry',  // iSEC
    'logical shift right',  // iLSR
    'return from interrupt',  // iRTI
    'exclusive or (with accumulator)',  // iEOR
    'push accumulator',  // iPHA
    'jump',  // iJMP
    'branch on overflow clear',  // iBVC
    'clear interrupt',  // iCLI
    'return from subroutine',  // iRTS
    'rotate right',  // iROR
    'add with carry',  // iADC
    'pull accumulator',  // iPLA
    'branch on overflow set',  // iBVS
    'set interrupt',  // iSEI
    'store accumulator',  // iSTA
    'store Y',  // iSTY
    'store X',  // iSTX
    'decrement Y',  // iDEY
    'transfer X to accumulator',  // iTXA
    'branch on carry clear',  // iBCC
    'transfer Y to accumulator',  // iTYA
    'transfer X to stack pointer',  // iTXS
    'load Y',  // iLDY
    'load accumulator',  // iLDA
    'load X',  // iLDX
    'transfer accumulator to Y',  // iTAY
    'transfer accumulator to X',  // iTAX
    'branch on carry set',  // iBCS
    'clear overflow',  // iCLV
    'transfer stack pointer to X',  // iTSX
    'compare with Y',  // iCPY
    'compare (with accumulator)',  // iCMP
    'decrement',  // iDEC
    'increment Y',  // iINY
    'decrement X',  // iDEX
    'branch on not equal (zero clear)',  // iBNE
    'clear decimal',  // iCLD
    'compare with X',  // iCPX
    'increment',  // iINC
    'subtract with carry',  // iSBC
    'no operation',  // iNOP
    'increment X',  // iINX
    'branch on equal (zero set)',  // iBEQ
    'set decimal',  // iSED
    'branch always',  // iBRA
    'push X',  // iPHX
    'push Y',  // iPHY
    'pull X',  // iPLX
    'pull Y',  // iPLY
    'store zero',  // iSTZ
    'test and reset bits',  // iTRB
    'test and set bits',  // iTSB
    'reset memory bit',  // iRMB
    'set memory bit',  // iSMB
    'branch on bit reset',  // iBBR
    'branch on bit set',  // iBBS
    'wait for interrupt',  // iWAI
    'stop the processor',  // iSTP
    'shift left, then or with accumulator',  // iSLO
    'rotate left, then and with accumulator',  // iRLA
    'shift right, then exclusive or with accumulator',  // iSRE
    'rotate right, then add with carry',  // iRRA
    'store accumulator and X',  // iSAX
    'load accumulator and X',  // iLAX
    'decrement, then compare with accumulator',  // iDCP
    'increment, then subtract with carry',  // iISC
    'and with accumulator, carry = bit 7',  // iANC
    'and with accumulator, then shift right',  // iALR
    'and with accumulator, then rotate right',  // iARR
    'X = (accumulator and X) - operand',  // iSBX
    'accumulator = (accumulator or magic) and X and operand (unstable)',  // iANE
    'accumulator and X = (accumulator or magic) and operand (unstable)',  // iLXA
    'accumulator, X and stack pointer = memory and stack pointer',  // iLAS
    'stack pointer = accumulator and X, store SP and (high address + 1)',  // iTAS
    'store accumulator and X and (high address + 1)',  // iSHA
    'store X and (high address + 1)',  // iSHX
    'store Y and (high address + 1)',  // iSHY
    'jam / halt the processor'   // iJAM
  );
  {$ENDREGION}

  {$REGION 'instruction addressing mode descriptions'}
  const CPU65xxInstrAddrModeDescriptions: T65xxInstrAddrModeDescription = (
    'NULL',
    'implied [%s]',
    'X-indexed, indirect [%s ($LL, X)]',
    'zeropage [%s $LL]',
    'immediate [%s #$BB]',
    'absolute [%s $LLHH]',
    'accumulator [%s A]',
    'relative [%s $BB]',
    'indirect, Y-indexed [%s ($LL), Y]',
    'zeropage, X-indexed [%s $LL, X]',
    'absolute, Y-indexed [%s $LLHH, Y]',
    'absolute, X-indexed [%s $LLHH, X]',
    'indirect [%s ($LLHH)]',
    'zeropage, Y-indexed [%s $LL, Y]',
    'zeropage, indirect [%s ($LL)]',
    'absolute, X-indexed, indirect [%s ($LLHH, X)]',
    'zeropage, relative [%s $LL, $BB]'
  );
  {$ENDREGION}

function VariantName(const AVariant: TCPU65xxVariant): String;
begin
  case AVariant of
    cv6502:   Result := 'NMOS 6502';
    cv2A03:   Result := 'Ricoh 2A03';
    cv65SC02: Result := '65SC02';
    cvR65C02: Result := 'Rockwell R65C02';
    cvW65C02: Result := 'WDC W65C02S';
  else
    Result := '?';
  end;
end;

function IsCMOS(const AVariant: TCPU65xxVariant): Boolean;
begin
  Result := AVariant in [cv65SC02, cvR65C02, cvW65C02];
end;

function HasDecimalMode(const AVariant: TCPU65xxVariant): Boolean;
begin
  Result := AVariant <> cv2A03;
end;

function HasBitInstructions(const AVariant: TCPU65xxVariant): Boolean;
begin
  Result := AVariant in [cvR65C02, cvW65C02];
end;

function HasWaiStp(const AVariant: TCPU65xxVariant): Boolean;
begin
  Result := AVariant = cvW65C02;
end;

procedure SetOp(var T: TOpcodeTable; const AOpCode: Byte; const AInstr: T65xxInstr;
  const AMode: T65xxInstrAddrMode; const ACycles: Byte; const AExtra: Byte = 0);
begin
  T[AOpCode].Instruction := AInstr;
  T[AOpCode].AddressingMode := AMode;
  T[AOpCode].Cycles := ACycles;
  T[AOpCode].ExtraCycles := AExtra;
  T[AOpCode].Illegal := False;
end;

procedure SetIllegal(var T: TOpcodeTable; const AOpCodes: array of Byte; const AInstr: T65xxInstr);
var
  Op: Byte;
begin
  // addressing mode and timing come from the NMOS tables
  for Op in AOpCodes do
  begin
    T[Op].Instruction := AInstr;
    T[Op].Illegal := True;
  end;
end;

procedure BuildNMOSTable(var T: TOpcodeTable);
var
  Op: Byte;
begin
  for Op := Low(Byte) to High(Byte) do
    SetOp(T, Op, NMOSInstructions[Op], NMOSInstrAddressingModes[Op],
      NMOSInstructionCycles[Op], NMOSExtraCycles[Op]);

  // undocumented opcodes
  SetIllegal(T, [$03, $07, $0F, $13, $17, $1B, $1F], iSLO);
  SetIllegal(T, [$23, $27, $2F, $33, $37, $3B, $3F], iRLA);
  SetIllegal(T, [$43, $47, $4F, $53, $57, $5B, $5F], iSRE);
  SetIllegal(T, [$63, $67, $6F, $73, $77, $7B, $7F], iRRA);
  SetIllegal(T, [$83, $87, $8F, $97], iSAX);
  SetIllegal(T, [$A3, $A7, $AF, $B3, $B7, $BF], iLAX);
  SetIllegal(T, [$C3, $C7, $CF, $D3, $D7, $DB, $DF], iDCP);
  SetIllegal(T, [$E3, $E7, $EF, $F3, $F7, $FB, $FF], iISC);
  SetIllegal(T, [$0B, $2B], iANC);
  SetIllegal(T, [$4B], iALR);
  SetIllegal(T, [$6B], iARR);
  SetIllegal(T, [$8B], iANE);
  SetIllegal(T, [$AB], iLXA);
  SetIllegal(T, [$CB], iSBX);
  SetIllegal(T, [$EB], iSBC);
  SetIllegal(T, [$BB], iLAS);
  SetIllegal(T, [$9B], iTAS);
  SetIllegal(T, [$93, $9F], iSHA);
  SetIllegal(T, [$9E], iSHX);
  SetIllegal(T, [$9C], iSHY);
  SetIllegal(T, [$1A, $3A, $5A, $7A, $DA, $FA,              // implied
                 $80, $82, $89, $C2, $E2,                   // immediate
                 $04, $44, $64, $14, $34, $54, $74, $D4, $F4, // zp / zp,X
                 $0C, $1C, $3C, $5C, $7C, $DC, $FC], iNOP); // abs / abs,X
  SetIllegal(T, [$02, $12, $22, $32, $42, $52, $62, $72, $92, $B2, $D2, $F2], iJAM);
  for Op in [$02, $12, $22, $32, $42, $52, $62, $72, $92, $B2, $D2, $F2] do
    T[Op].AddressingMode := mImp;
end;

procedure BuildCMOSTable(var T: TOpcodeTable; const AVariant: TCPU65xxVariant);
var
  Op: Byte;
  Bit: Byte;
begin
  BuildNMOSTable(T);

  // every NMOS-undocumented opcode becomes a 1-byte, 1-cycle NOP by default;
  // the ones with a different length / timing are overridden below
  for Op := Low(Byte) to High(Byte) do
    if T[Op].Illegal then
      SetOp(T, Op, iNOP, mImp, 1);

  // multi-byte NOPs
  for Op in [$02, $22, $42, $62, $82, $C2, $E2] do
    SetOp(T, Op, iNOP, mImm, 2);
  SetOp(T, $44, iNOP, mZpg, 3);
  for Op in [$54, $D4, $F4] do
    SetOp(T, Op, iNOP, mZpX, 4);
  SetOp(T, $5C, iNOP, mAbs, 8);
  SetOp(T, $DC, iNOP, mAbs, 4);
  SetOp(T, $FC, iNOP, mAbs, 4);

  // (zp) addressing mode
  SetOp(T, $12, iORA, mZpI, 5);
  SetOp(T, $32, iAND, mZpI, 5);
  SetOp(T, $52, iEOR, mZpI, 5);
  SetOp(T, $72, iADC, mZpI, 5);
  SetOp(T, $92, iSTA, mZpI, 5);
  SetOp(T, $B2, iLDA, mZpI, 5);
  SetOp(T, $D2, iCMP, mZpI, 5);
  SetOp(T, $F2, iSBC, mZpI, 5);

  // new addressing modes for existing instructions
  SetOp(T, $89, iBIT, mImm, 2);
  SetOp(T, $34, iBIT, mZpX, 4);
  SetOp(T, $3C, iBIT, mAbX, 4, 1);
  SetOp(T, $1A, iINC, mAcc, 2);
  SetOp(T, $3A, iDEC, mAcc, 2);
  SetOp(T, $7C, iJMP, mAbXI, 6);
  SetOp(T, $6C, iJMP, mInd, 6); // page wrap bug fixed, one cycle longer

  // read-modify-write abs,X shifts: 6 cycles + 1 on page cross (INC/DEC stay 7)
  for Op in [$1E, $3E, $5E, $7E] do
  begin
    T[Op].Cycles := 6;
    T[Op].ExtraCycles := 1;
  end;

  // new instructions
  SetOp(T, $80, iBRA, mRel, 2, 2);
  SetOp(T, $DA, iPHX, mImp, 3);
  SetOp(T, $5A, iPHY, mImp, 3);
  SetOp(T, $FA, iPLX, mImp, 4);
  SetOp(T, $7A, iPLY, mImp, 4);
  SetOp(T, $64, iSTZ, mZpg, 3);
  SetOp(T, $74, iSTZ, mZpX, 4);
  SetOp(T, $9C, iSTZ, mAbs, 4);
  SetOp(T, $9E, iSTZ, mAbX, 5);
  SetOp(T, $04, iTSB, mZpg, 5);
  SetOp(T, $0C, iTSB, mAbs, 6);
  SetOp(T, $14, iTRB, mZpg, 5);
  SetOp(T, $1C, iTRB, mAbs, 6);

  if HasBitInstructions(AVariant) then
    for Bit := 0 to 7 do
    begin
      SetOp(T, $07 + Bit shl 4, iRMB, mZpg, 5);
      SetOp(T, $87 + Bit shl 4, iSMB, mZpg, 5);
      SetOp(T, $0F + Bit shl 4, iBBR, mZpRel, 5, 2);
      SetOp(T, $8F + Bit shl 4, iBBS, mZpRel, 5, 2);
    end;

  if HasWaiStp(AVariant) then
  begin
    SetOp(T, $CB, iWAI, mImp, 3);
    SetOp(T, $DB, iSTP, mImp, 3);
  end;
end;

procedure BuildOpcodeTables;
var
  V: TCPU65xxVariant;
begin
  for V := Low(TCPU65xxVariant) to High(TCPU65xxVariant) do
    if IsCMOS(V) then
      BuildCMOSTable(OpcodeTables[V], V)
    else
      BuildNMOSTable(OpcodeTables[V]);
end;

function Instr(const AVariant: TCPU65xxVariant; const AOpCode: Byte): T65xxInstructionDescriptor;
var
  Info: TOpcodeInfo;
begin
  Info := OpcodeTables[AVariant][AOpCode];
  with Result do
  begin
    OpCode := AOpCode;
    Instruction := Info.Instruction;
    InstructionName := CPU65xxInstructionNames[Instruction];
    if Instruction in [iRMB, iSMB, iBBR, iBBS] then
      InstructionName := InstructionName + IntToStr((AOpCode shr 4) and 7);
    InstructionDesc := CPU65xxInstructionDescriptions[Instruction];
    AddressingMode := Info.AddressingMode;
    AddressingModeDesc := Format(CPU65xxInstrAddrModeDescriptions[AddressingMode], [InstructionName]);
    Cycles := Info.Cycles;
    ExtraCycles := Info.ExtraCycles;
    AddedCycles := 0;
    Illegal := Info.Illegal;
    Data := 0;
    EffectiveAddress := 0;
    BaseAddress := 0;
  end;
end;

initialization
  BuildOpcodeTables;

end.
