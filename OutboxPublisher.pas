unit OutboxPublisher;

{ Versendet die Events aus der Outbox (siehe TaskStore.pas) an den
  Fanout-Exchange "task-events" auf RabbitMQ - per STOMP (RabbitMQ-STOMP-
  Plugin), weil es fuer Delphi keine offizielle AMQP-0-9-1-Client-Library
  gibt. Vertrag: ../contracts/asyncapi/task-events.yaml

  Ablauf (eigener Hintergrund-Thread, blockiert nie einen HTTP-Request):
    1. Unversendete Events aus der Outbox lesen (in Entstehungsreihenfolge).
    2. Ueber eine offen gehaltene STOMP-Verbindung senden, jeweils mit
       "receipt"-Header, und auf die RECEIPT-Bestaetigung des Brokers warten.
    3. Erst nach der Bestaetigung als versendet markieren.
  Faellt der Broker aus (oder fehlt der Exchange noch), bleibt das Event in
  der Outbox und wird mit exponentiellem Backoff (1 s .. 30 s) erneut
  versucht. Das ergibt at-least-once: geht nach dem Senden die Bestaetigung
  verloren, wird das Event nochmals gesendet - der Consumer dedupliziert
  ueber eventId (siehe Vertrag). }

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  IdTCPClient,
  TaskStore;

type
  TOutboxPublisher = class(TThread)
  private
    FStore: TTaskStore;
    FHost: string;
    FPort: Integer;
    FLogin: string;
    FPasscode: string;
    FClient: TIdTCPClient;
    FStopSignal: TEvent;
    procedure EnsureConnected;
    procedure Disconnect;
    function ReadFrame: string;
    procedure SendEvent(const AEntry: TOutboxEntry);
  protected
    procedure Execute; override;
  public
    constructor Create(AStore: TTaskStore; const AHost: string; APort: Integer;
      const ALogin, APasscode: string);
    destructor Destroy; override;
    procedure Stop;
  end;

implementation

uses
  System.Math,
  System.JSON,
  IdGlobal,
  AppLog;

const
  Destination = '/exchange/task-events/';
  ReceiptTimeoutMs = 5000;
  MaxBackoffMs = 30000;
  BatchSize = 50;

{ TOutboxPublisher }

constructor TOutboxPublisher.Create(AStore: TTaskStore; const AHost: string; APort: Integer;
  const ALogin, APasscode: string);
begin
  FStore := AStore;
  FHost := AHost;
  FPort := APort;
  FLogin := ALogin;
  FPasscode := APasscode;
  FStopSignal := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TOutboxPublisher.Destroy;
begin
  Stop;
  inherited Destroy; // wartet auf das Ende von Execute
  Disconnect;
  FStopSignal.Free;
end;

procedure TOutboxPublisher.Stop;
begin
  Terminate;
  FStopSignal.SetEvent;
  FStore.OutboxSignal.SetEvent;
end;

function TOutboxPublisher.ReadFrame: string;
var
  B: Byte;
  Bytes: TIdBytes;
begin
  SetLength(Bytes, 0);
  // Zeilenumbrueche zwischen Frames (Heartbeats) ueberspringen.
  repeat
    B := FClient.IOHandler.ReadByte;
  until (B <> 10) and (B <> 13);
  while B <> 0 do
  begin
    AppendByte(Bytes, B);
    B := FClient.IOHandler.ReadByte;
  end;
  Result := IndyTextEncoding_UTF8.GetString(Bytes);
end;

procedure TOutboxPublisher.EnsureConnected;
var
  Frame: string;
