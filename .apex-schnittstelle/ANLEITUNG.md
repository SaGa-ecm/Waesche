# ANLEITUNG - Schnittstelle in Projekt 'waesche'

Projekt   : C:\Users\Admin\waesche-repo
Schnittstelle: C:\Users\Admin\waesche-repo\.apex-schnittstelle
Eingerichtet: 2026-10-02 00:24:39

---

# ANLEITUNG - APEX-Schnittstellen-Adapter v0.5

Für den Bediener. Stand 2026-10-02. Freigegeben und im produktiven Bestand.

---

## 1. Was das Werkzeug tut

Es übergibt einen **Arbeitsauftrag** an einen Bearbeiter und nimmt dessen **Ergebnis**
in ein prüfbares Paket zurück. Jeder Vorgang ist hashgesichert und nachvollziehbar.

Drei Schritte, drei Modi:

| Modus | Was passiert |
|---|---|
| `Auftrag` | Nimmt eine Auftragsdatei an, legt Auftrag + Arbeitsordner + Berichtsordner an |
| `Receive` | Nimmt das Ergebnis an, baut ein Paket, prüft alles, legt es in die Zwischenablage |
| `Wiederbereitstellen` | Gibt ein bestehendes Paket erneut aus, ohne es neu zu bauen |

**Zwischen `Auftrag` und `Receive` arbeitet der Bearbeiter** — er füllt den Arbeitsordner.

---

## 2. Wo alles liegt

Wurzel (fest im Adapter):
```
C:\Users\Admin\Desktop\KI-Schnittstelle-v0.1-20260926-171435-7ef96d\KI-Schnittstelle-v0.2-20260928-175730-2e7b1af6
```

| Ordner | Inhalt |
|---|---|
| `auftraege\<Kennung>\` | `auftrag.md`, `meta.txt`, `kontext.json` |
| `arbeit\<Kennung>\` | **Der Bearbeiter legt hier seine Ergebnisse ab** |
| `berichte\<Kennung>\pakete\<HandoffId>\` | Das fertige Paket |
| `sperren\` | Sperrdateien (nicht löschen) |

---

## 3. Ablauf in drei Befehlen

### Schritt 1 — Auftrag anlegen

```powershell
cd 'C:\Users\Admin\Desktop\KI-Schnittstelle-v0.1-20260926-171435-7ef96d\KI-Schnittstelle-v0.2-20260928-175730-2e7b1af6'

.\adapter.ps1 -Mode Auftrag `
  -Eingabe 'C:\pfad\zum\auftragstext.md' `
  -ProjektId 'mein-projekt' `
  -Profil 'test' `
  -EmpfaengerKanal 'telegram' `
  -EmpfaengerUnterhaltung 'chat-1' `
  -SessionId 's-1' -TurnId 't-1'
```

**Ausgabe:** eine **Kennung** (32 Hex-Zeichen). **Notieren** — die brauchst du in Schritt 2.

**Wichtig:** Die vier Kontextangaben (`ProjektId`, `Profil`, `EmpfaengerKanal`,
`EmpfaengerUnterhaltung`) gelten **gemeinsam** — entweder alle vier oder keine.
Ohne Kontext ist der Auftrag ungebunden und kann **nicht** per `Receive` angenommen werden.

`-Profil` muss `lieferung`, `test` oder `validierung` sein.

### Schritt 2 — Bearbeiter arbeiten lassen

Der Bearbeiter legt seine Dateien in den **Arbeitsordner**:
```
...\arbeit\<Kennung>\
```
Eine Datei davon ist der **Abschlussbericht** (z. B. `abschluss.md`) — die wird später
namentlich benannt und **nicht** als Anlage geführt.

### Schritt 3 — Ergebnis annehmen

```powershell
.\adapter.ps1 -Mode Receive `
  -Kennung 'DEINE-KENNUNG' `
  -Abschluss 'abschluss.md' `
  -ProjektId 'mein-projekt' `
  -Profil 'test' `
  -EmpfaengerKanal 'telegram' `
  -EmpfaengerUnterhaltung 'chat-1' `
  -SessionId 's-1' -TurnId 't-1'
```

**Ausgabe:**
```
Kennung        : ...
HandoffId      : ...   <- Paketkennung, für Wiederbereitstellen nötig
Status         : lokal_bereitgestellt
Anlagen        : 2
Clipboard      : OK
```

Der **Manifesttext liegt danach in der Zwischenablage** und wird an den Empfänger gesendet.

### Schritt 3b — Erneut ausgeben (optional)

```powershell
.\adapter.ps1 -Mode Wiederbereitstellen -Kennung 'DEINE-KENNUNG' -HandoffId 'PAKET-ID'
```

---

## 4. Was der Status bedeutet

| Status | Bedeutung |
|---|---|
| `vorbereitet` | Noch kein Statusdatensatz vorhanden |
| `gespeichert_verifiziert` | Paket geprüft und gespeichert — **Zwischenablage war nicht OK** |
| `lokal_bereitgestellt` | Paket geprüft und in die Zwischenablage gelegt |

