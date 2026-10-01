# APEX-Schnittstellen-Adapter v0.5 - Betriebs- und Freigabehandbuch

Stand: 2026-10-02
Bezug: adapter.ps1, SHA-256 feec3e5eb92c3d76aa6a631b1cfa86ab4f55b5037593a4d1263ac8cface02409

Dieses Dokument bedient die Bedingungen C (dokumentierte Bewertung) und D
(getrennte Betriebsentscheidung). Es erteilt selbst keine Freigabe.

---

## 1. Gegenstand und Status

| Ebene | Stand |
|---|---|
| Inhaltlich akzeptiert | Entwurfsstand nach statischer Pruefung (B1-B5, Objektartkonflikte, Laufwerkswurzel, Dokumentation) |
| Laufzeiterprobt | 26 Testfaelle in isolierter Kopie, PowerShell 5.1.28000.1, CLR 4.0.30319.42000 |
| Nicht unabhängig nachgewiesen | Byteidentitaet, vollstaendige Isolation, Ursache eines Clipboard-Einzelfehlers |
| Nicht freigegeben | Anwendung, Produktivbetrieb |

---

## 2. Betriebsvoraussetzungen (muessen vor Einsatz bestaetigt werden)

1. Nur vollqualifizierte lokale Windows-Laufwerkspfade. UNC-, Geraete- und
   Namespace-Pfade werden abgewiesen.
2. Zugeordnete Netzlaufwerke sind NICHT unterstuetzt. Die Formpruefung erkennt sie
   nicht als Netzwerkpfad; tatsaechliche Lokalitaet ist extern zu bestaetigen.
3. Wurzel, relevante Vorfahren sowie Bau-, Paket- und Sperrverzeichnisse sind gegen
   Anlegen, Loeschen, Umbenennen, Ersetzen und Berechtigungsaenderungen durch nicht
   vertrauenswuerdige Akteure geschuetzt.
4. Alle kooperierenden Adapterzugriffe nutzen dieselbe Sperrkonvention
   (Sperrverzeichnis <Wurzel>\sperren, Datei sperre-<sha256(Kennung|HandoffId)[0..31]>.lock,
   geoeffnet mit OpenOrCreate und FileShare.None).
5. Prozesse mit gleichwertigen Schreibrechten muessen ebenfalls vertrauenswuerdig und
   kooperierend sein. ACLs allein isolieren sie nicht.
6. Ist eine dieser Voraussetzungen nicht gewaehrleistet, liegt die Umgebung
   ausserhalb des unterstuetzten Betriebsmodells.

---

## 3. Bekannte Einschraenkungen (bewusst, nicht behoben)

| Nr | Einschraenkung | Wirkung | Bewertung |
|---|---|---|---|
| E1 | TOCTOU-Rest | Pfadpruefungen und Dateisystemoperationen sind nicht atomar; die kooperative Sperre schuetzt die Verzeichnisstruktur nicht | Traegt nur unter Voraussetzung 3/5 |
| E2 | finally-Maskierung in Write-BytesAtomar | Schlaegt die tmp-Loeschung fehl, kann ihre Exception den Originalfehler ueberlagern. Kein Erfolg bei Fehler, aber Ursache kann verlorengehen | Diagnosequalitaet; akzeptiert oder nachruesten |
| E3 | Recovery nicht implementiert | Restore-Paketstatus wirft ab. Ein fehlerhafter Status bleibt stehen; kein automatisches Rollback | Manueller Umgang noetig |
| E4 | Empfangsrueckkanal nicht implementiert | Receive-Bestaetigung wirft ab. empfangen_bestaetigt wird nicht vergeben und ein vorgefundener solcher Status als Konflikt abgewiesen | Kein Nachweis empfangener Lieferung |
| E5 | Clipboard-Einzelfehler | Ein Lauf meldete Clipboard=FEHLER; in 5 frischen Laeufen und 10 Race-Versuchen nicht reproduziert. Der Adapter faellt korrekt auf gespeichert_verifiziert zurueck | Ursache offen, Wirkung abgefangen |
| E6 | Ergebnismeldung Clipboard | Clipboard=OK belegt nur die eigene Ruecklesung, nicht den Empfang beim Empfaenger | Kein Empfangsnachweis |

---

## 4. Manueller Umgang mit Fehlerfaellen (zu E3/E4)

Bei einem Abbruch:

1. Nichts loeschen, nichts zuruecksetzen. Paket und Statusdatensatz unveraendert lassen.
2. Fehlertext und Paketpfad protokollieren.
3. Statusdatensatz lesen; stimmt handoff_id mit dem Paketordner ueberein?
4. Paketbestand manuell pruefen (Vollstaendigkeit, Groessen, Hashes) - ohne Hilfsmittel
   des Adapters.
5. Erst nach erfolgreicher manueller Pruefung den Status auf gespeichert_verifiziert
   setzen. Keine automatische Hochstufung auf lokal_bereitgestellt oder
   empfangen_bestaetigt.
6. Bei Widerspruch: Paket als fehlerhaft kennzeichnen und neu erstellen.

---

## 5. Betriebsentscheidung (Bedingung D) - Entscheidungsvorlage

Die verantwortliche Betriebsstelle entscheidet je Umgebung:

| Frage | Entscheidung |
|---|---|
| Sind die Betriebsvoraussetzungen (Abschnitt 2) erfuellt? | offen |
| Ist E1 (TOCTOU-Rest) unter diesen Voraussetzungen akzeptiert? | offen |
| Ist E2 (finally-Maskierung) akzeptiert oder nachzuruesten? | offen |
| Ist der manuelle Umgang (Abschnitt 4) fuer E3/E4 verbindlich? | offen |
| Ist E5 (Clipboard) akzeptiert? | offen |
| Ist der Einsatz auf einen konkreten, unveraenderten Pruefstand begrenzt? | offen |

Ein erfolgreicher Testlauf bewirkt KEINE automatische Freigabe.

---

## 6. Laufzeitnachweis (Bedingung B) - Testumgebung

| Groesse | Wert |
|---|---|
| Windows | Microsoft Windows NT 10.0.28000.0 |
| PowerShell | 5.1.28000.1 |
| CLR | 4.0.30319.42000 |
| Testwurzel | C:\Users\Admin\Desktop\apex-testlauf-20261001 |
| Testadapter | adapter_test.ps1, SHA-256 6f807cafe6ec480c8e5d1b66072750868ccdc53f9afe7963ee79594960fbb57b |
| Abweichung zum Produktionsstand | genau eine Zeile: $Base |
| Protokoll | TESTLAUF-SAUER.txt (26 Faelle, 7 OK, 19 erwartete Abweisungen) |

Der produktive Schnittstellenbestand wurde nicht veraendert.
