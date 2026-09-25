program TaskService;

{ Task-Service (Delphi) - Grundgerueest fuer das Task-Management-System.

  Verwaltet Aufgaben pro eingeloggtem Benutzer (In-Memory, siehe
  TaskModel.pas - TODO: durch echte Persistenz ersetzen) und published bei
  jeder Aenderung ein Event an RabbitMQ (Fanout-Exchange "task-events", per
  STOMP, siehe TaskEventPublisher.pas), das der History/Export-Service
  (Python, separates Repo) konsumiert.

  Schnittstellenbeschreibung (verbindlich): ../contracts/openapi/task-service.yaml
  Event-Format (verbindlich): ../contracts/asyncapi/task-events.yaml
  Bei Aenderungen ist ZUERST das jeweilige Contract-Repo anzupassen.

  Authentifizierung: OAuth2 Access-Token (Bearer) von Keycloak, siehe
  JwtAuth.pas - Achtung, dort steht ein wichtiges TODO (Signaturpruefung
  fehlt noch im aktuellen Grundgerueest).
  Autorisierung: ressourcenbasiert - jede Aufgabe gehoert dem "sub"-Claim
  des einloggten Benutzers, keine Rollen.

  Konfiguration per Umgebungsvariable (mit lokalen Defaults):
    PORT                 - eigener HTTP-Port (Default 8090)
    RABBITMQ_HOST        - Broker-Host (Default localhost)
    RABBITMQ_STOMP_PORT  - Broker-STOMP-Port (Default 61613)

  Aufruf: TaskService.exe (Beenden mit Ctrl+C) }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.DateUtils,
  System.Generics.Collections,
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  IdGlobal,
  TaskModel in 'TaskModel.pas',
  JwtAuth in 'JwtAuth.pas',
  TaskEventPublisher in 'TaskEventPublisher.pas';

var
  Store: TTaskStore;
  RabbitMqHost: string;
  RabbitMqStompPort: Integer;