begin
  if (FClient <> nil) and FClient.Connected then
    Exit;
  Disconnect;

  FClient := TIdTCPClient.Create(nil);
  FClient.Host := FHost;
  FClient.Port := FPort;
  FClient.ConnectTimeout := 3000;
  FClient.ReadTimeout := ReceiptTimeoutMs;
  FClient.Connect;

  FClient.IOHandler.Write(
    'CONNECT'#10 +
    'accept-version:1.2'#10 +
    'host:/'#10 +
    'heart-beat:0,0'#10 +
    'login:' + FLogin + #10 +
    'passcode:' + FPasscode + #10 +
    #10#0, IndyTextEncoding_UTF8);

  Frame := ReadFrame;
  if not Frame.StartsWith('CONNECTED') then
    raise Exception.Create('STOMP-Login fehlgeschlagen: ' + Frame.Replace(#10, ' '));
  Log(llInfo, 'Verbindung zu RabbitMQ (STOMP) hergestellt', '',
    TJSONObject.Create.AddPair('broker', FHost + ':' + IntToStr(FPort)));
end;

procedure TOutboxPublisher.Disconnect;
begin
  if FClient = nil then
    Exit;
  try
    if FClient.Connected then
    begin
      FClient.IOHandler.Write('DISCONNECT'#10#10#0, IndyTextEncoding_UTF8);
      FClient.Disconnect;
    end;
  except
    on Exception do ; // Verbindung war ohnehin schon kaputt
  end;
  FreeAndNil(FClient);
end;

procedure TOutboxPublisher.SendEvent(const AEntry: TOutboxEntry);
var
  BodyBytes: TIdBytes;
  Headers, Frame: string;
begin
  BodyBytes := IndyTextEncoding_UTF8.GetBytes(AEntry.Payload);
  // amqp-message-id / correlation-id werden von RabbitMQ auf die gleichnamigen
  // AMQP-Properties abgebildet, persistent:true -> delivery_mode 2.
  Headers :=
    'SEND'#10 +
    'destination:' + Destination + #10 +
    'content-type:application/json'#10 +
    'content-length:' + IntToStr(Length(BodyBytes)) + #10 +
    'persistent:true'#10 +
    'amqp-message-id:' + AEntry.EventId + #10 +
    'receipt:' + AEntry.EventId + #10;
  if AEntry.CorrelationId <> '' then
    Headers := Headers + 'correlation-id:' + AEntry.CorrelationId + #10;
  FClient.IOHandler.Write(Headers + #10, IndyTextEncoding_UTF8);
  FClient.IOHandler.Write(BodyBytes);
  FClient.IOHandler.Write(Byte(0));

  Frame := ReadFrame;
  if Frame.StartsWith('ERROR') then
    raise Exception.Create('Broker meldet Fehler: ' + Frame.Replace(#10, ' '));
  if not (Frame.StartsWith('RECEIPT') and Frame.Contains('receipt-id:' + AEntry.EventId)) then
    raise Exception.Create('Unerwartete Antwort statt RECEIPT: ' + Frame.Replace(#10, ' '));
end;

procedure TOutboxPublisher.Execute;
var
  Pending: TArray<TOutboxEntry>;
  Entry: TOutboxEntry;
  Current: string;
  BackoffMs: Integer;
begin
  NameThreadForDebugging('OutboxPublisher');
  BackoffMs := 0;
  while not Terminated do
  begin
    try
      Pending := FStore.FetchPendingOutbox(BatchSize);
    except
      on E: Exception do
      begin
        Log(llError, 'Outbox konnte nicht gelesen werden: ' + E.Message);
        FStopSignal.WaitFor(1000);
        Continue;
      end;
    end;

    if Length(Pending) = 0 then
    begin
      // Schlafen, bis ein neues Event committed wurde (oder max. 2 s).
      FStore.OutboxSignal.WaitFor(2000);
      Continue;
    end;

    Current := '';
    try
      EnsureConnected;
      for Entry in Pending do
      begin
        if Terminated then
          Break;
        Current := Entry.EventId;
        SendEvent(Entry);
        FStore.MarkOutboxSent(Entry.EventId);
        Log(llInfo, 'Event an RabbitMQ published', Entry.CorrelationId,
          TJSONObject.Create.AddPair('eventId', Entry.EventId)
            .AddPair('attempt', TJSONNumber.Create(Entry.Attempts + 1)));
      end;
      BackoffMs := 0;
    except
      on E: Exception do
      begin
        Disconnect;
        if Current <> '' then
          try
            FStore.MarkOutboxFailed(Current, E.Message);
          except
            on Exception do ;
          end;
        BackoffMs := Min(Max(BackoffMs * 2, 1000), MaxBackoffMs);
        Log(llWarning, Format('Event-Versand fehlgeschlagen, neuer Versuch in %d ms: %s',
          [BackoffMs, E.Message]), '',
          TJSONObject.Create.AddPair('eventId', Current)
            .AddPair('pending', TJSONNumber.Create(Length(Pending))));
        FStopSignal.WaitFor(BackoffMs);
      end;
    end;
  end;
end;

end.
