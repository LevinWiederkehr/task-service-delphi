unit TaskStore;

{ Persistenz des Task-Service: SQLite ueber FireDAC (statisch gelinkt, keine
  DLL noetig). Ersetzt den frueheren In-Memory-Store - Aufgaben ueberleben
  jetzt einen Neustart.

  Transactional Outbox: jede Aenderung an einer Aufgabe schreibt in DERSELBEN
  Transaktion das zugehoerige Task-Event in die Tabelle "outbox". Entweder
  beides wird gespeichert oder nichts - es kann also weder ein Event ohne
  Aenderung noch eine Aenderung ohne Event entstehen, auch wenn RabbitMQ
  gerade nicht erreichbar ist. Versendet werden die Events asynchron vom
  TOutboxPublisher (OutboxPublisher.pas); der HTTP-Request wartet nie auf
  den Broker.

  Thread-Sicherheit: Indy verarbeitet Requests parallel. Jede Operation holt
  sich eine eigene Verbindung aus dem FireDAC-Pool; SQLite laeuft im
  WAL-Modus mit Busy-Timeout. Gelesene Aufgaben werden als Record (Kopie)
  zurueckgegeben, nie als geteilte Objekt-Referenz.

  Konfiguration: DB_PATH (Default: tasks.db neben der .exe). }

interface

uses
  System.SysUtils,
  System.SyncObjs,
  TaskModel;

type
  TOutboxEntry = record
    EventId: string;
    Payload: string;
    CorrelationId: string;
    Attempts: Integer;
  end;

  TTaskStore = class
  private
    FOutboxSignal: TEvent;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;

    function IsHealthy: Boolean;

    function CreateTask(const AOwnerUserId, ATitle, ADescription, ACorrelationId: string): TTask;
    function ListByOwner(const AOwnerUserId: string): TArray<TTask>;
    function FindByIdAndOwner(const AId, AOwnerUserId: string; out ATask: TTask): Boolean;
    function UpdateTask(const AId, AOwnerUserId: string; const ATitle, ADescription: string;
      AHasTitle, AHasDescription: Boolean; AStatus: TTaskStatus; AHasStatus: Boolean;
      const ACorrelationId: string; out ATask: TTask): Boolean;
    function DeleteTask(const AId, AOwnerUserId, ACorrelationId: string): Boolean;

    function FetchPendingOutbox(ALimit: Integer): TArray<TOutboxEntry>;
    procedure MarkOutboxSent(const AEventId: string);
    procedure MarkOutboxFailed(const AEventId, AError: string);
    function PendingOutboxCount: Integer;

    { Wird nach jedem Commit mit Outbox-Eintrag gesetzt - weckt den Publisher sofort. }
    property OutboxSignal: TEvent read FOutboxSignal;
  end;

implementation

uses
  System.Classes,
  System.DateUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Param,
  FireDAC.Stan.Pool,
  FireDAC.DApt,
  FireDAC.Phys,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteWrapper.Stat,
  FireDAC.ConsoleUI.Wait,
  FireDAC.Comp.Client,
  AppLog;

const
  ConnDefName = 'TaskDB';

function OpenConnection: TFDConnection;
begin
  Result := TFDConnection.Create(nil);
  try
    Result.ConnectionDefName := ConnDefName;
    Result.Connected := True;
  except
    Result.Free;
    raise;
  end;
end;

function ToDbTime(AValue: TDateTime): string;
begin
  Result := DateToISO8601(AValue, True);
end;

function FromDbTime(const AValue: string): TDateTime;
begin
  Result := ISO8601ToDate(AValue, True);
end;

function ReadTask(AQuery: TFDQuery): TTask;
var
  Status: TTaskStatus;