**`empfangen_bestaetigt` gibt es nicht** — der Empfangsrückkanal ist nicht gebaut.
Ein vorgefundener solcher Status wird als **Konflikt** abgewiesen.

---

## 5. Was NICHT geht (und warum)

| Versuch | Reaktion |
|---|---|
| Relativer Pfad als Eingabe | abgewiesen — nur `Laufwerk:\...` |
| UNC-Pfad `\\server\share\...` | abgewiesen |
| Netzlaufwerk `Z:\...` | **wird nicht erkannt** — Voraussetzung ist, dass es wirklich lokal ist |
| `..` im Abschlusspfad | abgewiesen |
| Nur ein Teil der Kontextangaben | abgewiesen |
| Falsches Profil | abgewiesen |
| `-Ergebnis` benutzen | abgewiesen — Funktion deaktiviert |
| Parameter ohne `-Mode` | abgewiesen |
| Parameter, den der Modus nicht kennt | abgewiesen |

**Bei Fehlern passiert nichts Schlimmes:** Der Adapter bricht ab, bevor er schreibt.
Ein Fehler wird **nie** zu einem Erfolg.

---

## 6. Häufige Meldungen

| Meldung | Bedeutung / was tun |
|---|---|
| `Arbeitsordner existiert nicht` | Kennung falsch, oder `Auftrag` nie gelaufen |
| `Auftragsbindung blockiert: kein Kontext vorhanden` | Auftrag wurde ohne Kontext angelegt — mit `Auftrag` und Kontext neu anlegen |
| `Uebergebene Session weicht vom Auftragskontext ab` | `-SessionId` stimmt nicht mit Schritt 1 überein |
| `Fachlicher Abschluss nicht gefunden` | Dateiname falsch, oder liegt nicht im Arbeitsordner |
| `Fachlicher Abschluss ist leer` | Berichtsdatei hat 0 Bytes |
| `Anlagengroesse weicht ab` | Datei wurde nach der Paketierung verändert |
| `Bestandskonflikt: ... ist aber keine Datei` | Ein **Ordner** liegt dort, wo eine Datei erwartet wird |
| `KONFLIKT: Status 'empfangen_bestaetigt'` | Nicht verifizierbar — Datensatz bleibt unverändert |
| `Sperre konnte nicht erworben werden` | Ein anderer Vorgang läuft — kurz warten, dann erneut |
| `Clipboard: FEHLER` | Zwischenablage nicht lesbar — Status bleibt `gespeichert_verifiziert`, Manifest selbst aus `handoff.json` holen |

---

## 7. Notfall: Rollback

Der Vorgängerstand liegt gesichert:

```powershell
cd 'C:\Users\Admin\Desktop\KI-Schnittstelle-v0.1-20260926-171435-7ef96d\KI-Schnittstelle-v0.2-20260928-175730-2e7b1af6'

Copy-Item '.\adapter.ps1.VOR-UEBERGABE-20261002-001718.bak' '.\adapter.ps1' -Force
```

---

## 8. Manueller Umgang bei Abbruch

Wenn ein Vorgang mittendrin abbricht:

1. **Nichts löschen, nichts zurücksetzen.**
2. Fehlertext und Paketpfad notieren.
3. `status.json` lesen — passt `handoff_id` zum Paketordner?
4. Paket manuell prüfen: Dateien vollständig? Größen plausibel?
5. Erst nach erfolgreicher Prüfung `status.json` auf `gespeichert_verifiziert` setzen.
6. **Kein** Hochstufen auf `lokal_bereitgestellt` oder `empfangen_bestaetigt`.
7. Bei Widerspruch: Paket als fehlerhaft kennzeichnen, Vorgang neu anlegen.

---

## 9. Vor jedem Einsatz sicherstellen

- [ ] Alle Pfade sind **echte lokale** Laufwerkspfade (keine Netzlaufwerke)
- [ ] Wurzel und Unterordner sind gegen fremde Änderung geschützt
- [ ] **Alle** Zugriffe nutzen dieselbe Sperrkonvention (nicht parallel mit anderen Werkzeugen)
- [ ] `sperren\` wird nicht manuell geleert

---

## 10. Belegstand

| Gegenstand | Wert |
|---|---|
| Adapter | `adapter.ps1`, 1112 Zeilen, 55 Funktionen |
| SHA-256 | `feec3e5eb92c3d76aa6a631b1cfa86ab4f55b5037593a4d1263ac8cface02409` |
| Schema | `handoff-schema-v2.json`, SHA-256 `d76926b99a0cc3c2aa8d895363fcc9efbc2f9d701596a6581c76d5d9a8c3cb14` |
| Umgebung | Windows 10.0.28000, PowerShell 5.1.28000.1, CLR 4.0.30319.42000 |
| Schnittstellentest | `SCHNITTSTELLENTEST.txt` — 12 Fälle, 7 OK, 6 Abweisungen |
| Testlauf | `TESTLAUF-SAUER.txt` — 26 Fälle, 7 OK, 19 Abweisungen |
| Betriebshandbuch | `BETRIEBSHANDBUCH.md` |
