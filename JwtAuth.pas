unit JwtAuth;

{ Pruefung von OAuth2-Access-Tokens (JWT) fuer den Task-Service - mit
  vollstaendiger Signaturpruefung, gleichwertig zum History-Service (Python):

    1. Header dekodieren -> "alg" muss RS256 sein, "kid" bestimmt den Schluessel
    2. Oeffentlichen Schluessel (n, e) aus der JWKS von Keycloak holen
       (gecacht; bei unbekanntem "kid" - z.B. nach Key-Rotation - neu laden)
    3. Signatur (RSASSA-PKCS1-v1_5 mit SHA-256) ueber "header.payload"
       verifizieren - per Windows CNG (bcrypt.dll), also ohne Fremd-Library
       und ohne OpenSSL-DLLs
    4. Claims pruefen: "iss" = erwarteter Realm, "exp" nicht abgelaufen,
       "sub" vorhanden

  Konfiguration per Umgebungsvariable:
    OIDC_JWKS_URL - Default http://localhost:8082/realms/task-mgmt/protocol/openid-connect/certs
    OIDC_ISSUER   - Default http://localhost:8082/realms/task-mgmt

  Hinweis: bcrypt.dll gibt es nur unter Windows. Fuer einen Linux-Build
  muesste VerifyRs256 z.B. ueber OpenSSL implementiert werden. }

interface

uses
  System.SysUtils;

type
  TJwtInfo = record
    UserId: string;      // "sub"-Claim - eindeutige, stabile User-ID (Task-Ownership!)
    Username: string;    // "preferred_username"-Claim - nur fuer Anzeige/Logs
    ExpiresAt: TDateTime;
  end;

procedure ConfigureJwtAuth(const AJwksUrl, AIssuer: string);

{ Prueft den Authorization-Header vollstaendig (Signatur + Claims).
  Gibt bei Erfolg True zurueck, sonst False und eine Fehlermeldung. }
function TryAuthenticate(const AAuthorizationHeader: string; out AInfo: TJwtInfo;
  out AError: string): Boolean;

implementation

uses
  Winapi.Windows,
  System.JSON,
  System.NetEncoding,
  System.DateUtils,
  System.Hash,
  System.SyncObjs,
  System.Generics.Collections,
  IdHTTP;

{ --- Windows CNG (bcrypt.dll), nur die benoetigten Funktionen --- }

type
  NTSTATUS = Integer;
  BCRYPT_HANDLE = Pointer;

  BCRYPT_RSAKEY_BLOB = record
    Magic: ULONG;
    BitLength: ULONG;
    cbPublicExp: ULONG;
    cbModulus: ULONG;
    cbPrime1: ULONG;
    cbPrime2: ULONG;
  end;

  BCRYPT_PKCS1_PADDING_INFO = record
    pszAlgId: PWideChar;
  end;

const
  BCRYPT_RSAPUBLIC_MAGIC = $31415352; // 'RSA1'
  BCRYPT_PAD_PKCS1 = $00000002;
  BCryptDll = 'bcrypt.dll';

