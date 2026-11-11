unit CPUMemory;

{
  Memory for the 65xx CPU core (flat 64 KB byte array).
  Override ReadByte / WriteByte to map I/O, ROM, banking...

  Copyright (c) 2026 McManiek
  License: MIT (see LICENSE)
}

interface
uses
  System.SysUtils, System.Math, Winapi.Windows, System.Classes, System.IOUtils;

type
  TCPUMemory = class
  private
    FMemorySize: Integer;
    FPatternFill: Byte;
    FMemory: TBytes;
    function Get_ByteAtAddress(const AAddr: Word): Byte;
  public
    property PatternFill: Byte read FPatternFill;
    property MemorySize: Integer read FMemorySize;
    property ByteAtAddress[const AAddr: Word]: Byte read Get_ByteAtAddress; default;

    procedure Reset;

    // the CPU accesses memory only through these two methods - override them
    // in a descendant to map I/O devices, ROM, banking, mirroring...
    function ReadByte(const AAddr: Word): Byte; virtual;
    procedure WriteByte(const Addr: Word; const AByte: Byte); virtual;
    function ReadWord(const AAddr: Word): Word;
    procedure WriteWord(const Addr: Word; const AWord: Word);

    // copies AData straight into memory at AAddress, bypassing ReadByte / WriteByte
    // overrides (e.g. to load ROM images); data past the end of memory is ignored
    procedure LoadBytes(const AData: TBytes; const AAddress: Integer);
    function LoadFromFile(const AFileName: String): Boolean;
    function SaveToFile(const AFileName: String): Boolean;
    constructor Create(const ASize: Integer; APatternFill: Byte);
    destructor Destroy; override;
  end;

implementation

function TCPUMemory.ReadByte(const AAddr: Word): Byte;
begin
  Result := Byte(FMemory[AAddr]);
end;
procedure TCPUMemory.WriteByte(const Addr: Word; const AByte: Byte);
begin
  CopyMemory(@FMemory[Addr], @AByte, SizeOf(AByte));
end;

function TCPUMemory.ReadWord(const AAddr: Word): Word;
begin
  Result := FMemory[AAddr] or (FMemory[(AAddr + 1) and $FFFF] shl 8);
end;

procedure TCPUMemory.WriteWord(const Addr: Word; const AWord: Word);
begin
  CopyMemory(@FMemory[Addr], @AWord, SizeOf(AWord));
end;

procedure TCPUMemory.Reset;
begin
  FillChar(self.FMemory[0], Self.FMemorySize, self.FPatternFill);
end;

function TCPUMemory.Get_ByteAtAddress(const AAddr: Word): Byte;
begin
  Result := FMemory[AAddr];
end;

function TCPUMemory.SaveToFile(const AFileName: String): Boolean;
var
  MemStream: TMemoryStream;
begin
  MemStream := TMemoryStream.Create;
  try
    MemStream.Write(FMemory[0], self.FMemorySize);
    MemStream.SaveToFile(AFileName);
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
    end;
  end;
  FreeAndNil(MemStream);
end;

procedure TCPUMemory.LoadBytes(const AData: TBytes; const AAddress: Integer);
var
  Count: Integer;
begin
  Count := Min(Length(AData), FMemorySize - AAddress);
  if (AAddress < 0) or (Count <= 0) then
    Exit;
  Move(AData[0], FMemory[AAddress], Count);
end;

function TCPUMemory.LoadFromFile(const AFileName: String): Boolean;
var
  MemStream: TMemoryStream;
  ptrMemSize: Integer;
begin
  Result := False;
  if not TFile.Exists(AFileName) then
    Exit;

  MemStream := TMemoryStream.Create;
  try
    self.Reset;

    MemStream.LoadFromFile(AFileName);
    ptrMemSize := Min(Self.MemorySize, MemStream.Size);

    CopyMemory(@FMemory[0], MemStream.Memory, ptrMemSize);
    Result := True;
  finally
    FreeAndNil(MemStream);
  end;
end;

constructor TCPUMemory.Create(const ASize: Integer; APatternFill: Byte);
begin
  inherited Create;
  FMemorySize := ASize;
  FPatternFill := APatternFill;
  SetLength(FMemory, FMemorySize);
  Reset;
end;
destructor TCPUMemory.Destroy;
begin
  ZeroMemory(@FMemory[0], FMemorySize);
  SetLength(FMemory, 0);
  inherited Destroy;
end;
end.
