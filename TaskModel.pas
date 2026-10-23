unit TaskModel;

{ Domaenenmodell des Task-Service und die Abbildung auf die externen
  Vertraege. Bewusst getrennt:
    - TTask             : internes Domaenenobjekt (Record, Wertsemantik - wird
                          beim Lesen aus der DB kopiert, keine geteilten
                          Referenzen zwischen Threads)
    - TaskToApiJson     : DTO gemaess contracts/openapi/task-service.yaml
    - BuildTaskEventJson: Event gemaess contracts/asyncapi/task-events.yaml
  Aendert sich ein Vertrag, wird nur die jeweilige Abbildung angepasst, nicht
  das Domaenenmodell. }

interface

uses
  System.SysUtils,
  System.JSON;

const
  ContractVersion = '1.1.0';
  EventSchemaVersion = 1;
  MaxTitleLength = 200;
  MaxDescriptionLength = 2000;

type
  TTaskStatus = (tsOpen, tsDone);
  TTaskEventType = (etCreated, etUpdated, etCompleted, etDeleted);

  TTask = record
    Id: string;
    OwnerUserId: string;
    Title: string;
    Description: string;
    Status: TTaskStatus;
    CreatedAt: TDateTime; // UTC
    UpdatedAt: TDateTime; // UTC
  end;

function StatusToString(AStatus: TTaskStatus): string;
function StringToStatus(const AValue: string; out AStatus: TTaskStatus): Boolean;
function EventTypeToString(AEventType: TTaskEventType): string;

function TaskToApiJson(const ATask: TTask): TJSONObject;

{ Baut das Event als JSON-Text. AEventStatus erlaubt 'DELETED' (nur im Event). }
function BuildTaskEventJson(const AEventId: string; AEventType: TTaskEventType; const ATask: TTask;
  const AEventStatus, ACorrelationId: string; AOccurredAt: TDateTime): string;

function NewUuid: string;

implementation

uses
  System.DateUtils;

function StatusToString(AStatus: TTaskStatus): string;
begin
  case AStatus of
    tsDone: Result := 'DONE';
  else
    Result := 'OPEN';
  end;
end;

function StringToStatus(const AValue: string; out AStatus: TTaskStatus): Boolean;
begin
  Result := True;
  if SameText(AValue, 'OPEN') then
    AStatus := tsOpen
  else if SameText(AValue, 'DONE') then
    AStatus := tsDone
  else
    Result := False;
end;

function EventTypeToString(AEventType: TTaskEventType): string;
begin
  case AEventType of
    etCreated: Result := 'TASK_CREATED';
    etCompleted: Result := 'TASK_COMPLETED';
    etDeleted: Result := 'TASK_DELETED';
  else
    Result := 'TASK_UPDATED';
  end;
end;

function TaskToApiJson(const ATask: TTask): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', ATask.Id);
  Result.AddPair('ownerUserId', ATask.OwnerUserId);
  Result.AddPair('title', ATask.Title);
  Result.AddPair('description', ATask.Description);
  Result.AddPair('status', StatusToString(ATask.Status));
  Result.AddPair('createdAt', DateToISO8601(ATask.CreatedAt, True));
  Result.AddPair('updatedAt', DateToISO8601(ATask.UpdatedAt, True));
end;

function BuildTaskEventJson(const AEventId: string; AEventType: TTaskEventType; const ATask: TTask;
  const AEventStatus, ACorrelationId: string; AOccurredAt: TDateTime): string;
var
  Body: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('eventId', AEventId);
    Body.AddPair('schemaVersion', TJSONNumber.Create(EventSchemaVersion));
    Body.AddPair('eventType', EventTypeToString(AEventType));
    Body.AddPair('taskId', ATask.Id);
    Body.AddPair('ownerUserId', ATask.OwnerUserId);
    Body.AddPair('title', ATask.Title);
    Body.AddPair('status', AEventStatus);
    Body.AddPair('occurredAt', DateToISO8601(AOccurredAt, True));
    if ACorrelationId <> '' then
      Body.AddPair('correlationId', ACorrelationId);
    Result := Body.ToJSON;
  finally
    Body.Free;
  end;
end;

function NewUuid: string;
begin
  Result := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').ToLower;
end;

end.
