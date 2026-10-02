# sqmMergeGenerator - Changelog

## [0.1.0.0] - 2026-10-02

### Erste Version

- WinForms-GUI `Show-sqmMergeGeneratorGui`: Server verbinden (Windows/SQL-Auth,
  TrustServerCertificate), Quell- und Ziel-Datenbank/-Tabelle per Combobox, drei Spalten
  nebeneinander (Quellspalten, Mapping Quelle -> Ziel im Stil des SSIS-Editors, Schluesselspalten),
  darunter Optionen und das sofort neu erzeugte Statement. Kopieren, Speichern, Syntaxpruefung
  (SET NOEXEC ON) und Ausfuehren mit Rueckfrage.
- `New-sqmMergeStatement`: Generator ohne Datenbankverbindung.
  - Upsert / SCD Typ 1: Update nur bei echter Aenderung (NULL-sicher per EXCEPT), optional DELETE
    fuer in der Quelle fehlende Zeilen, HOLDLOCK, OUTPUT $action, IDENTITY_INSERT automatisch.
  - SCD Typ 2: Aenderungsart pro Spalte (Typ 2 Historie / Typ 1 Ueberschreiben / Fest),
    Gueltig ab/bis und Aktuell-Flag, offenes Ende NULL oder festes Datum, Schliessen fehlender
    Schluessel. Umsetzung per MERGE ... OUTPUT INTO #Temp + INSERT in einer Transaktion statt
    Composable DML, damit auch Ziele mit Triggern und Fremdschluesseln funktionieren. Liefert eine
    Zusammenfassung (neue Schluessel, neue Versionen, geschlossen, Typ-1-Updates).
  - Duplikatpruefung der Quelle vor dem MERGE (THROW 50001), Quellfilter (WHERE).
  - xml/text/ntext/image und CLR-Typen werden fuer den Aenderungsvergleich gecastet.
- `Get-sqmMergeDatabase`, `Get-sqmMergeTable`, `Get-sqmMergeColumn`: Metadaten per SqlClient,
  keine dbatools-Abhaengigkeit.
- Live-Test `Tests\Test-sqmMergeGenerator.ps1` (36 Pruefungen), auf DEV01 (SQL Server 2022)
  unter PowerShell 5.1 und 7 bestanden.
