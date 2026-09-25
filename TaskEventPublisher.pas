unit TaskEventPublisher;

{ Published Task-Events an den Fanout-Exchange "task-events" auf RabbitMQ -
  per STOMP (RabbitMQ-STOMP-Plugin), weil es fuer Delphi keine offizielle
  AMQP-0-9-1-Client-Library gibt. Vertrag: ../contracts/asyncapi/task-events.yaml

  Baut fuer jedes Event eine neue, kurze TCP-Verbindung auf (CONNECT -> SEND
  -> DISCONNECT) statt eine Verbindung offenzuhalten - einfacher und robust
  genug fuer dieses Grundgerueest. TODO fuer die Weiterentwicklung: bei hohem
  Durchsatz eine Verbindung wiederverwenden/poolen. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.DateUtils,
  IdTCPClient,
  IdGlobal;

type
  TTaskEventType = (etCreated, etUpdated, etCompleted, etDeleted);

procedure PublishTaskEvent(const AHost: string; APort: Integer; const AEventType: TTaskEventType;
  const ATaskId, AOwnerUserId, ATitle, AStatus: string);

implementation

function EventTypeToString(AEventType: TTaskEventType): string;
begin
  case AEventType of
    etCreated: Result := 'TASK_CREATED';
    etUpdated: Result := 'TASK_UPDATED';
    etCompleted: Result := 'TASK_COMPLETED';
    etDeleted: Result := 'TASK_DELETED';
  else
    Result := 'TASK_UPDATED';
  end;
end;

procedure PublishTaskEvent(const AHost: string; APort: Integer; const AEventType: TTaskEventType;
  const ATaskId, AOwnerUserId, ATitle, AStatus: string);
var
  Client: TIdTCPClient;
  Body: TJSONObject;
  BodyStr: string;
  BodyBytes: TIdBytes;
  NullTerminator: TIdBytes;
  ConnectFrame, SendFrame: string;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('eventId', TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
    Body.AddPair('eventType', EventTypeToString(AEventType));
    Body.AddPair('taskId', ATaskId);
    Body.AddPair('ownerUserId', AOwnerUserId);
    Body.AddPair('title', ATitle);
    Body.AddPair('status', AStatus);
    Body.AddPair('occurredAt', DateToISO8601(Now, False));
    BodyStr := Body.ToJSON;
  finally
    Body.Free;
  end;

  BodyBytes := IndyTextEncoding_UTF8.GetBytes(BodyStr);
  SetLength(NullTerminator, 1);
  NullTerminator[0] := 0;

  Client := TIdTCPClient.Create(nil);
  try
    Client.Host := AHost;
    Client.Port := APort;
    Client.ConnectTimeout := 3000;
    try
      Client.Connect;
    except
      on E: Exception do
      begin
        // Ein Broker-Ausfall darf einen Task-CRUD-Request nicht zum Scheitern
        // bringen - das Event geht dann einfach verloren (siehe Fanout-Verhalten
        // im M321-Demo-Projekt: kein "Nachliefern" ohne Queue).
        Writeln(' [!] Konnte Event nicht publizieren, Broker nicht erreichbar: ', E.Message);
        Exit;
      end;
    end;

    ConnectFrame :=
      'CONNECT'#10 +
      'accept-version:1.2'#10 +
      'host:/'#10 +
      'login:guest'#10 +
      'passcode:guest'#10 +
      #10 +
      #0;
    Client.IOHandler.Write(ConnectFrame, IndyTextEncoding_UTF8);
    // Auf die CONNECTED-Antwort wird bewusst nicht gewartet/geprueft - RabbitMQ
    // verarbeitet die Frames auf derselben TCP-Verbindung streng in Reihenfolge.

    SendFrame :=
      'SEND'#10 +
      'destination:/exchange/task-events/'#10 +
      'content-type:application/json'#10 +
      'content-length:' + IntToStr(Length(BodyBytes)) + #10 +
      #10;
    Client.IOHandler.Write(SendFrame, IndyTextEncoding_UTF8);
    Client.IOHandler.Write(BodyBytes);
    Client.IOHandler.Write(NullTerminator);

    Client.IOHandler.Write('DISCONNECT'#10#10#0, IndyTextEncoding_UTF8);

    Client.Disconnect;
  finally
    Client.Free;
  end;
end;

end.