function EnvOrDefault(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function TaskToJson(ATask: TTask): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', ATask.Id);
  Result.AddPair('ownerUserId', ATask.OwnerUserId);
  Result.AddPair('title', ATask.Title);
  Result.AddPair('description', ATask.Description);
  Result.AddPair('status', StatusToString(ATask.Status));
  Result.AddPair('createdAt', DateToISO8601(ATask.CreatedAt));
  Result.AddPair('updatedAt', DateToISO8601(ATask.UpdatedAt));
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

procedure RespondJson(AResponseInfo: TIdHTTPResponseInfo; AStatus: Integer; const ABody: string);
begin
  AResponseInfo.ResponseNo := AStatus;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
  AResponseInfo.ContentText := ABody;
end;

procedure RespondError(AResponseInfo: TIdHTTPResponseInfo; AStatus: Integer; const AMessage: string);
var
  Body: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('error', AMessage);
    RespondJson(AResponseInfo, AStatus, Body.ToJSON);
  finally
    Body.Free;
  end;
end;

{ Prueft Authentifizierung, schreibt bei Fehlern direkt die Response.
  Gibt True zurueck, wenn AInfo gefuellt ist und der Request weitergehen darf. }
function Authenticate(ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo;
  out AInfo: TJwtInfo): Boolean;
var
  Err: string;
begin
  Result := TryAuthenticate(ARequestInfo.RawHeaders.Values['Authorization'], AInfo, Err);
  if not Result then
  begin
    AResponseInfo.CustomHeaders.Values['WWW-Authenticate'] := 'Bearer';
    RespondError(AResponseInfo, 401, Err);
  end;
end;

procedure HandleHealth(AResponseInfo: TIdHTTPResponseInfo);
var
  Body: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('status', 'UP');
    Body.AddPair('service', 'task-service-delphi');
    RespondJson(AResponseInfo, 200, Body.ToJSON);
  finally
    Body.Free;
  end;
end;

procedure HandleListTasks(ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Info: TJwtInfo;
  Tasks: TArray<TTask>;
  Arr: TJSONArray;
  T: TTask;
begin
  if not Authenticate(ARequestInfo, AResponseInfo, Info) then
    Exit;

  Tasks := Store.ListByOwner(Info.UserId);
  Arr := TJSONArray.Create;
  try
    for T in Tasks do
      Arr.AddElement(TaskToJson(T));
    RespondJson(AResponseInfo, 200, Arr.ToJSON);
  finally
    Arr.Free;
  end;
end;

procedure HandleCreateTask(ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Info: TJwtInfo;
  Value: TJSONValue;
  Title, Description: string;
  NewTask: TTask;
begin
  if not Authenticate(ARequestInfo, AResponseInfo, Info) then
    Exit;

  Value := TJSONObject.ParseJSONValue(ReadRequestBody(ARequestInfo));
  try
    if not (Value is TJSONObject) or
       not TJSONObject(Value).TryGetValue<string>('title', Title) or
       (Title.Trim = '') then
    begin
      RespondError(AResponseInfo, 400, 'Feld ''title'' fehlt oder ist leer');
      Exit;
    end;
    TJSONObject(Value).TryGetValue<string>('description', Description);
  finally
    Value.Free;
  end;

  NewTask := Store.Add(Info.UserId, Title, Description);
  PublishTaskEvent(RabbitMqHost, RabbitMqStompPort, etCreated, NewTask.Id, NewTask.OwnerUserId,
    NewTask.Title, StatusToString(NewTask.Status));
  RespondJson(AResponseInfo, 201, TaskToJson(NewTask).ToJSON);
end;

procedure HandleGetTask(ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo;
  const ATaskId: string);
var
  Info: TJwtInfo;
  Found: TTask;
begin
  if not Authenticate(ARequestInfo, AResponseInfo, Info) then
    Exit;

  Found := Store.FindByIdAndOwner(ATaskId, Info.UserId);
  if Found = nil then
    RespondError(AResponseInfo, 404, 'Aufgabe nicht gefunden')
  else
    RespondJson(AResponseInfo, 200, TaskToJson(Found).ToJSON);
end;

procedure HandleUpdateTask(ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo;
  const ATaskId: string);
var
  Info: TJwtInfo;
  Value: TJSONValue;
  Title, Description, StatusStr: string;
  HasTitle, HasDescription, HasStatus: Boolean;
  Status: TTaskStatus;
  Updated: TTask;
  EventType: TTaskEventType;
begin
  if not Authenticate(ARequestInfo, AResponseInfo, Info) then
    Exit;

  Value := TJSONObject.ParseJSONValue(ReadRequestBody(ARequestInfo));
  try
    if not (Value is TJSONObject) then
    begin
      RespondError(AResponseInfo, 400, 'Ungueltiger Request-Body');
      Exit;
    end;
    HasTitle := TJSONObject(Value).TryGetValue<string>('title', Title);
    HasDescription := TJSONObject(Value).TryGetValue<string>('description', Description);
    HasStatus := TJSONObject(Value).TryGetValue<string>('status', StatusStr);
    if HasStatus and not StringToStatus(StatusStr, Status) then
    begin
      RespondError(AResponseInfo, 400, 'Ungueltiger Wert fuer ''status'' (erlaubt: OPEN, DONE)');
      Exit;
    end;
  finally
    Value.Free;
  end;

  Updated := Store.Update(ATaskId, Info.UserId, Title, Description, HasTitle, HasDescription,
    Status, HasStatus);
  if Updated = nil then
  begin
    RespondError(AResponseInfo, 404, 'Aufgabe nicht gefunden');
    Exit;
  end;

  if HasStatus and (Status = tsDone) then
    EventType := etCompleted
  else
    EventType := etUpdated;
  PublishTaskEvent(RabbitMqHost, RabbitMqStompPort, EventType, Updated.Id, Updated.OwnerUserId,
    Updated.Title, StatusToString(Updated.Status));
  RespondJson(AResponseInfo, 200, TaskToJson(Updated).ToJSON);
end;

procedure HandleDeleteTask(ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo;
  const ATaskId: string);
var
  Info: TJwtInfo;
  Existing: TTask;
begin
  if not Authenticate(ARequestInfo, AResponseInfo, Info) then
    Exit;

  Existing := Store.FindByIdAndOwner(ATaskId, Info.UserId);
  if Existing = nil then
  begin
    RespondError(AResponseInfo, 404, 'Aufgabe nicht gefunden');
    Exit;
  end;

  // Titel/Status VOR dem Loeschen fuer das Event sichern.
  PublishTaskEvent(RabbitMqHost, RabbitMqStompPort, etDeleted, Existing.Id, Existing.OwnerUserId,
    Existing.Title, StatusToString(Existing.Status));
  Store.Delete(ATaskId, Info.UserId);
  AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
  AResponseInfo.ResponseNo := 204;
  AResponseInfo.ContentText := '';
end;

procedure RouteRequest(ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Verb, Path, TaskId: string;
  Segments: TArray<string>;
begin
  Verb := ARequestInfo.Command.ToUpper;
  Path := ARequestInfo.Document;

  if Verb = 'OPTIONS' then
  begin
    AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
    AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Methods'] := 'GET, POST, PUT, DELETE, OPTIONS';
    AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Headers'] := 'Content-Type, Authorization';
    AResponseInfo.ResponseNo := 204;
    AResponseInfo.ContentText := '';
    Exit;
  end;

  if (Path = '/health') and (Verb = 'GET') then
  begin
    HandleHealth(AResponseInfo);
    Exit;
  end;

  if (Path = '/tasks') and (Verb = 'GET') then
  begin
    HandleListTasks(ARequestInfo, AResponseInfo);
    Exit;
  end;

  if (Path = '/tasks') and (Verb = 'POST') then
  begin
    HandleCreateTask(ARequestInfo, AResponseInfo);
    Exit;
  end;

  Segments := Path.Split(['/']);
  // Path beginnt mit '/', Split liefert also an Index 0 einen leeren String.
  if (Length(Segments) = 3) and (Segments[1] = 'tasks') and (Segments[2] <> '') then
  begin
    TaskId := Segments[2];
    if Verb = 'GET' then
    begin
      HandleGetTask(ARequestInfo, AResponseInfo, TaskId);
      Exit;
    end;
    if Verb = 'PUT' then
    begin
      HandleUpdateTask(ARequestInfo, AResponseInfo, TaskId);
      Exit;
    end;
    if Verb = 'DELETE' then
    begin
      HandleDeleteTask(ARequestInfo, AResponseInfo, TaskId);
      Exit;
    end;
    RespondError(AResponseInfo, 405, 'Methode nicht unterstuetzt fuer /tasks/{id}');
    Exit;
  end;

  RespondError(AResponseInfo, 404, 'Unbekannter Endpoint: ' + Verb + ' ' + Path);
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
begin
  RouteRequest(ARequestInfo, AResponseInfo);
end;

{ Indy wuerde den "Authorization"-Header sonst selbst als Basic/Digest deuten
  und einen eigenen 401 zurueckgeben, bevor unser Router (der Bearer-Tokens
  selbst prueft, siehe JwtAuth.pas) ueberhaupt zum Zug kommt. }
procedure TRequestRouter.HandleParseAuthentication(AContext: TIdContext;
  const AAuthType, AAuthData: string; var VUsername, VPassword: string; var VHandled: Boolean);
begin
  VHandled := True;
end;

var
  Server: TIdHTTPServer;
  Router: TRequestRouter;
  Port: Integer;
begin
  RabbitMqHost := EnvOrDefault('RABBITMQ_HOST', 'localhost');
  RabbitMqStompPort := StrToIntDef(EnvOrDefault('RABBITMQ_STOMP_PORT', '61613'), 61613);
  Port := StrToIntDef(EnvOrDefault('PORT', '8090'), 8090);

  Store := TTaskStore.Create;
  Router := TRequestRouter.Create;
  try
    Server := TIdHTTPServer.Create(nil);
    try
      Server.DefaultPort := Port;
      Server.OnCommandGet := Router.HandleCommand;
      Server.OnCommandOther := Router.HandleCommand; // Ein Router fuer alle Verben.
      Server.OnParseAuthentication := Router.HandleParseAuthentication;
      Server.Active := True;

      Writeln('=== Task-Service (Delphi) ===');
      Writeln('Laeuft auf http://localhost:', Port);
      Writeln('RabbitMQ (STOMP): ', RabbitMqHost, ':', RabbitMqStompPort);
      Writeln('Beenden mit Ctrl+C ...');
      Writeln;

      while True do
        Sleep(1000);
    finally
      Server.Free;
    end;
  finally
    Router.Free;
    Store.Free;
  end;
end.
