unit TaskModel;

{ Datenmodell + In-Memory-Speicher fuer Aufgaben. Bewusst als einfachste
  moegliche Persistenz gehalten (TODO fuer die Weiterentwicklung: durch eine
  echte Datenbank ersetzen, z.B. FireDAC + SQLite). Der Store ist
  Thread-sicher (TCriticalSection), weil Indys HTTP-Server Requests parallel
  auf mehreren Threads verarbeitet. }

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  System.SyncObjs;

type
  TTaskStatus = (tsOpen, tsDone);

  TTask = class
  public
    Id: string;
    OwnerUserId: string;
    Title: string;
    Description: string;
    Status: TTaskStatus;
    CreatedAt: TDateTime;
    UpdatedAt: TDateTime;
  end;

  { Liefert einen Task per Referenz/Klon - Aufrufer duerfen die Liste nicht
    behalten, sie ist nur fuer die Dauer des Requests gueltig. }
  TTaskStore = class
  private
    FLock: TCriticalSection;
    FTasks: TObjectList<TTask>;
    FNextId: Int64;
  public
    constructor Create;
    destructor Destroy; override;

    function Add(const AOwnerUserId, ATitle, ADescription: string): TTask;
    function ListByOwner(const AOwnerUserId: string): TArray<TTask>;
    function FindByIdAndOwner(const AId, AOwnerUserId: string): TTask;
    function Update(const AId, AOwnerUserId: string; const ATitle, ADescription: string;
      AHasTitle, AHasDescription: Boolean; AStatus: TTaskStatus; AHasStatus: Boolean): TTask;
    function Delete(const AId, AOwnerUserId: string): Boolean;
  end;

function StatusToString(AStatus: TTaskStatus): string;
function StringToStatus(const AValue: string; out AStatus: TTaskStatus): Boolean;

implementation

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

{ TTaskStore }

constructor TTaskStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTasks := TObjectList<TTask>.Create(True);
  FNextId := 0;
end;

destructor TTaskStore.Destroy;
begin
  FTasks.Free;
  FLock.Free;
  inherited Destroy;
end;

function TTaskStore.Add(const AOwnerUserId, ATitle, ADescription: string): TTask;
begin
  FLock.Enter;
  try
    Inc(FNextId);
    Result := TTask.Create;
    Result.Id := IntToStr(FNextId);
    Result.OwnerUserId := AOwnerUserId;
    Result.Title := ATitle;
    Result.Description := ADescription;
    Result.Status := tsOpen;
    Result.CreatedAt := Now;
    Result.UpdatedAt := Result.CreatedAt;
    FTasks.Add(Result);
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.ListByOwner(const AOwnerUserId: string): TArray<TTask>;
var
  Matches: TList<TTask>;
  Item: TTask;
begin
  FLock.Enter;
  try
    Matches := TList<TTask>.Create;
    try
      for Item in FTasks do
        if Item.OwnerUserId = AOwnerUserId then
          Matches.Add(Item);
      Result := Matches.ToArray;
    finally
      Matches.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.FindByIdAndOwner(const AId, AOwnerUserId: string): TTask;
var
  Item: TTask;
begin
  Result := nil;
  FLock.Enter;
  try
    for Item in FTasks do
      if (Item.Id = AId) and (Item.OwnerUserId = AOwnerUserId) then
      begin
        Result := Item;
        Break;
      end;
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.Update(const AId, AOwnerUserId: string; const ATitle, ADescription: string;
  AHasTitle, AHasDescription: Boolean; AStatus: TTaskStatus; AHasStatus: Boolean): TTask;
begin
  FLock.Enter;
  try
    Result := FindByIdAndOwner(AId, AOwnerUserId);
    if Result = nil then
      Exit;
    if AHasTitle then
      Result.Title := ATitle;
    if AHasDescription then
      Result.Description := ADescription;
    if AHasStatus then
      Result.Status := AStatus;
    Result.UpdatedAt := Now;
  finally
    FLock.Leave;
  end;
end;

function TTaskStore.Delete(const AId, AOwnerUserId: string): Boolean;
var
  Item: TTask;
begin
  FLock.Enter;
  try
    Item := FindByIdAndOwner(AId, AOwnerUserId);
    Result := Item <> nil;
    if Result then
      FTasks.Remove(Item);
  finally
    FLock.Leave;
  end;
end;

end.