begin
  Result.Id := AQuery.FieldByName('id').AsString;
  Result.OwnerUserId := AQuery.FieldByName('owner_user_id').AsString;
  Result.Title := AQuery.FieldByName('title').AsString;
  Result.Description := AQuery.FieldByName('description').AsString;
  if not StringToStatus(AQuery.FieldByName('status').AsString, Status) then
    Status := tsOpen;
  Result.Status := Status;
  Result.CreatedAt := FromDbTime(AQuery.FieldByName('created_at').AsString);
  Result.UpdatedAt := FromDbTime(AQuery.FieldByName('updated_at').AsString);
end;

function QueryTask(AConn: TFDConnection; const AId, AOwnerUserId: string; out ATask: TTask): Boolean;
var
  Query: TFDQuery;
begin
  Query := TFDQuery.Create(nil);
  try
    Query.Connection := AConn;
    Query.Open('SELECT * FROM tasks WHERE id = :id AND owner_user_id = :owner',
      [StrToInt64Def(AId, -1), AOwnerUserId]);
    Result := not Query.IsEmpty;
    if Result then
      ATask := ReadTask(Query);
  finally
    Query.Free;
  end;
end;

procedure AddToOutbox(AConn: TFDConnection; AEventType: TTaskEventType; const ATask: TTask;
  const AEventStatus, ACorrelationId: string);
var
  EventId: string;
  OccurredAt: TDateTime;
begin
  EventId := NewUuid;
  OccurredAt := NowUtc;
  AConn.ExecSQL(
    'INSERT INTO outbox (event_id, payload, correlation_id, created_at) VALUES (:id, :payload, :corr, :created)',
    [EventId, BuildTaskEventJson(EventId, AEventType, ATask, AEventStatus, ACorrelationId, OccurredAt),
     ACorrelationId, ToDbTime(OccurredAt)]);
end;

{ TTaskStore }

constructor TTaskStore.Create(const ADatabasePath: string);
var
  Params: TStringList;
  Conn: TFDConnection;
begin
  inherited Create;
  FOutboxSignal := TEvent.Create(nil, False, False, '');

  Params := TStringList.Create;
  try
    Params.Values['Database'] := ADatabasePath;
    Params.Values['OpenMode'] := 'CreateUTF8';
    Params.Values['JournalMode'] := 'WAL';
    Params.Values['LockingMode'] := 'Normal';
    Params.Values['Synchronous'] := 'Normal';
    Params.Values['BusyTimeout'] := '10000';
    Params.Values['StringFormat'] := 'Unicode';
    Params.Values['Pooled'] := 'True';
    Params.Values['POOL_MaximumItems'] := '50';
    FDManager.AddConnectionDef(ConnDefName, 'SQLite', Params);
  finally
    Params.Free;
  end;
  FDManager.Active := True;

  Conn := OpenConnection;
  try
    Conn.ExecSQL(
      'CREATE TABLE IF NOT EXISTS tasks (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  owner_user_id TEXT NOT NULL,' +
      '  title TEXT NOT NULL,' +
      '  description TEXT NOT NULL DEFAULT '''',' +
      '  status TEXT NOT NULL,' +
      '  created_at TEXT NOT NULL,' +
      '  updated_at TEXT NOT NULL)');
    Conn.ExecSQL('CREATE INDEX IF NOT EXISTS ix_tasks_owner ON tasks(owner_user_id)');
    Conn.ExecSQL(
      'CREATE TABLE IF NOT EXISTS outbox (' +
      '  event_id TEXT PRIMARY KEY,' +
      '  payload TEXT NOT NULL,' +
      '  correlation_id TEXT NOT NULL DEFAULT '''',' +
      '  created_at TEXT NOT NULL,' +
      '  sent_at TEXT,' +
      '  attempts INTEGER NOT NULL DEFAULT 0,' +
      '  last_error TEXT)');
    Conn.ExecSQL('CREATE INDEX IF NOT EXISTS ix_outbox_pending ON outbox(sent_at, created_at)');
  finally
    Conn.Free;
  end;
end;

destructor TTaskStore.Destroy;
begin
  FDManager.Close;
  FOutboxSignal.Free;
  inherited Destroy;
