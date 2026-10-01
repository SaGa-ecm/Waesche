# APEX-Schnittstellen-Adapter v0.5 â€“ Entwurf (NICHT angewendet)
# Keine Git-/GitHub-Aktionen, keine Installation, keine Zugangsdaten.
# PowerShell 5.1-kompatibel.
#
# ==========================================================================
# VERBINDLICHE GRENZEN DIESES ADAPTERS (Abgrenzung zum allgemeinen v2-Schema)
# ==========================================================================
# 1. ZEITSTEMPEL: Der Adapter beschraenkt ISO-8601-Zeitstempel zusaetzlich auf
#    die Jahre 2000-2200 (Assert-IsoZeitstempel). Das Schema tut das nicht.
# 2. ZAHLEN: Numerische Felder muessen nach dem JSON-Parsing als Int32 oder
#    Int64 vorliegen (Test-IstZahl). Das Schema erlaubt auch mathematisch
#    ganzzahlige Gleitkommadarstellungen wie 2.0; der Adapter lehnt sie ab.
#    Schema-Gueltigkeit allein garantiert deshalb keine Annahme.
# 3. ZUSAETZLICHE PRUEFUNGEN DES ADAPTERS (ueber das vorliegende Schema hinausgehend):
#    Handoff-ID-Reproduzierbarkeit, Anlagen- und Berichtshashkonsistenz,
#    Paketbestand, Groessenvergleich, Kontextbindung, Kollisionsvorpruefung.
# 4. DATEIPFADVERGLEICHE setzen eine case-insensitive Dateisystemumgebung
#    voraus. Sie loesen keine Dateialias-Fragen wie Kurz-/Langnamen auf.
# 5. PFADRAUM: Nur vollqualifizierte lokale Windows-Laufwerkspfade.
#    UNC-, Geraete- und Namespace-Pfade werden abgewiesen.
# 6. BETRIEBSVORAUSSETZUNGEN: Wurzel, Vorfahren, Bau-, Paket- und
#    Sperrverzeichnisse sind gegen Aenderungen durch nicht vertrauenswuerdige
#    Akteure geschuetzt; alle kooperierenden Zugriffe nutzen dieselbe
#    Sperrkonvention. Zugeordnete Netzlaufwerke sind NICHT unterstuetzt.
#    Ohne bestaetigte Voraussetzung liegt die Umgebung ausserhalb des
#    unterstuetzten Betriebsmodells.
# 7. NICHT IMPLEMENTIERT: Recovery (Restore-Paketstatus wirft ab) und der
#    verifizierte Empfangsrueckkanal (Receive-Bestaetigung wirft ab).
#    'empfangen_bestaetigt' wird nicht vergeben und nicht anerkannt.
# 8. TOCTOU-REST: Pfadpruefungen und Dateisystemoperationen sind nicht
#    atomar. FileShare.None schuetzt die Verzeichnisstruktur nicht.
# 9. KEINE LAUFZEITFREIGABE: Dieser Stand ist ein statisch gepruefter
#    Textentwurf. Anwendung und produktiver Betrieb sind nicht freigegeben.

[CmdletBinding()]
param(
    [ValidateSet('Auftrag','Receive','Wiederbereitstellen')][string]$Mode,
    [string]$Eingabe,
    [string]$Kennung,
    [string]$HandoffId,
    [string]$Abschluss,
    [string]$ProjektId,
    [string]$Profil,
    [string]$EmpfaengerKanal,
    [string]$EmpfaengerUnterhaltung,
    [AllowNull()]$SessionId,
    [AllowNull()]$TurnId,
    [string]$AbsenderKontext = 'apex-schnittstelle-adapter',
    [string]$Ergebnis
)

$Base = 'C:\Users\Admin\waesche-repo\.apex-schnittstelle'
$ErrorActionPreference = 'Stop'
$StatusGueltig = @('vorbereitet','gespeichert_verifiziert','lokal_bereitgestellt','empfangen_bestaetigt')
$ZulaessigeZusatzdateien = @('status.json','bestaetigung.json','bestaetigung-ref.json')
$KonstanteErfassung = 'alle Dateien im Arbeitsordner einschliesslich versteckter und System-Dateien, ausgenommen der uebernommene Abschlussbericht'

# --------------------------------------------------------------------------
# Typ- und Feldpruefer
# --------------------------------------------------------------------------

function Test-IstZahl { param($Wert) return ($Wert -is [int]) -or ($Wert -is [long]) }
function Test-IstText { param($Wert) return ($Wert -is [string]) }
function Test-IstTextOderNull { param($Wert)
    return ($null -eq $Wert) -or ($Wert -is [string]) }
function Test-IstJsonObjekt { param($Wert)
    return ($null -ne $Wert) -and ($Wert -is [System.Management.Automation.PSCustomObject]) }
function Test-IstJsonArray { param($Wert)
    return ($Wert -is [System.Array]) -or (($Wert -is [System.Collections.IList]) -and -not ($Wert -is [string])) }
function Test-IstFeld { param($Objekt, [string]$Name)
    if (-not (Test-IstJsonObjekt $Objekt)) { return $false }
    foreach ($p in @($Objekt.PSObject.Properties.Name)) {
        if ([string]::Equals($p, $Name, [System.StringComparison]::Ordinal)) { return $true } }
    return $false }
function Test-FeldVorhanden { param($Objekt, [string]$Name)
    return (Test-IstFeld -Objekt $Objekt -Name $Name) }
function Test-IstHex { param($Wert, [int]$Laenge)
    if ($null -eq $Wert) { return $false }
    if (-not ($Wert -is [string])) { return $false }
    return ($Wert -cmatch ('\A[a-f0-9]{' + $Laenge + '}\z')) }

function Assert-JsonObjekt { param($Wert, [string]$Ort)
    if (-not (Test-IstJsonObjekt $Wert)) { throw "$Ort : kein JSON-Objekt." } }
function Assert-Pflichtfelder { param($Objekt, [string[]]$Pflicht, [string]$Ort)
    if (-not (Test-IstJsonObjekt $Objekt)) { throw "$Ort : kein JSON-Objekt." }
    foreach ($f in $Pflicht) {
        if (-not (Test-FeldVorhanden -Objekt $Objekt -Name $f)) { throw "$Ort : Pflichtfeld '$f' fehlt." } } }
function Assert-NurFelder { param($Objekt, [string[]]$Erlaubt, [string]$Ort)
    if (-not (Test-IstJsonObjekt $Objekt)) { throw "$Ort : kein JSON-Objekt." }
    foreach ($p in @($Objekt.PSObject.Properties.Name)) {
        $ok = $false
        foreach ($e in $Erlaubt) { if ([string]::Equals($p, $e, [System.StringComparison]::Ordinal)) { $ok = $true; break } }
        if (-not $ok) { throw "$Ort : unbekanntes Feld '$p'." } } }
function Assert-Text { param($Wert, [string]$Ort, [bool]$NichtLeer = $true)
    if (-not ($Wert -is [string])) { throw "$Ort : kein String." }
    if ($NichtLeer -and $Wert.Length -eq 0) { throw "$Ort : leer." } }
function Assert-TextOderNull { param($Wert, [string]$Ort)
    if (-not (Test-IstTextOderNull $Wert)) { throw "$Ort : weder String noch null." } }
function Assert-StringOderNull { param($Wert, [string]$Ort)
    if ($null -eq $Wert) { return }
    if (-not ($Wert -is [string])) { throw "$Ort : nur String oder null zulaessig (ist $($Wert.GetType().Name))." } }
function Test-TextGleichOrdinal { param($A, $B)
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or  $null -eq $B) { return $false }
    if (-not ($A -is [string]) -or -not ($B -is [string])) { return $false }
    return [string]::Equals($A, $B, [System.StringComparison]::Ordinal) }
function Assert-Konstante { param($Wert, [string]$Erwartet, [string]$Ort)
    if (-not (Test-IstText $Wert)) { throw "$Ort : kein String." }
    if (-not (Test-TextGleichOrdinal -A $Wert -B $Erwartet)) { throw "$Ort : muss '$Erwartet' sein." } }
function Assert-EnumWert { param($Wert, [string[]]$Erlaubt, [string]$Ort)
    if (-not (Test-IstText $Wert)) { throw "$Ort : kein String." }
    $treffer = $false
    foreach ($e in $Erlaubt) { if ([string]::Equals($Wert, $e, [System.StringComparison]::Ordinal)) { $treffer = $true; break } }
    if (-not $treffer) { throw "$Ort : unzulaessiger Wert '$Wert'." } }
function Assert-Wert { param($Wert, $Erwartet, [string]$Ort)
    if ((Test-IstZahl $Erwartet) -or (Test-IstZahl $Wert)) {
        if ($null -eq $Wert) { throw "$Ort : keine Zahl (ist null)." }
        if (-not (Test-IstZahl $Wert)) { throw "$Ort : keine Zahl (ist $($Wert.GetType().Name))." }
        if (-not (Test-IstZahl $Erwartet)) { throw "$Ort : Erwartungswert keine Zahl (ist $($Erwartet.GetType().Name))." }
        if ([int64]$Wert -ne [int64]$Erwartet) { throw "$Ort : Wert '$Wert' statt '$Erwartet'." }
        return }
    if (-not (Test-TextGleichOrdinal -A $Wert -B $Erwartet)) { throw "$Ort : Wert '$Wert' statt '$Erwartet'." } }
function Assert-StatusUebergang { param([string]$Von, [string]$Nach)
    $tabelle = @{
        'vorbereitet'             = @('gespeichert_verifiziert')
        'gespeichert_verifiziert' = @('gespeichert_verifiziert','lokal_bereitgestellt')
        'lokal_bereitgestellt'    = @('lokal_bereitgestellt','gespeichert_verifiziert') }
    $nachListe = $null
    foreach ($k in @($tabelle.Keys)) {
        if ([string]::Equals($k, $Von, [System.StringComparison]::Ordinal)) { $nachListe = $tabelle[$k]; break } }
    if ($null -eq $nachListe) { throw "Unbekannter Ausgangsstatus: '$Von'" }
    if (Test-TextGleichOrdinal -A $Nach -B 'empfangen_bestaetigt') { throw "Zielstatus 'empfangen_bestaetigt' ist gesperrt (kein verifizierter Rueckkanal)." }
    $ok = $false
    foreach ($e in $nachListe) { if ([string]::Equals($Nach,$e,[System.StringComparison]::Ordinal)) { $ok = $true; break } }
    if (-not $ok) { throw "Unzulaessiger Statusuebergang: '$Von' -> '$Nach'" } }
