unit AppLog;

{ Strukturiertes Logging (eine JSON-Zeile pro Eintrag, CLEF-Format) fuer den
  Task-Service. Jeder Eintrag enthaelt Zeitstempel (UTC), Level, Service-Name
  und - falls vorhanden - die Korrelations-ID des Requests. Dasselbe Format
  schreibt auch der History-Service, damit die Logs beider Services
  zusammen durchsucht werden koennen.

  Ausgabe:
    - immer auf stdout
    - zusaetzlich an Seq (zentrale Log-Aggregation), wenn SEQ_URL gesetzt ist.
      Das Senden laeuft in einem Hintergrund-Thread (gebuendelt, max. 1x pro
      Sekunde) - ein langsames oder ausgefallenes Seq bremst nie einen Request. }

interface

uses
  System.SysUtils,
  System.JSON;

type
  TLogLevel = (llDebug, llInfo, llWarning, llError);

function EnvOrDefault(const AName, ADefault: string): string;
function NowUtc: TDateTime;

{ AProps (optional) wird uebernommen und freigegeben. }
procedure Log(ALevel: TLogLevel; const AMessage: string; const ACorrelationId: string = '';
  AProps: TJSONObject = nil);

procedure StartLogShipping;
procedure StopLogShipping;

implementation

uses
  System.Classes,
  System.DateUtils,
  System.SyncObjs,
  System.Generics.Collections,
  IdHTTP;

const
  ServiceName = 'task-service-delphi';

type
  TSeqShipper = class(TThread)
  private
    FUrl: string;
    FQueue: TThreadedQueue<string>;
  protected
    procedure Execute; override;
  public
    constructor Create(const AUrl: string);
    destructor Destroy; override;
    procedure Enqueue(const ALine: string);
  end;

var
  ConsoleLock: TCriticalSection;
  Shipper: TSeqShipper;

function EnvOrDefault(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function NowUtc: TDateTime;
begin
  Result := TTimeZone.Local.ToUniversalTime(Now);
end;

function LevelToClef(ALevel: TLogLevel): string;
begin
  case ALevel of
    llDebug: Result := 'Debug';
    llWarning: Result := 'Warning';
    llError: Result := 'Error';
  else
    Result := 'Information';
  end;
end;

procedure Log(ALevel: TLogLevel; const AMessage: string; const ACorrelationId: string;
  AProps: TJSONObject);
var
  Entry: TJSONObject;
  Pair: TJSONPair;
  Line: string;
begin
  Entry := TJSONObject.Create;
  try
    Entry.AddPair('@t', DateToISO8601(NowUtc, True));
    Entry.AddPair('@l', LevelToClef(ALevel));
    Entry.AddPair('@m', AMessage);
    Entry.AddPair('service', ServiceName);
    if ACorrelationId <> '' then
      Entry.AddPair('correlationId', ACorrelationId);
    if AProps <> nil then
      for Pair in AProps do
        Entry.AddPair(Pair.JsonString.Value, Pair.JsonValue.Clone as TJSONValue);
    Line := Entry.ToJSON;
  finally
    Entry.Free;
    AProps.Free;
  end;

  ConsoleLock.Enter;
  try
    Writeln(Line);
  finally
    ConsoleLock.Leave;
  end;

  if Shipper <> nil then
    Shipper.Enqueue(Line);
end;

{ TSeqShipper }

constructor TSeqShipper.Create(const AUrl: string);
begin
  FUrl := AUrl.TrimRight(['/']) + '/api/events/raw?clef';
  FQueue := TThreadedQueue<string>.Create(10000, 0, 1000);
  inherited Create(False);
end;

destructor TSeqShipper.Destroy;
begin
  inherited Destroy; // wartet auf Execute-Ende (Terminate wurde vorher gesetzt)
  FQueue.Free;
end;

procedure TSeqShipper.Enqueue(const ALine: string);
begin
  // PushTimeout = 0: ist die Queue voll (Seq lange weg), wird verworfen statt blockiert.
  FQueue.PushItem(ALine);
end;

procedure TSeqShipper.Execute;
var
  Http: TIdHTTP;
  Batch: TStringBuilder;
  Line: string;
  Body: TStringStream;
begin
  Http := TIdHTTP.Create(nil);
  Batch := TStringBuilder.Create;
  try
    Http.ConnectTimeout := 2000;
    Http.ReadTimeout := 2000;
    Http.Request.ContentType := 'application/vnd.serilog.clef';
    while not Terminated do
    begin
      Batch.Clear;
      // Erstes Element mit Timeout (1 s), danach alles, was sofort verfuegbar ist.
      if FQueue.PopItem(Line) = wrSignaled then
      begin
        Batch.Append(Line).Append(#10);
        while (FQueue.QueueSize > 0) and (FQueue.PopItem(Line) = wrSignaled) do
          Batch.Append(Line).Append(#10);
      end;
      if Batch.Length = 0 then
        Continue;

      Body := TStringStream.Create(Batch.ToString, TEncoding.UTF8);
      try
        try
          Http.Post(FUrl, Body);
        except
          // Seq nicht erreichbar: Batch verwerfen, stdout hat die Logs ohnehin.
          on Exception do ;
        end;
      finally
        Body.Free;
      end;
    end;
  finally
    Batch.Free;
    Http.Free;
  end;
end;

procedure StartLogShipping;
var
  SeqUrl: string;
begin
  SeqUrl := EnvOrDefault('SEQ_URL', '');
  if SeqUrl <> '' then
    Shipper := TSeqShipper.Create(SeqUrl);
end;

procedure StopLogShipping;
var
  Old: TSeqShipper;
begin
  Old := Shipper;
  Shipper := nil;
  if Old <> nil then
  begin
    Old.Terminate;
    Old.Free;
  end;
end;

initialization
  ConsoleLock := TCriticalSection.Create;

finalization
  StopLogShipping;
  ConsoleLock.Free;

end.