end;

function TTaskStore.IsHealthy: Boolean;
var
  Conn: TFDConnection;
begin
  try
    Conn := OpenConnection;
    try
      Result := Conn.ExecSQLScalar('SELECT 1') = 1;
    finally
      Conn.Free;
    end;
  except
    Result := False;
  end;
end;

function TTaskStore.CreateTask(const AOwnerUserId, ATitle, ADescription, ACorrelationId: string): TTask;
var
  Conn: TFDConnection;
begin
  Result.OwnerUserId := AOwnerUserId;
  Result.Title := ATitle;
  Result.Description := ADescription;
  Result.Status := tsOpen;
  Result.CreatedAt := NowUtc;
  Result.UpdatedAt := Result.CreatedAt;

  Conn := OpenConnection;
  try
    Conn.StartTransaction;
    try
      Conn.ExecSQL(
        'INSERT INTO tasks (owner_user_id, title, description, status, created_at, updated_at) ' +
        'VALUES (:owner, :title, :descr, :status, :created, :updated)',
        [AOwnerUserId, ATitle, ADescription, StatusToString(Result.Status),
         ToDbTime(Result.CreatedAt), ToDbTime(Result.UpdatedAt)]);
      Result.Id := VarToStr(Conn.ExecSQLScalar('SELECT last_insert_rowid()'));
      AddToOutbox(Conn, etCreated, Result, StatusToString(Result.Status), ACorrelationId);
      Conn.Commit;
    except
      Conn.Rollback;
      raise;
    end;
  finally
    Conn.Free;
  end;
  FOutboxSignal.SetEvent;
end;

function TTaskStore.ListByOwner(const AOwnerUserId: string): TArray<TTask>;
var
  Conn: TFDConnection;
  Query: TFDQuery;
  Items: TList<TTask>;
begin
  Conn := OpenConnection;
  Query := TFDQuery.Create(nil);
  Items := TList<TTask>.Create;
  try
    Query.Connection := Conn;
    Query.Open('SELECT * FROM tasks WHERE owner_user_id = :owner ORDER BY id', [AOwnerUserId]);
    while not Query.Eof do
    begin
      Items.Add(ReadTask(Query));
      Query.Next;
    end;
    Result := Items.ToArray;
  finally
    Items.Free;
    Query.Free;
    Conn.Free;
  end;
end;

function TTaskStore.FindByIdAndOwner(const AId, AOwnerUserId: string; out ATask: TTask): Boolean;
var
  Conn: TFDConnection;
begin
  Conn := OpenConnection;
  try
    Result := QueryTask(Conn, AId, AOwnerUserId, ATask);
  finally
    Conn.Free;
  end;
end;

function TTaskStore.UpdateTask(const AId, AOwnerUserId: string; const ATitle, ADescription: string;
  AHasTitle, AHasDescription: Boolean; AStatus: TTaskStatus; AHasStatus: Boolean;
  const ACorrelationId: string; out ATask: TTask): Boolean;
var
  Conn: TFDConnection;
  EventType: TTaskEventType;
  WasDone: Boolean;
begin
  Conn := OpenConnection;
  try
    Conn.StartTransaction;
    try
      Result := QueryTask(Conn, AId, AOwnerUserId, ATask);
      if not Result then
      begin
        Conn.Rollback;
        Exit;
      end;

      WasDone := ATask.Status = tsDone;
      if AHasTitle then
        ATask.Title := ATitle;
      if AHasDescription then
        ATask.Description := ADescription;
      if AHasStatus then
        ATask.Status := AStatus;
      ATask.UpdatedAt := NowUtc;

      Conn.ExecSQL(
        'UPDATE tasks SET title = :title, description = :descr, status = :status, updated_at = :updated ' +
        'WHERE id = :id AND owner_user_id = :owner',
        [ATask.Title, ATask.Description, StatusToString(ATask.Status), ToDbTime(ATask.UpdatedAt),
         StrToInt64(ATask.Id), AOwnerUserId]);

      // COMPLETED nur beim Uebergang OPEN -> DONE, sonst ein normales UPDATED.
      if AHasStatus and (AStatus = tsDone) and not WasDone then
        EventType := etCompleted
      else
        EventType := etUpdated;
      AddToOutbox(Conn, EventType, ATask, StatusToString(ATask.Status), ACorrelationId);
      Conn.Commit;
    except
      Conn.Rollback;
      raise;
    end;
  finally
    Conn.Free;
  end;
  FOutboxSignal.SetEvent;
