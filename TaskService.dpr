program TaskService;

{ Task-Service (Delphi) des Task-Management-Systems.

  Verwaltet Aufgaben pro eingeloggtem Benutzer (SQLite, siehe TaskStore.pas)
  und published bei jeder Aenderung ein Event an RabbitMQ (Fanout-Exchange
  "task-events") - ueber eine Transactional Outbox, die ein Hintergrund-
  Thread per STOMP versendet (siehe OutboxPublisher.pas). Ein Broker-Ausfall
  verzoegert also hoechstens die Events, nie einen HTTP-Request.

  Schnittstellenbeschreibung (verbindlich): ../contracts/openapi/task-service.yaml
  Event-Format (verbindlich): ../contracts/asyncapi/task-events.yaml
  Bei Aenderungen ist ZUERST das Contract-Repo anzupassen (EVOLUTION.md).

  Authentifizierung: OAuth2 Access-Token (Bearer) von Keycloak, Signatur-
  pruefung gegen die JWKS (JwtAuth.pas).
  Autorisierung: ressourcenbasiert - jede Aufgabe gehoert dem "sub"-Claim
  des eingeloggten Benutzers, keine Rollen.
  Observability: jeder Request bekommt eine Korrelations-ID (Header
  X-Correlation-ID, sonst neu erzeugt), die in jedem Log-Eintrag und im
  Event mitlaeuft (AppLog.pas).

  Konfiguration per Umgebungsvariable (mit lokalen Defaults):
    PORT                 - eigener HTTP-Port (Default 8090)
    DB_PATH              - SQLite-Datei (Default tasks.db neben der .exe)
    RABBITMQ_HOST        - Broker-Host (Default localhost)
    RABBITMQ_STOMP_PORT  - Broker-STOMP-Port (Default 61613)
    RABBITMQ_USER/_PASS  - Broker-Login (Default guest/guest)
    OIDC_JWKS_URL        - JWKS von Keycloak
    OIDC_ISSUER          - erwarteter Issuer
    SEQ_URL              - optional: zentrale Log-Aggregation (z.B. http://localhost:5341)

  Aufruf: TaskService.exe (Beenden mit Ctrl+C) }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.SyncObjs,
  System.Diagnostics,
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  IdGlobal,
  AppLog in 'AppLog.pas',
  TaskModel in 'TaskModel.pas',
  TaskStore in 'TaskStore.pas',
  OutboxPublisher in 'OutboxPublisher.pas',
  JwtAuth in 'JwtAuth.pas';

type
  { Kontext eines einzelnen Requests - wird an alle Handler durchgereicht. }
  TRequestContext = record
    Request: TIdHTTPRequestInfo;
    Response: TIdHTTPResponseInfo;
    CorrelationId: string;
    User: TJwtInfo;
  end;

var
  Store: TTaskStore;
  ShutdownSignal: TEvent;

{ Uebernimmt die Korrelations-ID des Aufrufers, wenn sie harmlos ist
  (sie landet in Logs und STOMP-Headern), sonst wird eine neue erzeugt. }
function ResolveCorrelationId(const AHeaderValue: string): string;
var
  C: Char;
begin
  Result := AHeaderValue.Trim;
  if (Result = '') or (Length(Result) > 64) then
    Exit(NewUuid);
  for C in Result do
    if not CharInSet(C, ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.']) then
      Exit(NewUuid);
end;

function ReadRequestBody(ARequestInfo: TIdHTTPRequestInfo): string;
var
  Stream: TStringStream;
begin
  Result := '';
  if (ARequestInfo.PostStream = nil) or (ARequestInfo.PostStream.Size = 0) then
    Exit;
  Stream := TStringStream.Create('', TEncoding.UTF8);
  try
    ARequestInfo.PostStream.Position := 0;
    Stream.CopyFrom(ARequestInfo.PostStream, ARequestInfo.PostStream.Size);
    Result := Stream.DataString;
  finally
    Stream.Free;
  end;
end;

procedure SetCommonHeaders(const ACtx: TRequestContext);
begin
  ACtx.Response.CustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
  ACtx.Response.CustomHeaders.Values['Access-Control-Expose-Headers'] := 'X-Correlation-ID';
  ACtx.Response.CustomHeaders.Values['X-Correlation-ID'] := ACtx.CorrelationId;
end;

{ Schreibt AJson als Response und gibt AJson frei. }
procedure RespondJson(const ACtx: TRequestContext; AStatus: Integer; AJson: TJSONValue);
begin
  try
    ACtx.Response.ResponseNo := AStatus;
    ACtx.Response.ContentType := 'application/json; charset=utf-8';
    ACtx.Response.ContentText := AJson.ToJSON;
  finally
    AJson.Free;
  end;
end;

procedure RespondError(const ACtx: TRequestContext; AStatus: Integer; const AMessage: string);
begin
  RespondJson(ACtx, AStatus, TJSONObject.Create
    .AddPair('error', AMessage)
    .AddPair('correlationId', ACtx.CorrelationId));
end;

function Authenticate(var ACtx: TRequestContext): Boolean;
var
  Err: string;
begin
  Result := TryAuthenticate(ACtx.Request.RawHeaders.Values['Authorization'], ACtx.User, Err);
  if not Result then
  begin
    ACtx.Response.CustomHeaders.Values['WWW-Authenticate'] := 'Bearer error="invalid_token"';
    Log(llWarning, 'Authentifizierung fehlgeschlagen: ' + Err, ACtx.CorrelationId);
    RespondError(ACtx, 401, Err);
  end;
end;

{ Liest den Body als JSON-Objekt. Bei Fehler: 400 geschrieben, Result = nil. }
function ParseBody(const ACtx: TRequestContext): TJSONObject;
var
  Value: TJSONValue;
begin
  Value := TJSONObject.ParseJSONValue(ReadRequestBody(ACtx.Request));
  if Value is TJSONObject then
    Exit(TJSONObject(Value));
  Value.Free;
  RespondError(ACtx, 400, 'Request-Body muss ein JSON-Objekt sein');
  Result := nil;
end;

function ValidateText(const ACtx: TRequestContext; const AField, AValue: string;
  AMinLength, AMaxLength: Integer): Boolean;
begin
  Result := (AValue.Trim.Length >= AMinLength) and (AValue.Length <= AMaxLength);
  if not Result then
    RespondError(ACtx, 400, Format('Feld ''%s'' muss %d bis %d Zeichen lang sein',
      [AField, AMinLength, AMaxLength]));
end;

procedure HandleHealth(const ACtx: TRequestContext);
begin
  if Store.IsHealthy then
    RespondJson(ACtx, 200, TJSONObject.Create
      .AddPair('status', 'UP')
      .AddPair('service', 'task-service-delphi')
      .AddPair('version', ContractVersion)
      .AddPair('pendingEvents', TJSONNumber.Create(Store.PendingOutboxCount)))
  else
    RespondError(ACtx, 503, 'Datenbank nicht verfuegbar');
end;

procedure HandleListTasks(var ACtx: TRequestContext);
var
  Arr: TJSONArray;
  T: TTask;
begin
  if not Authenticate(ACtx) then
    Exit;
  Arr := TJSONArray.Create;
  for T in Store.ListByOwner(ACtx.User.UserId) do
    Arr.AddElement(TaskToApiJson(T));
  RespondJson(ACtx, 200, Arr);
end;

procedure HandleCreateTask(var ACtx: TRequestContext);
var
  Body: TJSONObject;
  Title, Description: string;
  NewTask: TTask;
begin
  if not Authenticate(ACtx) then
    Exit;
  Body := ParseBody(ACtx);
  if Body = nil then
    Exit;
  try
    if not Body.TryGetValue<string>('title', Title) then
      Title := '';
    if not Body.TryGetValue<string>('description', Description) then
      Description := '';
  finally
    Body.Free;
  end;
  if not ValidateText(ACtx, 'title', Title, 1, MaxTitleLength) or
     not ValidateText(ACtx, 'description', Description, 0, MaxDescriptionLength) then
    Exit;

  NewTask := Store.CreateTask(ACtx.User.UserId, Title.Trim, Description, ACtx.CorrelationId);
  Log(llInfo, 'Aufgabe angelegt', ACtx.CorrelationId,
    TJSONObject.Create.AddPair('taskId', NewTask.Id).AddPair('user', ACtx.User.Username));
  RespondJson(ACtx, 201, TaskToApiJson(NewTask));
end;

procedure HandleGetTask(var ACtx: TRequestContext; const ATaskId: string);
var
  Found: TTask;
begin
  if not Authenticate(ACtx) then
    Exit;
  if Store.FindByIdAndOwner(ATaskId, ACtx.User.UserId, Found) then
    RespondJson(ACtx, 200, TaskToApiJson(Found))
  else
    RespondError(ACtx, 404, 'Aufgabe nicht gefunden');
end;

procedure HandleUpdateTask(var ACtx: TRequestContext; const ATaskId: string);
var
  Body: TJSONObject;
  Title, Description, StatusStr: string;
  HasTitle, HasDescription, HasStatus: Boolean;
  Status: TTaskStatus;
  Updated: TTask;
begin
  if not Authenticate(ACtx) then
    Exit;
  Body := ParseBody(ACtx);
  if Body = nil then
    Exit;
  try
    HasTitle := Body.TryGetValue<string>('title', Title);
    HasDescription := Body.TryGetValue<string>('description', Description);
    HasStatus := Body.TryGetValue<string>('status', StatusStr);
  finally
    Body.Free;
  end;

  Status := tsOpen;
  if HasStatus and not StringToStatus(StatusStr, Status) then
  begin
    RespondError(ACtx, 400, 'Ungueltiger Wert fuer ''status'' (erlaubt: OPEN, DONE)');
    Exit;
  end;
  if HasTitle and not ValidateText(ACtx, 'title', Title, 1, MaxTitleLength) then
    Exit;
  if HasDescription and not ValidateText(ACtx, 'description', Description, 0, MaxDescriptionLength) then
    Exit;

  if not Store.UpdateTask(ATaskId, ACtx.User.UserId, Title.Trim, Description, HasTitle,
    HasDescription, Status, HasStatus, ACtx.CorrelationId, Updated) then
  begin
    RespondError(ACtx, 404, 'Aufgabe nicht gefunden');
    Exit;
  end;
  Log(llInfo, 'Aufgabe aktualisiert', ACtx.CorrelationId,
    TJSONObject.Create.AddPair('taskId', Updated.Id).AddPair('status', StatusToString(Updated.Status)));
  RespondJson(ACtx, 200, TaskToApiJson(Updated));
end;

procedure HandleDeleteTask(var ACtx: TRequestContext; const ATaskId: string);
begin
  if not Authenticate(ACtx) then
    Exit;
  if not Store.DeleteTask(ATaskId, ACtx.User.UserId, ACtx.CorrelationId) then
  begin
    RespondError(ACtx, 404, 'Aufgabe nicht gefunden');
    Exit;
  end;
  Log(llInfo, 'Aufgabe geloescht', ACtx.CorrelationId, TJSONObject.Create.AddPair('taskId', ATaskId));
  ACtx.Response.ResponseNo := 204;
  ACtx.Response.ContentText := '';
end;

procedure RouteRequest(var ACtx: TRequestContext);
var
  Verb, Path, TaskId: string;
  Segments: TArray<string>;
begin
  Verb := ACtx.Request.Command.ToUpper;
  Path := ACtx.Request.Document;

  if Verb = 'OPTIONS' then
  begin
    ACtx.Response.CustomHeaders.Values['Access-Control-Allow-Methods'] := 'GET, POST, PUT, DELETE, OPTIONS';
    ACtx.Response.CustomHeaders.Values['Access-Control-Allow-Headers'] := 'Content-Type, Authorization, X-Correlation-ID';
    ACtx.Response.ResponseNo := 204;
    ACtx.Response.ContentText := '';
    Exit;
  end;

  if (Path = '/health') and (Verb = 'GET') then
  begin
    HandleHealth(ACtx);
    Exit;
  end;

  // Versionierte Pfade (/v1/tasks...) und - deprecated - die unversionierten
  // Pfade aus Vertrag 1.0.0 (/tasks...) landen im selben Handler.
  if Path.StartsWith('/v1/') then
    Path := Path.Substring(3)
  else if Path.StartsWith('/tasks') then
    ACtx.Response.CustomHeaders.Values['Deprecation'] := 'true';

  if Path = '/tasks' then
  begin
    if Verb = 'GET' then
      HandleListTasks(ACtx)
    else if Verb = 'POST' then
      HandleCreateTask(ACtx)
    else
      RespondError(ACtx, 405, 'Methode nicht unterstuetzt fuer /tasks');
    Exit;
  end;

  Segments := Path.Split(['/']);
  // Path beginnt mit '/', Split liefert also an Index 0 einen leeren String.
  if (Length(Segments) = 3) and (Segments[1] = 'tasks') and (Segments[2] <> '') then
  begin
    TaskId := Segments[2];
    if Verb = 'GET' then
      HandleGetTask(ACtx, TaskId)
    else if Verb = 'PUT' then
      HandleUpdateTask(ACtx, TaskId)
    else if Verb = 'DELETE' then
      HandleDeleteTask(ACtx, TaskId)
    else
      RespondError(ACtx, 405, 'Methode nicht unterstuetzt fuer /tasks/{id}');
    Exit;
  end;

  RespondError(ACtx, 404, 'Unbekannter Endpoint: ' + Verb + ' ' + ACtx.Request.Document);
end;

type
  { Indy-Events muessen Methodenzeiger sein - deshalb dieser kleine Wrapper
    statt einer freien Prozedur. }
  TRequestRouter = class
    procedure HandleCommand(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
    procedure HandleParseAuthentication(AContext: TIdContext; const AAuthType, AAuthData: string;
      var VUsername, VPassword: string; var VHandled: Boolean);
  end;

procedure TRequestRouter.HandleCommand(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Ctx: TRequestContext;
  Watch: TStopwatch;
begin
  Watch := TStopwatch.StartNew;
  Ctx := Default(TRequestContext);
  Ctx.Request := ARequestInfo;
  Ctx.Response := AResponseInfo;
  Ctx.CorrelationId := ResolveCorrelationId(ARequestInfo.RawHeaders.Values['X-Correlation-ID']);
  SetCommonHeaders(Ctx);
  try
    RouteRequest(Ctx);
  except
    on E: Exception do
    begin
      Log(llError, 'Unbehandelter Fehler: ' + E.ClassName + ': ' + E.Message, Ctx.CorrelationId);
      RespondError(Ctx, 500, 'Interner Fehler');
    end;
  end;
  if ARequestInfo.Document <> '/health' then
    Log(llInfo, 'HTTP-Request bearbeitet', Ctx.CorrelationId, TJSONObject.Create
      .AddPair('method', ARequestInfo.Command)
      .AddPair('path', ARequestInfo.Document)
      .AddPair('status', TJSONNumber.Create(AResponseInfo.ResponseNo))
      .AddPair('durationMs', TJSONNumber.Create(Watch.ElapsedMilliseconds))
      .AddPair('user', Ctx.User.Username));
end;

{ Indy wuerde den "Authorization"-Header sonst selbst als Basic/Digest deuten
  und einen eigenen 401 zurueckgeben, bevor unser Router (der Bearer-Tokens
  selbst prueft, siehe JwtAuth.pas) ueberhaupt zum Zug kommt. }
procedure TRequestRouter.HandleParseAuthentication(AContext: TIdContext;
  const AAuthType, AAuthData: string; var VUsername, VPassword: string; var VHandled: Boolean);
begin
  VHandled := True;
end;

function ConsoleCtrlHandler(ACtrlType: DWORD): BOOL; stdcall;
begin
  // Ctrl+C / Fenster schliessen: sauber herunterfahren statt hart abbrechen.
  ShutdownSignal.SetEvent;
  Result := True;
end;

var
  Server: TIdHTTPServer;
  Router: TRequestRouter;
  Publisher: TOutboxPublisher;
  Port, StompPort: Integer;
  DbPath, RabbitMqHost: string;
begin
  ShutdownSignal := TEvent.Create(nil, True, False, '');
  StartLogShipping;
  try
    Port := StrToIntDef(EnvOrDefault('PORT', '8090'), 8090);
    DbPath := EnvOrDefault('DB_PATH', ExtractFilePath(ParamStr(0)) + 'tasks.db');
    RabbitMqHost := EnvOrDefault('RABBITMQ_HOST', 'localhost');
    StompPort := StrToIntDef(EnvOrDefault('RABBITMQ_STOMP_PORT', '61613'), 61613);
    ConfigureJwtAuth(
      EnvOrDefault('OIDC_JWKS_URL', 'http://localhost:8082/realms/task-mgmt/protocol/openid-connect/certs'),
      EnvOrDefault('OIDC_ISSUER', 'http://localhost:8082/realms/task-mgmt'));

    Store := TTaskStore.Create(DbPath);
    Publisher := TOutboxPublisher.Create(Store, RabbitMqHost, StompPort,
      EnvOrDefault('RABBITMQ_USER', 'guest'), EnvOrDefault('RABBITMQ_PASS', 'guest'));
    Router := TRequestRouter.Create;
    Server := TIdHTTPServer.Create(nil);
    try
      Server.DefaultPort := Port;
      Server.OnCommandGet := Router.HandleCommand;
      Server.OnCommandOther := Router.HandleCommand; // Ein Router fuer alle Verben.
      Server.OnParseAuthentication := Router.HandleParseAuthentication;
      try
        Server.Active := True;
      except
        on E: Exception do
        begin
          Log(llError, Format('Port %d ist belegt oder nicht verfuegbar (%s). ' +
            'Anderen Port waehlen, z.B. start.cmd 8095', [Port, E.Message]));
          ExitCode := 1;
          Exit;
        end;
      end;

      SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
      Log(llInfo, Format('Task-Service laeuft auf http://localhost:%d (Vertrag %s)', [Port, ContractVersion]),
        '', TJSONObject.Create
          .AddPair('port', TJSONNumber.Create(Port))
          .AddPair('database', DbPath)
          .AddPair('broker', RabbitMqHost + ':' + IntToStr(StompPort)));

      ShutdownSignal.WaitFor(INFINITE);
      Log(llInfo, 'Fahre herunter ...');
      Server.Active := False;
    finally
      Server.Free;
      Router.Free;
      Publisher.Free;
      Store.Free;
    end;
  finally
    StopLogShipping;
    ShutdownSignal.Free;
  end;
end.
