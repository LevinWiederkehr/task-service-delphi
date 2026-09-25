unit JwtAuth;

{ Pruefung von OAuth2-Access-Tokens (JWT) fuer den Task-Service.

  WICHTIG - Stand dieses Grundgerueests: Es wird NUR die Payload dekodiert
  und die Ablaufzeit (exp) geprueft - die Signatur wird NICHT verifiziert!
  Das reicht fuer den ersten lauffaehigen Durchstich (Login->Token->Request
  funktioniert sichtbar Ende-zu-Ende), ist aber NICHT sicher: ein Angreifer
  koennte sich selbst ein beliebiges Payload basteln.

  TODO fuer die Weiterentwicklung: Signatur (RS256) gegen die JWKS von
  Keycloak pruefen, bevor irgendetwas produktiv damit laeuft. Optionen:
    - Library "Delphi-JOSE-JWT" (github.com/paolo-rossi/delphi-jose-jwt),
      unterstuetzt RS256 + JWKS.
    - Eigene Pruefung wie im M321-Demo-Projekt (service-java/JwtAuth.java) -
      dort ist der Ablauf (Header dekodieren -> kid -> JWKS -> RSA-Public-Key
      -> Signatur verifizieren) bereits als Referenzimplementierung
      (in Java) vorhanden.
}

interface

uses
  System.SysUtils,
  System.JSON,
  System.NetEncoding,
  System.DateUtils;

type
  TJwtInfo = record
    UserId: string;      // "sub"-Claim - eindeutige, stabile User-ID (Task-Ownership!)
    Username: string;    // "preferred_username"-Claim - nur fuer Anzeige/Logs
    ExpiresAt: TDateTime;
  end;

{ Liest Authorization-Header, dekodiert den Token (OHNE Signaturpruefung, siehe oben)
  und prueft nur, ob er noch nicht abgelaufen ist. Gibt bei Erfolg True zurueck. }
function TryAuthenticate(const AAuthorizationHeader: string; out AInfo: TJwtInfo;
  out AError: string): Boolean;

implementation

function Base64UrlDecode(const AValue: string): TBytes;
var
  Padded: string;
begin
  Padded := AValue.Replace('-', '+').Replace('_', '/');
  while Length(Padded) mod 4 <> 0 do
    Padded := Padded + '=';
  Result := TNetEncoding.Base64.DecodeStringToBytes(Padded);
end;

function TryAuthenticate(const AAuthorizationHeader: string; out AInfo: TJwtInfo;
  out AError: string): Boolean;
const
  BearerPrefix = 'Bearer ';
var
  Token, PayloadJson: string;
  Parts: TArray<string>;
  PayloadBytes: TBytes;
  Value: TJSONValue;
  ExpSeconds: Int64;
begin
  Result := False;
  AInfo := Default(TJwtInfo);

  if not AAuthorizationHeader.StartsWith(BearerPrefix) then
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

  try
    PayloadBytes := Base64UrlDecode(Parts[1]);
    PayloadJson := TEncoding.UTF8.GetString(PayloadBytes);
  except
    on E: Exception do
    begin
      AError := 'Token-Payload konnte nicht dekodiert werden: ' + E.Message;
      Exit;
    end;
  end;

  Value := TJSONObject.ParseJSONValue(PayloadJson);
  if not (Value is TJSONObject) then
  begin
    Value.Free;
    AError := 'Token-Payload ist kein gueltiges JSON-Objekt';
    Exit;
  end;

  try
    if not TJSONObject(Value).TryGetValue<string>('sub', AInfo.UserId) then
    begin
      AError := 'Token enthaelt kein "sub"-Claim';
      Exit;
    end;
    TJSONObject(Value).TryGetValue<string>('preferred_username', AInfo.Username);

    if not TJSONObject(Value).TryGetValue<Int64>('exp', ExpSeconds) then
    begin
      AError := 'Token enthaelt kein "exp"-Claim';
      Exit;
    end;
    AInfo.ExpiresAt := UnixToDateTime(ExpSeconds, False); // False = liefert lokale Zeit direkt

    if Now >= AInfo.ExpiresAt then
    begin
      AError := 'Token ist abgelaufen';
      Exit;
    end;

    Result := True;
  finally
    Value.Free;
  end;
end;

end.