function BCryptOpenAlgorithmProvider(out phAlgorithm: BCRYPT_HANDLE; pszAlgId: PWideChar;
  pszImplementation: PWideChar; dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;
function BCryptCloseAlgorithmProvider(hAlgorithm: BCRYPT_HANDLE; dwFlags: ULONG): NTSTATUS;
  stdcall; external BCryptDll;
function BCryptImportKeyPair(hAlgorithm: BCRYPT_HANDLE; hImportKey: BCRYPT_HANDLE;
  pszBlobType: PWideChar; out phKey: BCRYPT_HANDLE; pbInput: PByte; cbInput: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;
function BCryptDestroyKey(hKey: BCRYPT_HANDLE): NTSTATUS; stdcall; external BCryptDll;
function BCryptVerifySignature(hKey: BCRYPT_HANDLE; pPaddingInfo: Pointer; pbHash: PByte;
  cbHash: ULONG; pbSignature: PByte; cbSignature: ULONG; dwFlags: ULONG): NTSTATUS;
  stdcall; external BCryptDll;

type
  TRsaPublicKey = record
    Modulus: TBytes;
    Exponent: TBytes;
  end;

var
  JwksUrl: string = 'http://localhost:8082/realms/task-mgmt/protocol/openid-connect/certs';
  ExpectedIssuer: string = 'http://localhost:8082/realms/task-mgmt';
  KeyCache: TDictionary<string, TRsaPublicKey>;
  KeyLock: TCriticalSection;
  LastJwksFetch: TDateTime;

procedure ConfigureJwtAuth(const AJwksUrl, AIssuer: string);
begin
  JwksUrl := AJwksUrl;
  ExpectedIssuer := AIssuer;
end;

function Base64UrlDecode(const AValue: string): TBytes;
var
  Padded: string;
begin
  Padded := AValue.Replace('-', '+').Replace('_', '/');
  while Length(Padded) mod 4 <> 0 do
    Padded := Padded + '=';
  Result := TNetEncoding.Base64.DecodeStringToBytes(Padded);
end;

function ParseJsonObject(const AText: string): TJSONObject;
var
  Value: TJSONValue;
begin
  Value := TJSONObject.ParseJSONValue(AText);
  if not (Value is TJSONObject) then
  begin
    Value.Free;
    raise Exception.Create('kein gueltiges JSON-Objekt');
  end;
  Result := TJSONObject(Value);
end;

{ Laedt die JWKS neu (hoechstens alle 30 s, schuetzt Keycloak vor Token mit
  erfundenen kids). Muss unter KeyLock aufgerufen werden. }
procedure RefreshJwks;
var
  Http: TIdHTTP;
  Jwks: TJSONObject;
  Keys: TJSONArray;
  Item: TJSONValue;
  Kid, Kty, N, E: string;
  Key: TRsaPublicKey;
begin
  if SecondsBetween(Now, LastJwksFetch) < 30 then
    Exit;
  LastJwksFetch := Now;

  Http := TIdHTTP.Create(nil);
  try
    Http.ConnectTimeout := 3000;
    Http.ReadTimeout := 3000;
    Jwks := ParseJsonObject(Http.Get(JwksUrl));
  finally
    Http.Free;
  end;

  try
    KeyCache.Clear;
    if Jwks.TryGetValue<TJSONArray>('keys', Keys) then
      for Item in Keys do
        if (Item is TJSONObject) and
           TJSONObject(Item).TryGetValue<string>('kid', Kid) and
           TJSONObject(Item).TryGetValue<string>('kty', Kty) and (Kty = 'RSA') and
           TJSONObject(Item).TryGetValue<string>('n', N) and
           TJSONObject(Item).TryGetValue<string>('e', E) then
        begin
          Key.Modulus := Base64UrlDecode(N);
          Key.Exponent := Base64UrlDecode(E);
          KeyCache.AddOrSetValue(Kid, Key);
        end;
  finally
    Jwks.Free;
  end;
end;

function TryGetKey(const AKid: string; out AKey: TRsaPublicKey): Boolean;
begin
  KeyLock.Enter;
  try
    Result := KeyCache.TryGetValue(AKid, AKey);
    if not Result then
    begin
      RefreshJwks;
      Result := KeyCache.TryGetValue(AKid, AKey);
    end;
  finally
    KeyLock.Leave;
  end;
end;

function BitLength(const ABytes: TBytes): Cardinal;
var
  I: Integer;
  B: Byte;
begin
  Result := 0;
  for I := 0 to High(ABytes) do
    if ABytes[I] <> 0 then
    begin
      B := ABytes[I];
      Result := Cardinal(Length(ABytes) - I - 1) * 8;
      while B <> 0 do
      begin
        Inc(Result);
        B := B shr 1;
      end;
      Exit;
    end;
end;

function VerifyRs256(const AKey: TRsaPublicKey; const ASigningInput: string;
  const ASignature: TBytes): Boolean;
var
  Alg, Key: BCRYPT_HANDLE;
  Header: BCRYPT_RSAKEY_BLOB;
  Blob, Hash: TBytes;
  Padding: BCRYPT_PKCS1_PADDING_INFO;
begin
  Result := False;
  if Length(ASignature) = 0 then
    Exit;

  Header.Magic := BCRYPT_RSAPUBLIC_MAGIC;
  Header.BitLength := BitLength(AKey.Modulus);
  Header.cbPublicExp := Length(AKey.Exponent);
  Header.cbModulus := Length(AKey.Modulus);
  Header.cbPrime1 := 0;
  Header.cbPrime2 := 0;
  // Blob-Layout: Header | Exponent (big-endian) | Modulus (big-endian)
  SetLength(Blob, SizeOf(Header) + Length(AKey.Exponent) + Length(AKey.Modulus));
  Move(Header, Blob[0], SizeOf(Header));
  Move(AKey.Exponent[0], Blob[SizeOf(Header)], Length(AKey.Exponent));
  Move(AKey.Modulus[0], Blob[SizeOf(Header) + Length(AKey.Exponent)], Length(AKey.Modulus));

  Hash := THashSHA2.GetHashBytes(ASigningInput, SHA256);
  Padding.pszAlgId := 'SHA256';

  if BCryptOpenAlgorithmProvider(Alg, 'RSA', nil, 0) <> 0 then
    raise Exception.Create('BCrypt: RSA-Provider nicht verfuegbar');
  try
    if BCryptImportKeyPair(Alg, nil, 'RSAPUBLICBLOB', Key, @Blob[0], Length(Blob), 0) <> 0 then
      raise Exception.Create('BCrypt: oeffentlicher Schluessel konnte nicht importiert werden');
    try
      Result := BCryptVerifySignature(Key, @Padding, @Hash[0], Length(Hash),
        @ASignature[0], Length(ASignature), BCRYPT_PAD_PKCS1) = 0;
    finally
      BCryptDestroyKey(Key);
    end;
  finally
    BCryptCloseAlgorithmProvider(Alg, 0);
  end;
end;

function TryAuthenticate(const AAuthorizationHeader: string; out AInfo: TJwtInfo;
  out AError: string): Boolean;
const
  BearerPrefix = 'Bearer ';
var
  Token, Alg, Kid, Issuer: string;
  Parts: TArray<string>;
  Header, Payload: TJSONObject;
  Key: TRsaPublicKey;
  ExpSeconds: Int64;
begin
  Result := False;
  AInfo := Default(TJwtInfo);

  if not AAuthorizationHeader.StartsWith(BearerPrefix, True) then
  begin
    AError := 'Fehlender oder ungueltiger Authorization-Header (Bearer-Token erforderlich)';
    Exit;
  end;

  Token := AAuthorizationHeader.Substring(Length(BearerPrefix)).Trim;
  Parts := Token.Split(['.']);
  if Length(Parts) <> 3 then
  begin
    AError := 'Token hat kein gueltiges JWT-Format (erwartet: header.payload.signature)';
    Exit;
  end;

  Header := nil;
  Payload := nil;
  try
    try
      Header := ParseJsonObject(TEncoding.UTF8.GetString(Base64UrlDecode(Parts[0])));
      Payload := ParseJsonObject(TEncoding.UTF8.GetString(Base64UrlDecode(Parts[1])));
    except
      on E: Exception do
      begin
        AError := 'Token konnte nicht dekodiert werden: ' + E.Message;
        Exit;
      end;
    end;

    // 1. Algorithmus fest vorgeben - nie dem Token vertrauen ("alg": "none" etc.)
    if not Header.TryGetValue<string>('alg', Alg) or (Alg <> 'RS256') then
    begin
      AError := 'Nicht unterstuetzter Signatur-Algorithmus (erwartet RS256)';
      Exit;
    end;
    if not Header.TryGetValue<string>('kid', Kid) then
    begin
      AError := 'Token-Header enthaelt kein "kid"';
      Exit;
    end;

    // 2. + 3. Schluessel holen und Signatur pruefen
    try
      if not TryGetKey(Kid, Key) then
      begin
        AError := 'Kein passender Schluessel (kid) in der JWKS gefunden';
        Exit;
      end;
      if not VerifyRs256(Key, Parts[0] + '.' + Parts[1], Base64UrlDecode(Parts[2])) then
      begin
        AError := 'Token-Signatur ist ungueltig';
        Exit;
      end;
    except
      on E: Exception do
      begin
        AError := 'Token konnte nicht geprueft werden (JWKS nicht erreichbar?): ' + E.Message;
        Exit;
      end;
    end;

    // 4. Claims
    if not Payload.TryGetValue<string>('iss', Issuer) or (Issuer <> ExpectedIssuer) then
    begin
      AError := 'Token stammt nicht vom erwarteten Issuer';
      Exit;
    end;
    if not Payload.TryGetValue<string>('sub', AInfo.UserId) or (AInfo.UserId = '') then
    begin
      AError := 'Token enthaelt kein "sub"-Claim';
      Exit;
    end;
    Payload.TryGetValue<string>('preferred_username', AInfo.Username);
    if not Payload.TryGetValue<Int64>('exp', ExpSeconds) then
    begin
      AError := 'Token enthaelt kein "exp"-Claim';
      Exit;
    end;
    AInfo.ExpiresAt := UnixToDateTime(ExpSeconds, True);
    if DateTimeToUnix(Now, False) >= ExpSeconds then
    begin
      AError := 'Token ist abgelaufen';
      Exit;
    end;

    Result := True;
  finally
    Header.Free;
    Payload.Free;
  end;
end;

initialization
  KeyCache := TDictionary<string, TRsaPublicKey>.Create;
  KeyLock := TCriticalSection.Create;
  LastJwksFetch := 0;

finalization
  KeyLock.Free;
  KeyCache.Free;

end.
