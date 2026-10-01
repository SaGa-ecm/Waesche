# Bequemer Aufruf der Schnittstelle fuer Projekt 'waesche'
# Beispiel:  .\apex.ps1 -Mode Auftrag -Eingabe C:\pfad\auftrag.md -ProjektId p -Profil test -EmpfaengerKanal telegram -EmpfaengerUnterhaltung chat-1
param([Parameter(ValueFromRemainingArguments=$true)]$Rest)
& (Join-Path $PSScriptRoot 'adapter.ps1') @Rest