function Assert-OptionalHex { param($Ist, [string]$Name, [int]$Laenge, $Vergleich, [string]$Ort)
    Assert-JsonObjekt -Wert $Ist -Ort $Ort
    if (-not (Test-FeldVorhanden -Objekt $Ist -Name $Name)) { return }
    if ($null -eq $Ist.$Name) { throw "$Ort : '$Name' darf nicht null sein (nur fehlen)." }
    if (-not (Test-IstHex $Ist.$Name $Laenge)) { throw "$Ort : '$Name' ungueltig." }
    if ($null -ne $Vergleich -and -not (Test-TextGleichOrdinal -A $Ist.$Name -B $Vergleich)) { throw "$Ort : '$Name' stimmt nicht mit '$Vergleich' ueberein." } }
function Assert-IsoZeitstempel { param($Wert, [string]$Ort)
    if (-not ($Wert -is [string])) { throw "$Ort : kein String." }
    if ($Wert -cnotmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z') {
        throw "$Ort : keine ISO-8601-Form ('$Wert')." }
    $dt = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParse($Wert, [Globalization.CultureInfo]::InvariantCulture,
                                     [Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)
    if (-not $ok) { throw "$Ort : semantisch ungueltiges Datum ('$Wert')." }
    if ($dt.Year -lt 2000 -or $dt.Year -gt 2200) { throw "$Ort : Jahr ausserhalb 2000-2200 ('$Wert')." } }

function Get-JsonObjekt { param($Wert)
    if ($null -eq $Wert) { return $null }
    if ($Wert -is [string]) { return $Wert }
    if ($Wert -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Wert.Keys) { $o[$k] = Get-JsonObjekt -Wert $Wert[$k] }
        return [PSCustomObject]$o }
    if ($Wert -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Wert.PSObject.Properties) { $o[$p.Name] = Get-JsonObjekt -Wert $p.Value }
        return [PSCustomObject]$o }
    if (($Wert -is [System.Collections.IEnumerable]) -and -not ($Wert -is [ValueType])) {
        $arr = [System.Collections.Generic.List[object]]::new()
        foreach ($x in $Wert) { $arr.Add((Get-JsonObjekt -Wert $x)) }
        return ,$arr.ToArray() }
    return $Wert }

# --------------------------------------------------------------------------
# Pfadregeln â€“ EINZIGE Quelle
# --------------------------------------------------------------------------

function Test-SichererRelPfad {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$RelPfad)
    if ([string]::IsNullOrEmpty($RelPfad)) { return $false }
    if ($RelPfad.Contains('\'))   { return $false }
    if ($RelPfad.Contains(':'))   { return $false }
    if ($RelPfad.StartsWith('/')) { return $false }
    if ($RelPfad.Contains('//'))  { return $false }
    if ($RelPfad.EndsWith('/'))   { return $false }
    if ($RelPfad -match '[\x00-\x1f\uFEFF\u2028\u2029]') { return $false }
    foreach ($seg in ($RelPfad -split '/')) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { return $false }
        if ($seg -match '[\x00-\x1f\\/:*?"<>|\uFEFF\u2028\u2029]') { return $false }
        if ($seg.EndsWith('.') -or $seg.EndsWith(' ')) { return $false }
        if ($seg -match '^(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\.|$)') { return $false }
    }
    return $true }