end;

function TTaskStore.DeleteTask(const AId, AOwnerUserId, ACorrelationId: string): Boolean;
var
  Conn: TFDConnection;
  Existing: TTask;
begin
  Conn := OpenConnection;
  try
    Conn.StartTransaction;
    try
      Result := QueryTask(Conn, AId, AOwnerUserId, Existing);
      if not Result then
      begin
        Conn.Rollback;
        Exit;
      end;
      Conn.ExecSQL('DELETE FROM tasks WHERE id = :id AND owner_user_id = :owner',
        [StrToInt64(Existing.Id), AOwnerUserId]);
      AddToOutbox(Conn, etDeleted, Existing, 'DELETED', ACorrelationId);
      Conn.Commit;
    except
      Conn.Rollback;
      raise;
    end;
  finally
    Conn.Free;
  end;
  FOutboxSignal.SetEvent;
end;

function TTaskStore.FetchPendingOutbox(ALimit: Integer): TArray<TOutboxEntry>;
var
  Conn: TFDConnection;
  Query: TFDQuery;
  Items: TList<TOutboxEntry>;
  Entry: TOutboxEntry;
begin
  Conn := OpenConnection;
  Query := TFDQuery.Create(nil);
  Items := TList<TOutboxEntry>.Create;
  try
    Query.Connection := Conn;
    // Reihenfolge = Entstehungsreihenfolge, damit Events pro Aufgabe geordnet bleiben.
    Query.Open('SELECT event_id, payload, correlation_id, attempts FROM outbox ' +
      'WHERE sent_at IS NULL ORDER BY created_at, rowid LIMIT :lim', [ALimit]);
    while not Query.Eof do
    begin
      Entry.EventId := Query.FieldByName('event_id').AsString;
      Entry.Payload := Query.FieldByName('payload').AsString;
      Entry.CorrelationId := Query.FieldByName('correlation_id').AsString;
      Entry.Attempts := Query.FieldByName('attempts').AsInteger;
      Items.Add(Entry);
      Query.Next;
    end;
    Result := Items.ToArray;
  finally
    Items.Free;
    Query.Free;
    Conn.Free;
  end;
end;

procedure TTaskStore.MarkOutboxSent(const AEventId: string);
var
  Conn: TFDConnection;
begin
  Conn := OpenConnection;
  try
    Conn.ExecSQL('UPDATE outbox SET sent_at = :sent, attempts = attempts + 1, last_error = NULL ' +
      'WHERE event_id = :id', [ToDbTime(NowUtc), AEventId]);
  finally
    Conn.Free;
  end;
end;

procedure TTaskStore.MarkOutboxFailed(const AEventId, AError: string);
var
  Conn: TFDConnection;
begin
  Conn := OpenConnection;
  try
    Conn.ExecSQL('UPDATE outbox SET attempts = attempts + 1, last_error = :err WHERE event_id = :id',
      [AError, AEventId]);
  finally
    Conn.Free;
  end;
end;

function TTaskStore.PendingOutboxCount: Integer;
var
  Conn: TFDConnection;
begin
  Conn := OpenConnection;
  try
    Result := Conn.ExecSQLScalar('SELECT COUNT(*) FROM outbox WHERE sent_at IS NULL');
  finally
    Conn.Free;
  end;
end;

end.