function Assert-ImBereich { param(
        [Parameter(Mandatory=$true)][string]$Pfad,
        [Parameter(Mandatory=$true)][string]$Wurzel,
        [switch]$NurNachfahre)
    if ([string]::IsNullOrWhiteSpace($Wurzel)) { throw "Bereichswurzel fehlt." }
    $voll = [IO.Path]::GetFullPath($Pfad)
    $wAbs = [IO.Path]::GetFullPath($Wurzel).TrimEnd('\')
    if ([string]::IsNullOrEmpty($wAbs)) { throw "Bereichswurzel ungueltig: '$Wurzel'." }
    # Einschliessender Vertrag: die Wurzel selbst ist zulaessig, sofern kein Nachfahre verlangt wird.
    if ([string]::Equals($voll.TrimEnd('\'), $wAbs, [StringComparison]::OrdinalIgnoreCase)) {
        if ($NurNachfahre) { throw "Pfad ist die Wurzel selbst, echter Nachfahre erforderlich: $Pfad" }
        return $voll }
    # Laufwerkswurzel behaelt ihren Separator, sonst wird einer angehaengt.
    $w = $wAbs + '\'
    if (-not $voll.StartsWith($w, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pfad ausserhalb der freigegebenen Wurzel: $Pfad" }
    return $voll }

function Assert-LaufwerkspfadForm { param(
        [Parameter(Mandatory=$true)][string]$Pfad,
        [string]$Ort = 'Pfad')
    if ([string]::IsNullOrWhiteSpace($Pfad)) { throw "$Ort : leer." }
    # Schritt 1: Form der EINGABE pruefen - relative Werte werden nicht kontextabhaengig aufgeloest.
    if ($Pfad.StartsWith('\\')) {
        throw "$Ort : UNC-, Geraete- oder Namespace-Pfade werden nicht unterstuetzt: '$Pfad'." }
    $einRoot = [IO.Path]::GetPathRoot($Pfad)
    if ($null -eq $einRoot -or $einRoot.Length -ne 3 -or $einRoot[1] -ne ':' -or $einRoot[2] -ne '\') {
        throw "$Ort : Eingabe ist kein vollqualifizierter Laufwerkspfad (Laufwerk:\): '$Pfad'." }
    if (-not [char]::IsLetter($einRoot[0])) { throw "$Ort : ungueltiger Laufwerksbuchstabe: '$Pfad'." }
    # Schritt 2: normalisieren und erneut pruefen.
    $abs = [IO.Path]::GetFullPath($Pfad)
    if ($abs.StartsWith('\\')) {
        throw "$Ort : UNC-, Geraete- oder Namespace-Pfade werden nicht unterstuetzt: '$Pfad'." }
    $root = [IO.Path]::GetPathRoot($abs)
    if ($null -eq $root -or $root.Length -ne 3 -or $root[1] -ne ':' -or $root[2] -ne '\') {
        throw "$Ort : kein vollqualifizierter Laufwerkspfad (Laufwerk:\): '$Pfad'." }
    if (-not [char]::IsLetter($root[0])) { throw "$Ort : ungueltiger Laufwerksbuchstabe: '$Pfad'." }
    return $abs }

function Assert-KeineReparsePoints { param(
        [Parameter(Mandatory=$true)][string]$Pfad,
        [Parameter(Mandatory=$true)][string]$Wurzel)
    $voll  = [IO.Path]::GetFullPath($Pfad)
    $wVoll = [IO.Path]::GetFullPath($Wurzel)
    # Normalisierte Wurzel inkl. Laufwerksseparator behalten; nur den Vergleichswert trimmen.
    Assert-ImBereich -Pfad $voll -Wurzel $wVoll | Out-Null
    $w     = $wVoll.TrimEnd('\')
    $cur   = $voll
    while ($cur -and $cur.Length -ge $w.Length) {
        if (Test-Path -LiteralPath $cur) {
            $item = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse Point im Pfad: $cur" } }
        if ($cur -eq $w) { break }
        $parent = Split-Path -Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent } }

function Resolve-PaketPfad { param(
        [Parameter(Mandatory=$true)][string]$PaketWurzel,
        [Parameter(Mandatory=$true)][string]$RelPfad,
        [Parameter(Mandatory=$true)][string]$Bereich)
    if (-not (Test-SichererRelPfad -RelPfad $RelPfad)) { throw "Ungueltiger Paketpfad: '$RelPfad'" }
    $teile = $RelPfad -split '/'
    $voll  = [IO.Path]::GetFullPath((Join-Path -Path $PaketWurzel -ChildPath ($teile -join '\')))
    # Zentral: jedes Paketdateiziel muss echter Nachfahre seiner Paketwurzel sein.
    $voll = Assert-ImBereich -Pfad $voll -Wurzel $PaketWurzel -NurNachfahre
    $voll = Assert-ImBereich -Pfad $voll -Wurzel $Bereich
    return $voll }

function Get-DateienOhneLinks { param(
        [Parameter(Mandatory=$true)][string]$Wurzel,
        [Parameter(Mandatory=$true)][string]$Bereich)
    $stapel = New-Object System.Collections.Stack
    $stapel.Push($Wurzel)
    $ergebnis = @()
    while ($stapel.Count -gt 0) {
        $dir = $stapel.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse Point im Bestand: $($item.FullName)" }
            if ($item.PSIsContainer) { $stapel.Push($item.FullName) } else { $ergebnis += $item } } }
    foreach ($f in $ergebnis) { Assert-KeineReparsePoints -Pfad $f.FullName -Wurzel $Bereich }
    return $ergebnis }

function Write-BytesAtomar { param(
        [Parameter(Mandatory=$true)][string]$Ziel,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $dir = Split-Path -Path $Ziel -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    $tmp = Join-Path -Path $dir ('.tmp-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    try {
        if (Test-Path -LiteralPath $Ziel) {
            # PS 5.1 bindet $null beim .NET-Stringparameter zu einem LEEREN STRING, nicht zu einer
            # echten Nullreferenz; das wirft ArgumentException ('The path is not of a legal form.').
            # NullString.Value uebergibt eine echte Nullreferenz -> kein Backup, kein Bereinigungspfad.
            [IO.File]::Replace($tmp, $Ziel, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($tmp, $Ziel) } }
    finally {
        if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) } }
    return $Ziel }

function Write-NeuAtomar { param(
        [Parameter(Mandatory=$true)][string]$Ziel,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $dir = Split-Path -Path $Ziel -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    $tmp = Join-Path -Path $dir ('.tmp-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    [IO.File]::Move($tmp, $Ziel)
    return $Ziel }

# --------------------------------------------------------------------------
# Hash- und Kodierfunktionen
# --------------------------------------------------------------------------

function Get-Sha256Hex { param([Parameter(Mandatory=$true)][string]$Pfad)
    if (-not (Test-Path -LiteralPath $Pfad -PathType Leaf)) { throw "Datei nicht gefunden: $Pfad" }
    return (Get-FileHash -LiteralPath $Pfad -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-Sha256Bytes { param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try   { $h = $sha.ComputeHash($Bytes) }
    finally { $sha.Dispose() }
    return (-join ($h | ForEach-Object { $_.ToString('x2') })) }

function Get-Sha256Text { param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    return (Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))) }

function Get-LaengenKodiert { param([Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Felder)
    $teile = foreach ($f in $Felder) { "$($f.Length):$f" }
    return (($teile -join '|')) }

function Get-OrdinalSchluessel { param([Parameter(Mandatory=$true)][string]$Text)
    return (($Text.ToCharArray() | ForEach-Object { '{0:D6}' -f [int]$_ }) -join ',') }

function Get-AnlagenManifest { param($Anlagen)
    $sortiert = @(@($Anlagen) | Sort-Object -Property @{ Expression = { Get-OrdinalSchluessel -Text $_.RelPfad } })
    return (($sortiert | ForEach-Object { "$($_.RelPfad)|$($_.Groesse)|$($_.SHA256)" }) -join "`n") }

function Test-BytesGleich { param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true }

function Assert-Kennung { param([Parameter(Mandatory=$true)][string]$Wert)
    if (-not (Test-IstHex $Wert 32)) { throw "Ungueltige Auftragskennung (erwartet 32 Hex-Kleinbuchstaben): '$Wert'" }
    return $Wert }

# --------------------------------------------------------------------------
# Vertragspruefer
# --------------------------------------------------------------------------

function Assert-PaketManifest ( $Ist ) {
    $pflicht = @('schema_version','handoff_id','auftrag_kennung','projekt_id','profil','erstellt','pfad_basis',
                 'report_hash','abschluss','anlagen','anlagen_hash','anlagen_erfassung','absender','empfaenger',
                 'auftrag_meta','auftrag_kontext')
    $erlaubt = $pflicht + @('session_id','turn_id','auftrag_id')
    Assert-JsonObjekt    -Wert $Ist -Ort 'Manifest'
    Assert-Pflichtfelder -Objekt $Ist -Pflicht $pflicht -Ort 'Manifest'
    Assert-NurFelder     -Objekt $Ist -Erlaubt $erlaubt -Ort 'Manifest'
    if (-not (Test-IstZahl $Ist.schema_version)) { throw "Manifest: schema_version kein Integer." }
    Assert-Wert -Wert $Ist.schema_version -Erwartet 2 -Ort 'Manifest.schema_version'
    if (-not (Test-IstHex $Ist.handoff_id 32))      { throw "Manifest: ungueltige handoff_id." }
    if (-not (Test-IstHex $Ist.auftrag_kennung 32)) { throw "Manifest: ungueltige auftrag_kennung." }
    Assert-OptionalHex -Ist $Ist -Name 'auftrag_id' -Laenge 32 -Vergleich $Ist.auftrag_kennung -Ort 'Manifest'
    Assert-Text -Wert $Ist.projekt_id -Ort 'Manifest.projekt_id'
    Assert-EnumWert -Wert $Ist.profil -Erlaubt @('lieferung','test','validierung') -Ort 'Manifest.profil'
    Assert-TextOderNull -Wert $Ist.session_id -Ort 'Manifest.session_id'
    Assert-TextOderNull -Wert $Ist.turn_id    -Ort 'Manifest.turn_id'
    Assert-Konstante -Wert $Ist.pfad_basis -Erwartet 'paket' -Ort 'Manifest.pfad_basis'
    if (-not (Test-IstHex $Ist.report_hash 64))  { throw "Manifest: ungueltiger report_hash." }
    if (-not (Test-IstHex $Ist.anlagen_hash 64)) { throw "Manifest: ungueltiger anlagen_hash." }
    Assert-Konstante -Wert $Ist.anlagen_erfassung -Erwartet $KonstanteErfassung -Ort 'Manifest.anlagen_erfassung'
    Assert-EnumWert -Wert $Ist.auftrag_kontext -Erlaubt @('vorhanden','nicht vorhanden') -Ort 'Manifest.auftrag_kontext'
    Assert-IsoZeitstempel -Wert $Ist.erstellt -Ort 'Manifest.erstellt'

    $abP = @('basis','rel_pfad','groesse','uebernommen_aus')
    Assert-Pflichtfelder -Objekt $Ist.abschluss -Pflicht $abP -Ort 'Manifest.abschluss'
    Assert-NurFelder     -Objekt $Ist.abschluss -Erlaubt $abP -Ort 'Manifest.abschluss'
    Assert-Konstante -Wert $Ist.abschluss.basis -Erwartet 'paket' -Ort 'Manifest.abschluss.basis'
    Assert-Text -Wert $Ist.abschluss.rel_pfad -Ort 'Manifest.abschluss.rel_pfad'
    if (-not ($Ist.abschluss.rel_pfad -cmatch '\Abericht/')) { throw "Manifest: abschluss.rel_pfad ohne 'bericht/'." }
    if (-not (Test-SichererRelPfad -RelPfad $Ist.abschluss.rel_pfad)) { throw "Manifest: abschluss.rel_pfad unsicher." }
    if (-not (Test-IstZahl $Ist.abschluss.groesse)) { throw "Manifest: abschluss.groesse kein Integer." }
    if ($Ist.abschluss.groesse -lt 1) { throw "Manifest: abschluss.groesse < 1." }
    Assert-Text -Wert $Ist.abschluss.uebernommen_aus -Ort 'Manifest.abschluss.uebernommen_aus'
    if (-not (Test-SichererRelPfad -RelPfad $Ist.abschluss.uebernommen_aus)) { throw "Manifest: uebernommen_aus unsicher." }

    if (-not (Test-IstJsonArray $Ist.anlagen)) { throw "Manifest: 'anlagen' ist kein JSON-Array." }
    $gesehen = @{}
    foreach ($e in $Ist.anlagen) {
        $aP = @('RelPfad','SHA256','Groesse')
        Assert-Pflichtfelder -Objekt $e -Pflicht $aP -Ort 'Manifest.anlagen[]'
        Assert-NurFelder     -Objekt $e -Erlaubt $aP -Ort 'Manifest.anlagen[]'
        Assert-Text -Wert $e.RelPfad -Ort 'Manifest.anlagen[].RelPfad'
        if (-not ($e.RelPfad -cmatch '\Aanlagen/')) { throw "Manifest: Anlagenpfad ohne 'anlagen/'." }
        if (-not (Test-SichererRelPfad -RelPfad $e.RelPfad)) { throw "Manifest: unsicherer Anlagenpfad '$($e.RelPfad)'." }
        if ($gesehen.ContainsKey($e.RelPfad)) { throw "Manifest: doppelter Anlagenpfad '$($e.RelPfad)'." }
        $gesehen[$e.RelPfad] = $true
        if (-not (Test-IstHex $e.SHA256 64)) { throw "Manifest: ungueltiger Anlagenhash." }
        if (-not (Test-IstZahl $e.Groesse)) { throw "Manifest: Anlagengroesse kein Integer." }
        if ($e.Groesse -lt 0) { throw "Manifest: negative Anlagengroesse." } }

    $sP = @('kontext_id')
    Assert-Pflichtfelder -Objekt $Ist.absender -Pflicht $sP -Ort 'Manifest.absender'
    Assert-NurFelder     -Objekt $Ist.absender -Erlaubt $sP -Ort 'Manifest.absender'
    Assert-Text -Wert $Ist.absender.kontext_id -Ort 'Manifest.absender.kontext_id'

    $eP = @('kanal','unterhaltung_id')
    Assert-Pflichtfelder -Objekt $Ist.empfaenger -Pflicht $eP -Ort 'Manifest.empfaenger'
    Assert-NurFelder     -Objekt $Ist.empfaenger -Erlaubt $eP -Ort 'Manifest.empfaenger'
    Assert-Text -Wert $Ist.empfaenger.kanal -Ort 'Manifest.empfaenger.kanal'
    Assert-Text -Wert $Ist.empfaenger.unterhaltung_id -Ort 'Manifest.empfaenger.unterhaltung_id'

    $mP = @('basis','rel_pfad','sha256')
    Assert-Pflichtfelder -Objekt $Ist.auftrag_meta -Pflicht $mP -Ort 'Manifest.auftrag_meta'
    Assert-NurFelder     -Objekt $Ist.auftrag_meta -Erlaubt $mP -Ort 'Manifest.auftrag_meta'
    Assert-Konstante -Wert $Ist.auftrag_meta.basis -Erwartet 'auftrag' -Ort 'Manifest.auftrag_meta.basis'
    Assert-Text -Wert $Ist.auftrag_meta.rel_pfad -Ort 'Manifest.auftrag_meta.rel_pfad'
    if (-not (Test-IstHex $Ist.auftrag_meta.sha256 64)) { throw "Manifest: ungueltiger auftrag_meta.sha256." }
    return $true }

function Assert-PaketKonsistenz ( $Manifest ) {
    $anlagenHash = Get-Sha256Text -Text (Get-AnlagenManifest -Anlagen $Manifest.anlagen)
    if (-not (Test-TextGleichOrdinal -A $anlagenHash -B $Manifest.anlagen_hash)) { throw "Manifest: anlagen_hash stimmt nicht mit der Anlagenliste ueberein." }
    $handoffId = (Get-Sha256Text -Text (Get-LaengenKodiert -Felder @(
        "kennung=$($Manifest.auftrag_kennung)"
        "abschluss_aus=$($Manifest.abschluss.uebernommen_aus)"
        "report_hash=$($Manifest.report_hash)"
        "anlagen_hash=$anlagenHash"
        "projekt_id=$($Manifest.projekt_id)"
        "profil=$($Manifest.profil)"
        "empfaenger_kanal=$($Manifest.empfaenger.kanal)"
        "empfaenger_unterhaltung=$($Manifest.empfaenger.unterhaltung_id)"
    ))).Substring(0,32)
    if (-not (Test-TextGleichOrdinal -A $handoffId -B $Manifest.handoff_id)) { throw "Manifest: handoff_id ist aus dem Inhalt nicht reproduzierbar." }
    return $true }

function Assert-KontextVollstaendig ( $Kontext ) {
    $pflicht = @('schema_version','auftrag_kennung','projekt_id','profil','empfaenger','erstellt')
    $erlaubt = $pflicht + @('session_id','turn_id')
    Assert-JsonObjekt    -Wert $Kontext -Ort 'Kontext'
    Assert-Pflichtfelder -Objekt $Kontext -Pflicht $pflicht -Ort 'Kontext'
    Assert-NurFelder     -Objekt $Kontext -Erlaubt $erlaubt -Ort 'Kontext'
    if (-not (Test-IstZahl $Kontext.schema_version)) { throw "Kontext: schema_version kein Integer." }
    Assert-Wert -Wert $Kontext.schema_version -Erwartet 1 -Ort 'Kontext.schema_version'
    if (-not (Test-IstHex $Kontext.auftrag_kennung 32)) { throw "Kontext: ungueltige auftrag_kennung." }
    Assert-Text -Wert $Kontext.projekt_id -Ort 'Kontext.projekt_id'
    Assert-EnumWert -Wert $Kontext.profil -Erlaubt @('lieferung','test','validierung') -Ort 'Kontext.profil'
    Assert-TextOderNull -Wert $Kontext.session_id -Ort 'Kontext.session_id'
    Assert-TextOderNull -Wert $Kontext.turn_id    -Ort 'Kontext.turn_id'
    Assert-IsoZeitstempel -Wert $Kontext.erstellt -Ort 'Kontext.erstellt'
    $eP = @('kanal','unterhaltung_id')
    Assert-Pflichtfelder -Objekt $Kontext.empfaenger -Pflicht $eP -Ort 'Kontext.empfaenger'
    Assert-NurFelder     -Objekt $Kontext.empfaenger -Erlaubt $eP -Ort 'Kontext.empfaenger'
    Assert-Text -Wert $Kontext.empfaenger.kanal -Ort 'Kontext.empfaenger.kanal'
    Assert-Text -Wert $Kontext.empfaenger.unterhaltung_id -Ort 'Kontext.empfaenger.unterhaltung_id'
    return $true }

function Assert-StatusVollstaendig ( $Status ) {
    $pflicht = @('schema_version','handoff_id','status','geaendert')
    Assert-JsonObjekt    -Wert $Status -Ort 'Status'
    Assert-Pflichtfelder -Objekt $Status -Pflicht $pflicht -Ort 'Status'
    Assert-NurFelder     -Objekt $Status -Erlaubt $pflicht -Ort 'Status'
    if (-not (Test-IstZahl $Status.schema_version)) { throw "Status: schema_version kein Integer." }
    Assert-Wert -Wert $Status.schema_version -Erwartet 1 -Ort 'Status.schema_version'
    if (-not (Test-IstHex $Status.handoff_id 32)) { throw "Status: ungueltige handoff_id." }
    Assert-EnumWert -Wert $Status.status -Erlaubt $StatusGueltig -Ort 'Status.status'
    Assert-IsoZeitstempel -Wert $Status.geaendert -Ort 'Status.geaendert'
    return $true }

function Get-PaketSoll ( $Manifest ) {
    $soll = @('handoff.json', $Manifest.abschluss.rel_pfad)
    foreach ($e in @($Manifest.anlagen)) { $soll += $e.RelPfad }
    return $soll }

function Test-PaketdateienVollstaendig { param(
        [Parameter(Mandatory=$true)][string]$PaketDir,
        [Parameter(Mandatory=$true)][string[]]$Erwartet)
    $ist = @()
    foreach ($f in (Get-DateienOhneLinks -Wurzel $PaketDir -Bereich $PaketDir)) {
        $rel = ($f.FullName.Substring($PaketDir.Length).TrimStart('\','/')) -replace '\\','/'
        $ist += $rel }
    foreach ($rel in $ist) {
        $gefunden = $false
        foreach ($e in $Erwartet) { if ([string]::Equals($e,$rel,[System.StringComparison]::OrdinalIgnoreCase)) { $gefunden = $true; break } }
        if ($gefunden) { continue }
        $zusatz = $false
        foreach ($z in $ZulaessigeZusatzdateien) { if ([string]::Equals($z,$rel,[System.StringComparison]::OrdinalIgnoreCase)) { $zusatz = $true; break } }
        if ($zusatz) { continue }
        throw "Unerwartete Datei im Paket: $rel" }
    foreach ($rel in $Erwartet) {
        $drin = $false
        foreach ($e in $ist) { if ([string]::Equals($e,$rel,[System.StringComparison]::OrdinalIgnoreCase)) { $drin = $true; break } }
        if (-not $drin) { throw "Erwartete Paketdatei fehlt: $rel" } }
    return $true }

function Get-PaketAusManifest { param(
        [Parameter(Mandatory=$true)][string]$PaketDir,
        [Parameter(Mandatory=$true)][string]$Bereich)
    Assert-KeineReparsePoints -Pfad $PaketDir -Wurzel $Bereich
    $handoffPfad = Join-Path -Path $PaketDir -ChildPath 'handoff.json'
    if (-not (Test-Path -LiteralPath $handoffPfad -PathType Leaf)) { throw "Paketordner ohne handoff.json: $PaketDir" }
    Assert-KeineReparsePoints -Pfad $handoffPfad -Wurzel $Bereich
    $text = Get-Content -LiteralPath $handoffPfad -Raw -Encoding UTF8
    try   { $obj = $text | ConvertFrom-Json } catch { throw "Manifest ist kein gueltiges JSON: $handoffPfad" }
    return (Get-JsonObjekt -Wert $obj) }

function Assert-PaketBestand { param(
        [Parameter(Mandatory=$true)][string]$PaketDir,
        [Parameter(Mandatory=$true)][string]$Bereich)
    Assert-KeineReparsePoints -Pfad $PaketDir -Wurzel $Bereich
    $handoffPfad = Join-Path -Path $PaketDir -ChildPath 'handoff.json'
    if (-not (Test-Path -LiteralPath $handoffPfad -PathType Leaf)) { throw "Paketordner ohne handoff.json: $PaketDir" }
    Assert-KeineReparsePoints -Pfad $handoffPfad -Wurzel $Bereich
    $ist = Get-JsonObjekt -Wert (Get-Content -LiteralPath $handoffPfad -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-PaketManifest   -Ist $ist | Out-Null
    Assert-PaketKonsistenz -Manifest $ist | Out-Null
    Test-PaketdateienVollstaendig -PaketDir $PaketDir -Erwartet (Get-PaketSoll -Manifest $ist) | Out-Null
    $bZiel = Resolve-PaketPfad -PaketWurzel $PaketDir -RelPfad $ist.abschluss.rel_pfad -Bereich $Bereich
    Assert-KeineReparsePoints -Pfad $bZiel -Wurzel $Bereich
    if (-not (Test-Path -LiteralPath $bZiel -PathType Leaf)) { throw "Bericht fehlt im Paket." }
    if ((Get-Item -LiteralPath $bZiel -Force -ErrorAction Stop).Length -ne $ist.abschluss.groesse) { throw "Berichtsgoesse weicht ab." }
    if (-not (Test-TextGleichOrdinal -A (Get-Sha256Hex -Pfad $bZiel) -B $ist.report_hash)) { throw "Berichtshash weicht ab." }
    foreach ($e in @($ist.anlagen)) {
        $z = Resolve-PaketPfad -PaketWurzel $PaketDir -RelPfad $e.RelPfad -Bereich $Bereich
        Assert-KeineReparsePoints -Pfad $z -Wurzel $Bereich
        if (-not (Test-Path -LiteralPath $z -PathType Leaf)) { throw "Anlage fehlt im Paket: $($e.RelPfad)" }
        if ((Get-Item -LiteralPath $z -Force -ErrorAction Stop).Length -ne $e.Groesse) { throw "Anlagengroesse weicht ab: $($e.RelPfad)" }
        if (-not (Test-TextGleichOrdinal -A (Get-Sha256Hex -Pfad $z) -B $e.SHA256)) { throw "Anlage weicht ab: $($e.RelPfad)" } }
    return $ist }

function Assert-KonfliktStatus { param(
        [Parameter(Mandatory=$true)][string]$StatusPfad,
        [Parameter(Mandatory=$true)][string]$HandoffId,
        [Parameter(Mandatory=$true)][string]$Bereich)
    Assert-KeineReparsePoints -Pfad $StatusPfad -Wurzel $Bereich
    if ((Test-Path -LiteralPath $StatusPfad) -and -not (Test-Path -LiteralPath $StatusPfad -PathType Leaf)) {
        throw "Bestandskonflikt: '$StatusPfad' existiert, ist aber keine Datei." }
    if (-not (Test-Path -LiteralPath $StatusPfad -PathType Leaf)) { return 'vorbereitet' }
    $s = Get-JsonObjekt -Wert (Get-Content -LiteralPath $StatusPfad -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-StatusVollstaendig -Status $s | Out-Null
    if (-not (Test-TextGleichOrdinal -A $s.handoff_id -B $HandoffId)) { throw "Statusdatensatz passt nicht zum Paket." }
    if (Test-TextGleichOrdinal -A $s.status -B 'empfangen_bestaetigt') {
        throw "KONFLIKT: Status 'empfangen_bestaetigt' ist nicht verifizierbar (kein Rueckkanal). Statusdatensatz bleibt unveraendert; kein Erfolgssignal." }
    return $s.status }

function Assert-Exklusiv { param(
        [Parameter(Mandatory=$true)][string]$Kennung,
        [Parameter(Mandatory=$true)][string]$HandoffId,
        [Parameter(Mandatory=$true)][string]$Wurzel)
    # Bereichszugehoerigkeit und Reparse-Points VOR jedem Schreibzugriff pruefen.
    Assert-KeineReparsePoints -Pfad $Wurzel -Wurzel $Wurzel
    $sperrDir = Join-Path -Path $Wurzel -ChildPath 'sperren'
    Assert-ImBereich -Pfad $sperrDir -Wurzel $Wurzel | Out-Null
    Assert-KeineReparsePoints -Pfad $sperrDir -Wurzel $Wurzel
    if (-not (Test-Path -LiteralPath $sperrDir -PathType Container)) {
        New-Item -Path $sperrDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    Assert-KeineReparsePoints -Pfad $sperrDir -Wurzel $Wurzel
    $schluessel = (Get-Sha256Text -Text ($Kennung + '|' + $HandoffId)).Substring(0,32)
    $sperrPfad  = Join-Path -Path $sperrDir -ChildPath ('sperre-' + $schluessel + '.lock')
    Assert-ImBereich -Pfad $sperrPfad -Wurzel $Wurzel | Out-Null
    Assert-KeineReparsePoints -Pfad $sperrPfad -Wurzel $Wurzel
    try {
        $fs = [IO.File]::Open($sperrPfad, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch {
        # Strukturierte Verpackung: urspruengliche Exception bleibt erhalten, Pfadkontext wird ergaenzt.
        Write-Error -Message ("Sperre konnte nicht erworben werden: {0}" -f $sperrPfad) `
                    -Exception $_.Exception -Category ResourceUnavailable -TargetObject $sperrPfad -ErrorAction Stop }
    return $fs }

function Assert-Kollisionsfrei { param(
        [Parameter(Mandatory=$true)][string[]]$System,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Anlagen,
        [Parameter(Mandatory=$true)][string]$BauDir,
        [Parameter(Mandatory=$true)][string]$Bereich)
    $reserviert = @('handoff.json') + $ZulaessigeZusatzdateien
    $cmp = [System.StringComparer]::OrdinalIgnoreCase
    $alle = @($System) + @($Anlagen)
    $gesehen = New-Object 'System.Collections.Generic.Dictionary[string,bool]' $cmp
    foreach ($p in $alle) {
        if (-not (Test-SichererRelPfad -RelPfad $p)) { throw "Kollisionspruefung: unsicherer Zielpfad '$p'." }
        if ($gesehen.ContainsKey($p)) { throw "Kollisionspruefung: doppelter Zielpfad '$p'." }
        $gesehen[$p] = $true }
    # Reservierte Wurzelnamen: Anlagen duerfen sie weder sein noch als Wurzelpraefix nutzen.
    foreach ($p in @($Anlagen)) {
        foreach ($r in $reserviert) {
            if ($cmp.Equals($p, $r) -or $p.StartsWith(($r + '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Kollisionspruefung: Anlage '$p' belegt den reservierten Wurzelnamen '$r'." } } }
    foreach ($p in $alle) {
        foreach ($q in $alle) {
            if ($cmp.Equals($p, $q)) { continue }
            if ($q.StartsWith(($p + '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Kollisionspruefung: '$p' ist zugleich Datei und Verzeichnis ('$q')." } } }
    # Bestandspruefung: kein geplantes Ziel darf im Bauverzeichnis bereits existieren.
    # Wurzelausschluss: das Bauverzeichnis muss ein echtes Unterverzeichnis sein.
    $bauAbs = Assert-LaufwerkspfadForm -Pfad $BauDir -Ort 'Bauverzeichnis'
    $bauRoot = [IO.Path]::GetPathRoot($bauAbs)
    if ([string]::IsNullOrEmpty($bauRoot)) { throw "Kollisionspruefung: Bauverzeichnis ohne Dateisystemwurzel: '$BauDir'." }
    if ($bauAbs.TrimEnd('\','/').Length -le $bauRoot.TrimEnd('\','/').Length) {
        throw "Kollisionspruefung: Bauverzeichnis darf keine Dateisystemwurzel sein: '$BauDir'." }
    $bauVoll = $bauAbs.TrimEnd('\','/')
    # Bedingung 2: das Bauverzeichnis selbst muss im erlaubten Bereich liegen (einschliessend).
    $bauVoll = Assert-ImBereich -Pfad $bauVoll -Wurzel $Bereich
    Assert-KeineReparsePoints -Pfad $bauVoll -Wurzel $Bereich
    foreach ($p in $alle) {
        $voll = Resolve-PaketPfad -PaketWurzel $bauVoll -RelPfad $p -Bereich $Bereich
        if (Test-Path -LiteralPath $voll) { throw "Kollisionspruefung: Ziel existiert bereits im Bauverzeichnis: '$p'." }
        $vorfahr = Split-Path -Path $voll -Parent
        $wurzelErreicht = $false
        while ($vorfahr) {
            if ([string]::Equals($vorfahr, $bauVoll, [System.StringComparison]::OrdinalIgnoreCase)) {
                $wurzelErreicht = $true; break }
            if (-not $vorfahr.StartsWith(($bauVoll + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Kollisionspruefung: Zielpfad verlaesst das Bauverzeichnis: '$vorfahr'." }
            if (Test-Path -LiteralPath $vorfahr -PathType Leaf) {
                throw "Kollisionspruefung: Datei-Vorfahr im Bauverzeichnis: '$vorfahr'." }
            if (Test-Path -LiteralPath $vorfahr) {
                $it = Get-Item -LiteralPath $vorfahr -Force -ErrorAction Stop
                if (($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Kollisionspruefung: Reparse Point im Zielpfad: '$vorfahr'." } }
            $vorfahr = Split-Path -Path $vorfahr -Parent }
        if (-not $wurzelErreicht) {
            throw "Kollisionspruefung: Bauwurzel nicht erreicht fuer Ziel '$p'." } }
    return $true }

function Restore-Paketstatus {
    # ANSCHLUSSSTELLE â€“ absichtlich NICHT implementiert.
    throw "Restore-Paketstatus ist nicht implementiert. Recovery erfordert: Paketsperre, Sicherung des fehlerhaften Zustands ausserhalb des Paketbestands, erneute Identitaets-/Manifest-/Vollstaendigkeits-/Groessen-/Hashpruefung, erst danach 'gespeichert_verifiziert'. Kein pauschales Rollback; 'empfangen_bestaetigt' bleibt gesperrt." }

function Receive-Bestaetigung {
    # ANSCHLUSSSTELLE â€“ absichtlich NICHT implementiert.
    throw "Receive-Bestaetigung ist nicht implementiert: keine verifizierte Rueckkanal- und Signaturpruefung vorhanden. Status 'empfangen_bestaetigt' wird nicht vergeben und nicht anerkannt." }

function Get-AuftragKontext { param([Parameter(Mandatory=$true)][string]$AuftragDir)
    $p = Join-Path -Path $AuftragDir -ChildPath 'kontext.json'
    if ((Test-Path -LiteralPath $p) -and -not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Bestandskonflikt: '$p' existiert, ist aber keine Datei." }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    Assert-KeineReparsePoints -Pfad $p -Wurzel $AuftragDir
    return (Get-JsonObjekt -Wert (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)) }

# --------------------------------------------------------------------------
# Auftragsannahme
# --------------------------------------------------------------------------

function New-Auftrag {
    param(
        [Parameter(Mandatory=$true)][string]$Eingabe,
        [string]$ProjektId,
        [string]$Profil,
        [string]$EmpfaengerKanal,
        [string]$EmpfaengerUnterhaltung,
        [AllowNull()]$SessionId,
        [AllowNull()]$TurnId
    )
    $wurzelVoll = Assert-LaufwerkspfadForm -Pfad $Base -Ort 'Basiswurzel'

    # --- VOR jeder BestandsÃ¤nderung: Eingabe- und Kontextvalidierung --------
    $eingabeVoll = Assert-LaufwerkspfadForm -Pfad $Eingabe -Ort 'Eingabedatei'
    $eingabeVoll = Assert-ImBereich -Pfad $eingabeVoll -Wurzel $wurzelVoll
    if (-not (Test-Path -LiteralPath $eingabeVoll -PathType Leaf)) { throw "Eingabedatei nicht gefunden: $eingabeVoll" }
    Assert-KeineReparsePoints -Pfad $eingabeVoll -Wurzel $wurzelVoll

    $kontextAngegeben = @('ProjektId','Profil','EmpfaengerKanal','EmpfaengerUnterhaltung') |
                        Where-Object { $PSBoundParameters.ContainsKey($_) }
    $kontextGewuenscht = ($kontextAngegeben.Count -gt 0)
    $kontextAngelegt   = $false
    if ($kontextGewuenscht -and $kontextAngegeben.Count -lt 4) {
        throw "Kontext unvollstaendig: -ProjektId, -Profil, -EmpfaengerKanal und -EmpfaengerUnterhaltung sind gemeinsam Pflicht." }
    if (-not $kontextGewuenscht -and ($PSBoundParameters.ContainsKey('SessionId') -or $PSBoundParameters.ContainsKey('TurnId'))) {
        throw "Session/Turn ohne die vier Kontextangaben: unvollstaendiger Kontext." }
    if ($kontextGewuenscht) {
        Assert-Text -Wert $ProjektId -Ort 'ProjektId'
        Assert-Text -Wert $EmpfaengerKanal -Ort 'EmpfaengerKanal'
        Assert-Text -Wert $EmpfaengerUnterhaltung -Ort 'EmpfaengerUnterhaltung'
        Assert-EnumWert -Wert $Profil -Erlaubt @('lieferung','test','validierung') -Ort 'Profil'
        Assert-StringOderNull -Wert $SessionId -Ort 'SessionId'
        Assert-StringOderNull -Wert $TurnId    -Ort 'TurnId' }

    # --- ab hier erst BestandsÃ¤nderungen -----------------------------------
    $kennung = [Guid]::NewGuid().ToString('N')
    $auftragDir = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $wurzelVoll -ChildPath 'auftraege') -ChildPath $kennung) -Wurzel $wurzelVoll
    $arbeitDir  = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $wurzelVoll -ChildPath 'arbeit')    -ChildPath $kennung) -Wurzel $wurzelVoll
    $berichtDir = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $wurzelVoll -ChildPath 'berichte')  -ChildPath $kennung) -Wurzel $wurzelVoll

    foreach ($d in @($auftragDir, $arbeitDir, $berichtDir)) {
        Assert-KeineReparsePoints -Pfad $d -Wurzel $wurzelVoll
        New-Item -Path $d -ItemType Directory -Force -ErrorAction Stop | Out-Null }

    $ziel = Join-Path -Path $auftragDir -ChildPath 'auftrag.md'
    if (Test-Path -LiteralPath $ziel) { throw "Ziel existiert bereits, ueberschreibe nicht: $ziel" }
    Copy-Item -LiteralPath $eingabeVoll -Destination $ziel -Force

    $hash      = Get-Sha256Hex -Pfad $ziel
    $quellHash = Get-Sha256Hex -Pfad $eingabeVoll
    if (-not (Test-TextGleichOrdinal -A $quellHash -B $hash)) { throw "Quell-/Kopie-Vergleich fehlgeschlagen: $ziel entspricht nicht der Eingabe." }

    $meta = @"
Kennung: $kennung
Erzeugt: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
Eingabe-Quellpfad: $eingabeVoll
Eingabe-SHA256: $quellHash
Auftrag-md-SHA256: $hash
"@
    Write-NeuAtomar -Ziel (Join-Path -Path $auftragDir -ChildPath 'meta.txt') -Bytes ([Text.Encoding]::UTF8.GetBytes($meta)) | Out-Null

    if ($kontextGewuenscht) {
        $kontext = [ordered]@{
            schema_version  = 1
            auftrag_kennung = $kennung
            projekt_id      = $ProjektId
            profil          = $Profil
            empfaenger      = [ordered]@{ kanal = $EmpfaengerKanal; unterhaltung_id = $EmpfaengerUnterhaltung }
            erstellt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        if ($PSBoundParameters.ContainsKey('SessionId')) { $kontext['session_id'] = $SessionId }
        if ($PSBoundParameters.ContainsKey('TurnId'))    { $kontext['turn_id']    = $TurnId }
        Assert-KontextVollstaendig -Kontext (Get-JsonObjekt -Wert $kontext) | Out-Null
        Write-NeuAtomar -Ziel (Join-Path -Path $auftragDir -ChildPath 'kontext.json') `
                        -Bytes ([Text.Encoding]::UTF8.GetBytes(($kontext | ConvertTo-Json -Depth 6))) | Out-Null
        $kontextAngelegt = $true
    }

    [PSCustomObject]@{
        Kennung    = $kennung
        Auftrag    = $ziel
        Arbeit     = $arbeitDir
        Bericht    = $berichtDir
        Kontext    = $kontextAngelegt
        EingabeHash  = $quellHash
        AuftragHash = $hash
    }
}

# --------------------------------------------------------------------------
# Ergebnisannahme
# --------------------------------------------------------------------------

function Receive-Ergebnis {
    param(
        [Parameter(Mandatory=$true)][string]$Kennung,
        [Parameter(Mandatory=$true)][string]$Abschluss,
        [Parameter(Mandatory=$true)][string]$ProjektId,
        [Parameter(Mandatory=$true)][string]$Profil,
        [Parameter(Mandatory=$true)][string]$EmpfaengerKanal,
        [Parameter(Mandatory=$true)][string]$EmpfaengerUnterhaltung,
        [AllowNull()]$SessionId,
        [AllowNull()]$TurnId,
        [string]$AbsenderKontext = 'apex-schnittstelle-adapter'
    )
    $sessionUebergeben = $PSBoundParameters.ContainsKey('SessionId')
    $turnUebergeben    = $PSBoundParameters.ContainsKey('TurnId')

    Assert-Kennung -Wert $Kennung | Out-Null

    $wurzelVoll = Assert-LaufwerkspfadForm -Pfad $Base -Ort 'Basiswurzel'
    $arbeitDir  = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $wurzelVoll -ChildPath 'arbeit')    -ChildPath $Kennung) -Wurzel $wurzelVoll
    $berichtDir = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $wurzelVoll -ChildPath 'berichte')  -ChildPath $Kennung) -Wurzel $wurzelVoll
    $auftragDir = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $wurzelVoll -ChildPath 'auftraege') -ChildPath $Kennung) -Wurzel $wurzelVoll
    $metaPfad    = Join-Path -Path $auftragDir -ChildPath 'meta.txt'
    $kontextPfad = Join-Path -Path $auftragDir -ChildPath 'kontext.json'

    if (-not (Test-Path -LiteralPath $arbeitDir -PathType Container)) { throw "Arbeitsordner existiert nicht: $arbeitDir" }
    if (-not (Test-Path -LiteralPath $metaPfad -PathType Leaf)) { throw "Auftragsmetadaten fehlen: $metaPfad" }

    Assert-KeineReparsePoints -Pfad $arbeitDir   -Wurzel $wurzelVoll
    Assert-KeineReparsePoints -Pfad $auftragDir  -Wurzel $wurzelVoll
    Assert-KeineReparsePoints -Pfad $berichtDir  -Wurzel $wurzelVoll
    Assert-KeineReparsePoints -Pfad $metaPfad    -Wurzel $wurzelVoll
    Assert-KeineReparsePoints -Pfad $kontextPfad -Wurzel $wurzelVoll

    # Fruehpruefung: Inhalte VOR jedem Schreibzugriff (Variante A: mindestens ein Zeichen)
    Assert-Text -Wert $ProjektId -Ort 'ProjektId'
    Assert-Text -Wert $EmpfaengerKanal -Ort 'EmpfaengerKanal'
    Assert-Text -Wert $EmpfaengerUnterhaltung -Ort 'EmpfaengerUnterhaltung'
    Assert-Text -Wert $AbsenderKontext -Ort 'AbsenderKontext'
    Assert-EnumWert -Wert $Profil -Erlaubt @('lieferung','test','validierung') -Ort 'Profil'
    Assert-StringOderNull -Wert $SessionId -Ort 'SessionId'
    Assert-StringOderNull -Wert $TurnId    -Ort 'TurnId'

    # Auftragskontext ist bindend. Fehlen blockiert die gebundene Uebergabe.
    $kontext = Get-AuftragKontext -AuftragDir $auftragDir
    if ($null -eq $kontext) {
        throw "Auftragsbindung blockiert: kein Kontext vorhanden. Gebundene Uebergabe ist ohne Kontext nicht zulaessig." }
    Assert-KontextVollstaendig -Kontext $kontext | Out-Null
    if (-not (Test-TextGleichOrdinal -A $kontext.auftrag_kennung -B $Kennung)) { throw "Kontext gehoert zu einer anderen Auftragskennung." }
    if (-not (Test-TextGleichOrdinal -A $kontext.projekt_id -B $ProjektId)) { throw "Projekt stimmt nicht mit dem Auftragskontext ueberein." }
    if (-not (Test-TextGleichOrdinal -A $kontext.profil -B $Profil)) { throw "Profil stimmt nicht mit dem Auftragskontext ueberein." }
    if (-not (Test-TextGleichOrdinal -A $kontext.empfaenger.kanal -B $EmpfaengerKanal) -or
        -not (Test-TextGleichOrdinal -A $kontext.empfaenger.unterhaltung_id -B $EmpfaengerUnterhaltung)) {
        throw "Empfaenger stimmt nicht mit dem Auftragskontext ueberein." }

    # Anwesenheit VOR Wertvergleich: explizites null gegen fehlendes Feld ist nicht gleich.
    if ($sessionUebergeben) {
        if (-not (Test-FeldVorhanden -Objekt $kontext -Name 'session_id')) {
            throw "Session wurde uebergeben, fehlt aber im Auftragskontext." }
        if (-not (Test-TextGleichOrdinal -A $kontext.session_id -B $SessionId)) {
            throw "Uebergebene Session weicht vom Auftragskontext ab." } }
    if ($turnUebergeben) {
        if (-not (Test-FeldVorhanden -Objekt $kontext -Name 'turn_id')) {
            throw "Turn wurde uebergeben, fehlt aber im Auftragskontext." }
        if (-not (Test-TextGleichOrdinal -A $kontext.turn_id -B $TurnId)) {
            throw "Uebergebener Turn weicht vom Auftragskontext ab." } }
    if (-not $sessionUebergeben) { $SessionId = $kontext.session_id }
    if (-not $turnUebergeben)    { $TurnId    = $kontext.turn_id }
    $kontextStand = 'vorhanden'

    # --- 1. Fachlichen Abschluss uebernehmen -------------------------------
    $abschlussVoll = Resolve-PaketPfad -PaketWurzel $arbeitDir -RelPfad $Abschluss -Bereich $wurzelVoll
    if (-not (Test-Path -LiteralPath $abschlussVoll -PathType Leaf)) { throw "Fachlicher Abschluss nicht gefunden: $abschlussVoll" }
    Assert-KeineReparsePoints -Pfad $abschlussVoll -Wurzel $wurzelVoll
    $abschlussBytes = [IO.File]::ReadAllBytes($abschlussVoll)
    if ($abschlussBytes.Length -eq 0) { throw "Fachlicher Abschluss ist leer: $abschlussVoll" }
    $reportHash    = Get-Sha256Bytes -Bytes $abschlussBytes
    $reportSize    = $abschlussBytes.Length
    $abschlussRel  = ($Abschluss -replace '\\','/')
    $abschlussName = [IO.Path]::GetFileName($abschlussVoll)

    # --- 2. Anlagen erfassen (inkl. versteckter; ohne Linkverfolgung) ------
    $anlagenQuelle = @()
    foreach ($f in (Get-DateienOhneLinks -Wurzel $arbeitDir -Bereich $wurzelVoll)) {
        $rel = ($f.FullName.Substring($arbeitDir.Length).TrimStart('\','/')) -replace '\\','/'
        # Dateipfadvergleich ueber normalisierte Vollpfade; setzt eine case-insensitive Dateisystemumgebung voraus.
        if ([string]::Equals($f.FullName, $abschlussVoll, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-SichererRelPfad -RelPfad $rel)) { throw "Ungueltiger Anlagenpfad: $rel" }
        $anlagenQuelle += [ordered]@{ Rel = $rel; Voll = $f.FullName; Ord = (Get-OrdinalSchluessel -Text $rel) } }
    $anlagenQuelle = @($anlagenQuelle | Sort-Object -Property Ord)

    $anlagenEintraege = @()
    foreach ($q in $anlagenQuelle) {
        $bytes = [IO.File]::ReadAllBytes($q.Voll)
        $anlagenEintraege += [ordered]@{
            RelPfad = ('anlagen/' + $q.Rel)
            SHA256  = (Get-Sha256Bytes -Bytes $bytes)
            Groesse = $bytes.Length } }
    $anlagenHash = Get-Sha256Text -Text (Get-AnlagenManifest -Anlagen $anlagenEintraege)

    # --- 3. Uebergabeidentitaet --------------------------------------------
    $handoffId = (Get-Sha256Text -Text (Get-LaengenKodiert -Felder @(
        "kennung=$Kennung"
        "abschluss_aus=$abschlussRel"
        "report_hash=$reportHash"
        "anlagen_hash=$anlagenHash"
        "projekt_id=$ProjektId"
        "profil=$Profil"
        "empfaenger_kanal=$EmpfaengerKanal"
        "empfaenger_unterhaltung=$EmpfaengerUnterhaltung"
    ))).Substring(0,32)

    $paketeDir = Join-Path -Path $berichtDir -ChildPath 'pakete'
    $paketDir  = Join-Path -Path $paketeDir  -ChildPath $handoffId
    $handoffPfad      = Join-Path -Path $paketDir -ChildPath 'handoff.json'
    $statusPfad       = Join-Path -Path $paketDir -ChildPath 'status.json'

    # Kooperative Paketsperre: Handle vor der massgeblichen Paket-/Statuspruefung erwerben.
    $sperrHandle = Assert-Exklusiv -Kennung $Kennung -HandoffId $handoffId -Wurzel $wurzelVoll
    try {

    $handoff = [ordered]@{
        schema_version  = 2
        handoff_id      = $handoffId
        auftrag_kennung = $Kennung
        projekt_id      = $ProjektId
        profil          = $Profil
        auftrag_id      = $Kennung
        erstellt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        pfad_basis      = 'paket'
        report_hash     = $reportHash
        abschluss       = [ordered]@{
            basis           = 'paket'
            rel_pfad        = ('bericht/' + $abschlussName)
            groesse         = $reportSize
            uebernommen_aus = $abschlussRel }
        anlagen         = $anlagenEintraege
        anlagen_hash    = $anlagenHash
        anlagen_erfassung = $KonstanteErfassung
        absender        = [ordered]@{ kontext_id = $AbsenderKontext }
        empfaenger      = [ordered]@{ kanal = $EmpfaengerKanal; unterhaltung_id = $EmpfaengerUnterhaltung }
        auftrag_meta    = [ordered]@{ basis = 'auftrag'; rel_pfad = 'meta.txt'; sha256 = (Get-Sha256Hex -Pfad $metaPfad) }
        auftrag_kontext = $kontextStand }
    # Anwesenheit aus dem bindenden Auftragskontext uebernehmen: fehlt -> weglassen, vorhanden -> Wert (auch null).
    if (Test-FeldVorhanden -Objekt $kontext -Name 'session_id') { $handoff['session_id'] = $kontext.session_id }
    if (Test-FeldVorhanden -Objekt $kontext -Name 'turn_id')    { $handoff['turn_id']    = $kontext.turn_id }
    $handoffText = ($handoff | ConvertTo-Json -Depth 8)

    $status = 'vorbereitet'

    if ((Test-Path -LiteralPath $paketDir) -and -not (Test-Path -LiteralPath $paketDir -PathType Container)) {
        throw "Bestandskonflikt: '$paketDir' existiert, ist aber kein Verzeichnis." }
    if (-not (Test-Path -LiteralPath $paketDir -PathType Container)) {
        if ((Test-Path -LiteralPath $paketeDir) -and -not (Test-Path -LiteralPath $paketeDir -PathType Container)) {
            throw "Bestandskonflikt: '$paketeDir' existiert, ist aber kein Verzeichnis." }
        if (-not (Test-Path -LiteralPath $paketeDir -PathType Container)) {
            New-Item -Path $paketeDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        Assert-KeineReparsePoints -Pfad $paketeDir -Wurzel $wurzelVoll
        $bauDir = Join-Path -Path $paketeDir -ChildPath ('.bau-' + [Guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $bauDir) { throw "Bauverzeichnis existiert bereits: $bauDir" }

        # Kollisions-Vorpruefung: vollstaendiger Zielplan VOR dem ersten Nutzdatei-Schreibzugriff
        New-Item -Path $bauDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Assert-Kollisionsfrei -System @('handoff.json', $handoff.abschluss.rel_pfad) `
                              -Anlagen @($anlagenEintraege | ForEach-Object { $_.RelPfad }) `
                              -BauDir $bauDir -Bereich $wurzelVoll | Out-Null

        $reportZiel = Resolve-PaketPfad -PaketWurzel $bauDir -RelPfad $handoff.abschluss.rel_pfad -Bereich $wurzelVoll
        New-Item -Path (Split-Path -Path $reportZiel -Parent) -ItemType Directory -Force -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllBytes($reportZiel, $abschlussBytes)
        if (-not (Test-BytesGleich -A ([IO.File]::ReadAllBytes($reportZiel)) -B $abschlussBytes)) { throw "Berichtskopie weicht byteweise ab." }
        if (-not (Test-TextGleichOrdinal -A (Get-Sha256Hex -Pfad $reportZiel) -B $reportHash)) { throw "Berichtshash weicht ab." }

        for ($i = 0; $i -lt $anlagenEintraege.Count; $i++) {
            $e     = $anlagenEintraege[$i]
            $bytes = [IO.File]::ReadAllBytes($anlagenQuelle[$i].Voll)
            $ziel  = Resolve-PaketPfad -PaketWurzel $bauDir -RelPfad $e.RelPfad -Bereich $wurzelVoll
            New-Item -Path (Split-Path -Path $ziel -Parent) -ItemType Directory -Force -ErrorAction Stop | Out-Null
            [IO.File]::WriteAllBytes($ziel, $bytes)
            if (-not (Test-BytesGleich -A ([IO.File]::ReadAllBytes($ziel)) -B $bytes)) { throw "Anlagenkopie weicht byteweise ab: $($e.RelPfad)" }
            if (-not (Test-TextGleichOrdinal -A (Get-Sha256Hex -Pfad $ziel) -B $e.SHA256)) { throw "Anlagenhash weicht ab: $($e.RelPfad)" } }

        [IO.File]::WriteAllText((Join-Path -Path $bauDir -ChildPath 'handoff.json'), $handoffText, (New-Object Text.UTF8Encoding($false)))
        $hRueck = Get-JsonObjekt -Wert (Get-Content -LiteralPath (Join-Path -Path $bauDir -ChildPath 'handoff.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
        Assert-PaketManifest   -Ist $hRueck | Out-Null
        Assert-PaketKonsistenz -Manifest $hRueck | Out-Null
        Test-PaketdateienVollstaendig -PaketDir $bauDir -Erwartet (Get-PaketSoll -Manifest $hRueck) | Out-Null

        [IO.Directory]::Move($bauDir, $paketDir)
    }
    else {
        # 4b: Teil von Receive â€“ durchlaeuft weiterhin die vorgelagerte Quellenpruefung.
        $wieder = Get-PaketAusManifest -PaketDir $paketDir -Bereich $wurzelVoll
        Assert-PaketManifest   -Ist $wieder | Out-Null
        Assert-PaketKonsistenz -Manifest $wieder | Out-Null
        if (-not (Test-TextGleichOrdinal -A $wieder.handoff_id -B $handoffId)) {
            throw "Paketidentitaet: handoff_id passt nicht zum erwarteten Paketordner." }
        if (-not (Test-TextGleichOrdinal -A $wieder.auftrag_kennung -B $Kennung)) {
            throw "Paketidentitaet: Paket gehoert zu einer anderen Auftragskennung." }
        Assert-PaketBestand    -PaketDir $paketDir -Bereich $wurzelVoll | Out-Null
        # B5: Felder pruefen, die NICHT durch die Handoff-ID gebunden sind.
        if (-not (Test-TextGleichOrdinal -A $wieder.absender.kontext_id -B $AbsenderKontext)) {
            throw "Konflikt: absender.kontext_id des vorhandenen Pakets weicht vom aktuellen Aufruf ab." }
        if (-not (Test-TextGleichOrdinal -A $wieder.empfaenger.kanal -B $EmpfaengerKanal) -or
            -not (Test-TextGleichOrdinal -A $wieder.empfaenger.unterhaltung_id -B $EmpfaengerUnterhaltung)) {
            throw "Konflikt: empfaenger des vorhandenen Pakets weicht vom aktuellen Aufruf ab." }
        # Anwesenheit zuerst, dann Wert: fehlend und vorhandenes null sind verschieden.
        foreach ($paar in @(@('session_id',$SessionId), @('turn_id',$TurnId))) {
            $feld = $paar[0]
            $sollDa = Test-FeldVorhanden -Objekt $kontext -Name $feld
            $istDa  = Test-FeldVorhanden -Objekt $wieder  -Name $feld
            if ($sollDa -ne $istDa) {
                throw ("Konflikt: Anwesenheit von '{0}' im vorhandenen Paket weicht vom Auftragskontext ab." -f $feld) }
            if ($sollDa -and -not (Test-TextGleichOrdinal -A $wieder.$feld -B $kontext.$feld)) {
                throw ("Konflikt: Wert von '{0}' im vorhandenen Paket weicht vom Auftragskontext ab." -f $feld) } }
        if (-not (Test-TextGleichOrdinal -A $wieder.auftrag_meta.sha256 -B (Get-Sha256Hex -Pfad $metaPfad))) {
            throw "Konflikt: auftrag_meta.sha256 des vorhandenen Pakets weicht von den aktuellen Metadaten ab." }
        if (-not (Test-TextGleichOrdinal -A $wieder.auftrag_meta.rel_pfad -B $handoff.auftrag_meta.rel_pfad)) {
            throw "Konflikt: auftrag_meta.rel_pfad des vorhandenen Pakets weicht vom erwarteten Pfad ab." }
        if (-not (Test-TextGleichOrdinal -A $wieder.auftrag_kontext -B $handoff.auftrag_kontext)) {
            throw "Konflikt: auftrag_kontext des vorhandenen Pakets weicht vom erwarteten Status ab." }
        if (-not (Test-TextGleichOrdinal -A $wieder.abschluss.rel_pfad -B $handoff.abschluss.rel_pfad)) {
            throw "Konflikt: abschluss.rel_pfad des vorhandenen Pakets weicht vom erwarteten Berichtspfad ab." }
        $handoffText = Get-Content -LiteralPath $handoffPfad -Raw -Encoding UTF8
    }

    $status = Assert-KonfliktStatus -StatusPfad $statusPfad -HandoffId $handoffId -Bereich $wurzelVoll
    $setzeStatus = {
        param([string]$Von, [string]$Nach)
        Assert-StatusUebergang -Von $Von -Nach $Nach | Out-Null
        $obj = [ordered]@{ schema_version = 1; handoff_id = $handoffId; status = $Nach
                           geaendert = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        Assert-StatusVollstaendig -Status (Get-JsonObjekt -Wert $obj) | Out-Null
        Write-BytesAtomar -Ziel $statusPfad -Bytes ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5))) | Out-Null
        $r = Get-JsonObjekt -Wert (Get-Content -LiteralPath $statusPfad -Raw -Encoding UTF8 | ConvertFrom-Json)
        Assert-StatusVollstaendig -Status $r | Out-Null
        if (-not (Test-TextGleichOrdinal -A $r.status -B $Nach) -or -not (Test-TextGleichOrdinal -A $r.handoff_id -B $handoffId)) {
            throw "Statusruecklesung fehlgeschlagen: $statusPfad" }
        return $Nach }

    if (-not (Test-TextGleichOrdinal -A $status -B 'lokal_bereitgestellt')) {
        $status = & $setzeStatus -Von $status -Nach 'gespeichert_verifiziert' }

    $gleich = $false
    try {
        Set-Clipboard -Value $handoffText
        $zurueck = Get-Clipboard -Raw
        $gleich  = [string]::Equals($zurueck.Replace("`r`n", "`n"), $handoffText.Replace("`r`n", "`n"), [System.StringComparison]::Ordinal)
    } catch { $gleich = $false }

    $status = & $setzeStatus -Von $status -Nach $(if ($gleich) { 'lokal_bereitgestellt' } else { 'gespeichert_verifiziert' })

    [PSCustomObject]@{
        Kennung        = $Kennung
        HandoffId      = $handoffId
        Paket          = $paketDir
        HandoffJson    = $handoffPfad
        StatusDatei    = $statusPfad
        Bericht        = $handoff.abschluss.rel_pfad
        Anlagen        = $anlagenEintraege.Count
        AnlagenHash    = $anlagenHash
        Status         = $status
        AuftragKontext = $kontextStand
        Clipboard      = $(if ($gleich) { 'OK' } else { 'FEHLER' })
    }
    } finally { if ($null -ne $sperrHandle) { $sperrHandle.Close(); $sperrHandle.Dispose() } }
}

function Receive-Wiederbereitstellen {
    param(
        [Parameter(Mandatory=$true)][string]$Kennung,
        [Parameter(Mandatory=$true)][string]$HandoffId
    )
    Assert-Kennung -Wert $Kennung | Out-Null
    if (-not (Test-IstHex $HandoffId 32)) { throw "Ungueltige handoff_id (erwartet 32 Hex-Kleinbuchstaben): '$HandoffId'" }

    $wurzelVoll = Assert-LaufwerkspfadForm -Pfad $Base -Ort 'Basiswurzel'
    $berichtDir = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $wurzelVoll -ChildPath 'berichte') -ChildPath $Kennung) -Wurzel $wurzelVoll
    Assert-KeineReparsePoints -Pfad $berichtDir -Wurzel $wurzelVoll
    if (-not (Test-Path -LiteralPath $berichtDir -PathType Container)) { throw "Berichtsordner fehlt: $berichtDir" }

    $paketDir    = Assert-ImBereich -Pfad (Join-Path -Path (Join-Path -Path $berichtDir -ChildPath 'pakete') -ChildPath $HandoffId) -Wurzel $wurzelVoll
    $handoffPfad = Join-Path -Path $paketDir -ChildPath 'handoff.json'
    $statusPfad  = Join-Path -Path $paketDir -ChildPath 'status.json'
    if (-not (Test-Path -LiteralPath $paketDir -PathType Container)) { throw "Paket nicht gefunden: $paketDir" }

    $sperrHandle = Assert-Exklusiv -Kennung $Kennung -HandoffId $HandoffId -Wurzel $wurzelVoll
    try {

    $manifest = Get-PaketAusManifest -PaketDir $paketDir -Bereich $wurzelVoll
    Assert-PaketManifest   -Ist $manifest | Out-Null
    Assert-PaketKonsistenz -Manifest $manifest | Out-Null
    if (-not (Test-TextGleichOrdinal -A $manifest.handoff_id -B $HandoffId)) { throw "Manifest-kennung passt nicht zum Paketordner." }
    if (-not (Test-TextGleichOrdinal -A $manifest.auftrag_kennung -B $Kennung)) { throw "Manifest gehoert zu einer anderen Auftragskennung." }
    Assert-PaketBestand -PaketDir $paketDir -Bereich $wurzelVoll | Out-Null

    $status = Assert-KonfliktStatus -StatusPfad $statusPfad -HandoffId $HandoffId -Bereich $wurzelVoll
    $setzeStatus = {
        param([string]$Von, [string]$Nach)
        Assert-StatusUebergang -Von $Von -Nach $Nach | Out-Null
        $obj = [ordered]@{ schema_version = 1; handoff_id = $HandoffId; status = $Nach
                           geaendert = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        Assert-StatusVollstaendig -Status (Get-JsonObjekt -Wert $obj) | Out-Null
        Write-BytesAtomar -Ziel $statusPfad -Bytes ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5))) | Out-Null
        $r = Get-JsonObjekt -Wert (Get-Content -LiteralPath $statusPfad -Raw -Encoding UTF8 | ConvertFrom-Json)
        Assert-StatusVollstaendig -Status $r | Out-Null
        if (-not (Test-TextGleichOrdinal -A $r.status -B $Nach) -or -not (Test-TextGleichOrdinal -A $r.handoff_id -B $HandoffId)) {
            throw "Statusruecklesung fehlgeschlagen." }
        return $Nach }

    if (-not (Test-TextGleichOrdinal -A $status -B 'lokal_bereitgestellt')) {
        $status = & $setzeStatus -Von $status -Nach 'gespeichert_verifiziert' }

    $handoffText = Get-Content -LiteralPath $handoffPfad -Raw -Encoding UTF8
    $gleich = $false
    try {
        Set-Clipboard -Value $handoffText
        $zurueck = Get-Clipboard -Raw
        $gleich  = [string]::Equals($zurueck.Replace("`r`n", "`n"), $handoffText.Replace("`r`n", "`n"), [System.StringComparison]::Ordinal)
    } catch { $gleich = $false }
    $status = & $setzeStatus -Von $status -Nach $(if ($gleich) { 'lokal_bereitgestellt' } else { 'gespeichert_verifiziert' })

    [PSCustomObject]@{
        Kennung = $Kennung; HandoffId = $HandoffId; Paket = $paketDir
        HandoffJson = $handoffPfad; StatusDatei = $statusPfad
        Bericht = $manifest.abschluss.rel_pfad; Anlagen = @($manifest.anlagen).Count
        AnlagenHash = $manifest.anlagen_hash; Status = $status
        Clipboard = $(if ($gleich) { 'OK' } else { 'FEHLER' })
    }
    } finally { if ($null -ne $sperrHandle) { $sperrHandle.Close(); $sperrHandle.Dispose() } }
}

# --------------------------------------------------------------------------
# Hauptprogramm
# --------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $ModusErlaubt = @{
        'Auftrag'             = @('Eingabe','ProjektId','Profil','EmpfaengerKanal','EmpfaengerUnterhaltung','SessionId','TurnId')
        'Receive'             = @('Kennung','Abschluss','ProjektId','Profil','EmpfaengerKanal','EmpfaengerUnterhaltung','SessionId','TurnId','AbsenderKontext')
        'Wiederbereitstellen' = @('Kennung','HandoffId') }
    $Common = @('Verbose','Debug','ErrorAction','WarningAction','InformationAction','ErrorVariable',
                'WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable')
    $nutz = @($PSBoundParameters.Keys) | Where-Object {
        if ([string]::Equals($_, 'Mode', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        foreach ($c in $Common) { if ([string]::Equals($_, $c, [System.StringComparison]::OrdinalIgnoreCase)) { return $false } }
        return $true }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        if ($nutz.Count -gt 0) { throw "Ohne -Mode sind keine Nutzparameter zulaessig (angegeben: $($nutz -join ', '))." }
        Write-Output "Modus: -Mode Auftrag | Receive | Wiederbereitstellen"
    }
    else {
        $erlaubt = $ModusErlaubt[$Mode]
        foreach ($p in $nutz) {
            if ([string]::Equals($p,'Ergebnis',[System.StringComparison]::OrdinalIgnoreCase)) {
                throw "-Ergebnis ist bis zur belastbaren Korrektur DEAKTIVIERT. Verwende nur den festen Arbeitsordner arbeit\<kennung>." }
            $ok = $false
            foreach ($e in $erlaubt) { if ([string]::Equals($p,$e,[System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break } }
            if (-not $ok) { throw "Parameter '-$p' ist im Modus '$Mode' nicht zulaessig." } }

        switch ($Mode) {
            'Auftrag' {
                $aArgs = @{ Eingabe = $Eingabe }
                foreach ($n in @('ProjektId','Profil','EmpfaengerKanal','EmpfaengerUnterhaltung','SessionId','TurnId')) {
                    if ($PSBoundParameters.ContainsKey($n)) { $aArgs[$n] = $PSBoundParameters[$n] } }
                New-Auftrag @aArgs
            }
            'Wiederbereitstellen' {
                Receive-Wiederbereitstellen -Kennung $Kennung -HandoffId $HandoffId
            }
            'Receive' {
                $rArgs = @{ Kennung = $Kennung; Abschluss = $Abschluss; ProjektId = $ProjektId; Profil = $Profil
                            EmpfaengerKanal = $EmpfaengerKanal; EmpfaengerUnterhaltung = $EmpfaengerUnterhaltung
                            AbsenderKontext = $AbsenderKontext }
                foreach ($n in @('SessionId','TurnId')) {
                    if ($PSBoundParameters.ContainsKey($n)) { $rArgs[$n] = $PSBoundParameters[$n] } }
                Receive-Ergebnis @rArgs
            }
        }
    }
}