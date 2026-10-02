<#
.SYNOPSIS
	End-to-End-Test: erzeugt MERGE-Statements und fuehrt sie gegen eine echte Instanz aus.
.DESCRIPTION
	Legt die Wegwerf-Datenbanken smgTestSrc / smgTestTgt an, prueft Upsert (inkl. DELETE,
	Nur-bei-Aenderung, IDENTITY_INSERT, xml-Vergleich), SCD Typ 2 (Typ1/Typ2/Fest, Schliessen
	fehlender Schluessel, Idempotenz) und die Duplikatpruefung. Raeumt danach wieder auf.
.EXAMPLE
	$cred = Get-Credential DEV
	.\Tests\Test-sqmMergeGenerator.ps1 -SqlInstance DEV01 -SqlCredential $cred
#>
param(
	[Parameter(Mandatory)][string]$SqlInstance,
	[System.Management.Automation.PSCredential]$SqlCredential,
	[switch]$KeepDatabases
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\sqmMergeGenerator.psd1') -Force

$mod = Get-Module sqmMergeGenerator
$cs  = & $mod { param($i, $c) New-smgConnectionString -SqlInstance $i -SqlCredential $c } $SqlInstance $SqlCredential

$script:fail = 0
function Exec([string]$sql, [string]$db = 'master') {
	$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $cs
	$b['Initial Catalog'] = $db
	$conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
	try {
		$conn.Open()
		$cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
		$cmd.ExecuteNonQuery()
	} finally { $conn.Dispose() }
}
function Scalar([string]$sql, [string]$db = 'smgTestTgt') {
	$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $cs
	$b['Initial Catalog'] = $db
	$conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
	try {
		$conn.Open()
		$cmd = $conn.CreateCommand(); $cmd.CommandText = $sql
		$cmd.ExecuteScalar()
	} finally { $conn.Dispose() }
}
function Query([string]$sql, [string]$db = 'smgTestTgt') {
	$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $cs
	$b['Initial Catalog'] = $db
	& $mod { param($c, $q) Invoke-smgSqlQuery -ConnectionString $c -Query $q } $b.ConnectionString $sql | Select-Object -First 1
}
function Check([string]$name, $actual, $expected) {
	if ("$actual" -eq "$expected") { Write-Host "  [OK]   $name = $actual" -ForegroundColor Green }
	else { Write-Host "  [FAIL] $name = $actual (erwartet $expected)" -ForegroundColor Red; $script:fail++ }
}
# Mapping wie die GUI: gleiche Namen, Typinfos aus dem Ziel
function Get-Map($srcTable, $tgtSchema, $tgtTable, [hashtable]$changeTypes = @{}, [string[]]$exclude = @()) {
	$p = @{ SqlInstance = $SqlInstance; SqlCredential = $SqlCredential }
	$s = Get-sqmMergeColumn @p -Database smgTestSrc -Table $srcTable
	$t = Get-sqmMergeColumn @p -Database smgTestTgt -Schema $tgtSchema -Table $tgtTable
	foreach ($c in $s) {
		$tc = $t | Where-Object { $_.ColumnName -eq $c.ColumnName -and $_.IsWritable }
		if (-not $tc -or $c.ColumnName -in $exclude) { continue }
		@{
			SourceColumn = $c.ColumnName; TargetColumn = $tc.ColumnName
			ChangeType = $changeTypes[$c.ColumnName]
			TargetDataType = $tc.BaseType; TargetIsClrType = $tc.IsClrType; TargetIsIdentity = $tc.IsIdentity
		}
	}
}

Write-Host "== Setup auf $SqlInstance" -ForegroundColor Cyan
foreach ($db in 'smgTestSrc', 'smgTestTgt') {
	Exec "IF DB_ID('$db') IS NOT NULL BEGIN ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db]; END; CREATE DATABASE [$db];" | Out-Null
}
Exec @"
CREATE TABLE dbo.Customer (CustomerNo int NOT NULL PRIMARY KEY, Name nvarchar(100) NOT NULL,
    City nvarchar(50) NULL, Segment varchar(10) NULL, Notes xml NULL);
INSERT dbo.Customer VALUES (1,N'Alpha',N'Berlin','A',NULL),(2,N'Beta',N'Hamburg','B',N'<n>x</n>'),(3,N'Gamma',NULL,'C',NULL);
CREATE TABLE dbo.Product (Id int NOT NULL PRIMARY KEY, Title nvarchar(50) NOT NULL);
INSERT dbo.Product VALUES (10,N'Ten'),(20,N'Twenty');
"@ smgTestSrc | Out-Null
Exec @"
CREATE TABLE dbo.Customer (CustomerNo int NOT NULL PRIMARY KEY, Name nvarchar(100) NOT NULL,
    City nvarchar(50) NULL, Segment varchar(10) NULL, Notes xml NULL, RowVer rowversion);
CREATE TABLE dbo.Product (Id int IDENTITY(1,1) NOT NULL PRIMARY KEY, Title nvarchar(50) NOT NULL);
EXEC('CREATE SCHEMA dim');
CREATE TABLE dim.Customer (CustomerSK int IDENTITY(1,1) NOT NULL PRIMARY KEY, CustomerNo int NOT NULL,
    Name nvarchar(100) NOT NULL, City nvarchar(50) NULL, Segment varchar(10) NULL,
    ValidFrom datetime2(3) NOT NULL, ValidTo datetime2(3) NULL, IsCurrent bit NOT NULL);
"@ smgTestTgt | Out-Null

$common = @{ SourceDatabase = 'smgTestSrc'; TargetDatabase = 'smgTestTgt' }

# ------------------------------------------------------------------------------------------
Write-Host "== Upsert" -ForegroundColor Cyan
$sql = New-sqmMergeStatement @common -SourceTable Customer -TargetTable Customer `
	-ColumnMapping (Get-Map Customer dbo Customer) -KeyColumns CustomerNo -DeleteNotMatchedBySource -HoldLock -OutputAction
Check 'Erstlauf rows affected' (Exec $sql smgTestTgt) 3
Check 'Wiederholung ohne Aenderung' (Exec $sql smgTestTgt) 0
Exec "UPDATE dbo.Customer SET Name=N'Alpha2' WHERE CustomerNo=1; UPDATE dbo.Customer SET Notes=N'<n>y</n>' WHERE CustomerNo=3;
      DELETE dbo.Customer WHERE CustomerNo=2; INSERT dbo.Customer VALUES (4,N'Delta',N'Koeln','D',NULL);" smgTestSrc | Out-Null
Check '2 Updates + 1 Delete + 1 Insert' (Exec $sql smgTestTgt) 4
Check 'Name uebernommen' (Scalar "SELECT Name FROM dbo.Customer WHERE CustomerNo=1") 'Alpha2'
Check 'xml-Aenderung (NULL->Wert) erkannt' (Scalar "SELECT CAST(Notes AS nvarchar(max)) FROM dbo.Customer WHERE CustomerNo=3") '<n>y</n>'
Check 'Geloeschte Zeile weg' (Scalar "SELECT COUNT(*) FROM dbo.Customer WHERE CustomerNo=2") 0
Check 'Wiederholung ohne Aenderung' (Exec $sql smgTestTgt) 0

Write-Host "== Upsert mit IDENTITY_INSERT" -ForegroundColor Cyan
$sql = New-sqmMergeStatement @common -SourceTable Product -TargetTable Product -ColumnMapping (Get-Map Product dbo Product) -KeyColumns Id
Check 'IDENTITY_INSERT im Statement' ($sql -match 'IDENTITY_INSERT .* ON') $true
Check 'Erstlauf' (Exec $sql smgTestTgt) 2
Exec "UPDATE dbo.Product SET Title=N'Ten!' WHERE Id=10" smgTestSrc | Out-Null
Check 'Update mit Identity-Schluessel' (Exec $sql smgTestTgt) 1
Check 'Id 20 erhalten' (Scalar "SELECT Title FROM dbo.Product WHERE Id=20") 'Twenty'

# ------------------------------------------------------------------------------------------
Write-Host "== SCD Typ 2" -ForegroundColor Cyan
Exec "TRUNCATE TABLE dbo.Customer; INSERT dbo.Customer VALUES (1,N'Alpha',N'Berlin','A',NULL),(2,N'Beta',N'Hamburg','B',NULL),(3,N'Gamma',NULL,'C',NULL);" smgTestSrc | Out-Null
$map = Get-Map Customer dim Customer -changeTypes @{ Name = 'Type1'; City = 'Type2'; Segment = 'Fixed' }
$scd = New-sqmMergeStatement @common -SourceTable Customer -TargetSchema dim -TargetTable Customer `
	-ColumnMapping $map -KeyColumns CustomerNo -Mode Scd2 -DeleteNotMatchedBySource -DuplicateKeyCheck `
	-ValidFromColumn ValidFrom -ValidToColumn ValidTo -CurrentFlagColumn IsCurrent
# Trigger + Fremdschluessel am Ziel: mit Composable DML waere das nicht erlaubt
Exec "CREATE TABLE dim.Audit (N int); CREATE TABLE dbo.FactSale (CustomerSK int REFERENCES dim.Customer(CustomerSK));" smgTestTgt | Out-Null
Exec "CREATE TRIGGER dim.trCustomer ON dim.Customer AFTER INSERT, UPDATE AS INSERT dim.Audit SELECT COUNT(*) FROM inserted;" smgTestTgt | Out-Null
$sum = Query $scd
Check 'Zusammenfassung NeueSchluessel' $sum.NeueSchluessel 3
Check 'Trigger hat gefeuert, sah 3 Zeilen' (Scalar "SELECT SUM(N) FROM dim.Audit") 3
Check 'Erstlauf: 3 Zeilen' (Scalar "SELECT COUNT(*) FROM dim.Customer") 3
Check 'Erstlauf: 3 aktuell' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE IsCurrent=1 AND ValidTo IS NULL") 3
Exec $scd smgTestTgt | Out-Null
Check 'Wiederholung: keine neue Version' (Scalar "SELECT COUNT(*) FROM dim.Customer") 3

Exec "UPDATE dbo.Customer SET City=N'Muenchen' WHERE CustomerNo=1" smgTestSrc | Out-Null
$sum = Query $scd
Check 'Zusammenfassung NeueVersionen' $sum.NeueVersionen 1
Check 'Typ 2: neue Version' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE CustomerNo=1") 2
Check 'Typ 2: alte Version geschlossen' (Scalar "SELECT City FROM dim.Customer WHERE CustomerNo=1 AND IsCurrent=0 AND ValidTo IS NOT NULL") 'Berlin'
Check 'Typ 2: aktuelle Version' (Scalar "SELECT City FROM dim.Customer WHERE CustomerNo=1 AND IsCurrent=1 AND ValidTo IS NULL") 'Muenchen'

Exec "UPDATE dbo.Customer SET City=NULL WHERE CustomerNo=2" smgTestSrc | Out-Null
Exec $scd smgTestTgt | Out-Null
Check 'Typ 2: Wert->NULL erkannt' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE CustomerNo=2") 2

Exec "UPDATE dbo.Customer SET Name=N'Alpha-Neu' WHERE CustomerNo=1" smgTestSrc | Out-Null
$sum = Query $scd
Check 'Zusammenfassung Typ1Aktualisiert' $sum.Typ1Aktualisiert 2
Check 'Typ 1: keine neue Version' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE CustomerNo=1") 2
Check 'Typ 1: alle Versionen ueberschrieben' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE CustomerNo=1 AND Name=N'Alpha-Neu'") 2

Exec "UPDATE dbo.Customer SET Segment='Z' WHERE CustomerNo=3" smgTestSrc | Out-Null
Exec $scd smgTestTgt | Out-Null
Check 'Fest: nicht aktualisiert' (Scalar "SELECT Segment FROM dim.Customer WHERE CustomerNo=3") 'C'

Exec "DELETE dbo.Customer WHERE CustomerNo=3" smgTestSrc | Out-Null
$sum = Query $scd
Check 'Zusammenfassung GeschlosseneSchluessel' $sum.GeschlosseneSchluessel 1
Check 'Fehlender Schluessel geschlossen' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE CustomerNo=3 AND IsCurrent=0 AND ValidTo IS NOT NULL") 1
Check 'Keine NULL-Zeile eingefuegt' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE CustomerNo IS NULL") 0

Exec "INSERT dbo.Customer VALUES (3,N'Gamma',N'Bonn','C',NULL)" smgTestSrc | Out-Null
Exec $scd smgTestTgt | Out-Null
Check 'Wiederkehrender Schluessel: neue aktuelle Version' (Scalar "SELECT COUNT(*) FROM dim.Customer WHERE CustomerNo=3 AND IsCurrent=1") 1
$before = Scalar "SELECT COUNT(*) FROM dim.Customer"
Exec $scd smgTestTgt | Out-Null
Check 'Idempotent' (Scalar "SELECT COUNT(*) FROM dim.Customer") $before

Write-Host "== SCD Typ 2 nur mit ValidTo (offenes Ende 9999-12-31)" -ForegroundColor Cyan
Exec "CREATE TABLE dim.Customer2 (CustomerNo int NOT NULL, City nvarchar(50) NULL, ValidFrom datetime2(3) NOT NULL, ValidTo datetime2(3) NOT NULL);" smgTestTgt | Out-Null
$m2 = Get-Map Customer dim Customer2
$scd2 = New-sqmMergeStatement @common -SourceTable Customer -TargetSchema dim -TargetTable Customer2 -ColumnMapping $m2 `
	-KeyColumns CustomerNo -Mode Scd2 -ValidFromColumn ValidFrom -ValidToColumn ValidTo -OpenEndValue "'9999-12-31'"
Exec $scd2 smgTestTgt | Out-Null
Exec "UPDATE dbo.Customer SET City=N'Paris' WHERE CustomerNo=1" smgTestSrc | Out-Null
Exec $scd2 smgTestTgt | Out-Null
Check 'Versionen' (Scalar "SELECT COUNT(*) FROM dim.Customer2") 4
Check 'Offen' (Scalar "SELECT COUNT(*) FROM dim.Customer2 WHERE ValidTo='9999-12-31'") 3

Write-Host "== Duplikatpruefung" -ForegroundColor Cyan
Exec "CREATE VIEW dbo.vDup AS SELECT CustomerNo, Name, City, Segment FROM dbo.Customer UNION ALL SELECT CustomerNo, Name, City, Segment FROM dbo.Customer WHERE CustomerNo = 1;" smgTestSrc | Out-Null
$dupSql = New-sqmMergeStatement @common -SourceTable vDup -TargetTable Customer -ColumnMapping @{ CustomerNo = 'CustomerNo'; Name = 'Name' } -KeyColumns CustomerNo -DuplicateKeyCheck
$err = $null
try { Exec $dupSql smgTestTgt | Out-Null } catch { $err = $_.Exception.InnerException.Message; if (-not $err) { $err = $_.Exception.Message } }
Check 'THROW 50001 bei doppeltem Schluessel' ([bool]($err -match 'doppelte Schluesselwerte')) $true

Write-Host "== Validierung" -ForegroundColor Cyan
$e = $null; try { New-sqmMergeStatement @common -SourceTable a -TargetTable b -ColumnMapping @{ x = 'x' } -KeyColumns y } catch { $e = $_.Exception.Message }
Check 'Schluessel nicht im Mapping' ([bool]($e -match 'nicht im Mapping')) $true
$e = $null; try { New-sqmMergeStatement @common -SourceTable a -TargetTable b -ColumnMapping @{ x = 'x' } -KeyColumns x -Mode Scd2 } catch { $e = $_.Exception.Message }
Check 'SCD2 ohne Verwaltungsspalten' ([bool]($e -match 'benoetigt')) $true
$e = $null; try { New-sqmMergeStatement @common -SourceTable a -TargetTable b -ColumnMapping @(@{ SourceColumn = 'x'; TargetColumn = 'x' }, @{ SourceColumn = 'id'; TargetColumn = 'SK'; TargetIsIdentity = $true }) -KeyColumns x -Mode Scd2 -CurrentFlagColumn f } catch { $e = $_.Exception.Message }
Check 'SCD2 lehnt Identitaetsspalte ab' ([bool]($e -match 'Identitaetsspalte')) $true

if (-not $KeepDatabases) {
	foreach ($db in 'smgTestSrc', 'smgTestTgt') {
		Exec "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db];" | Out-Null
	}
}
Write-Host ''
if ($script:fail) { Write-Host "$script:fail Test(s) fehlgeschlagen" -ForegroundColor Red; exit 1 }
Write-Host 'Alle Tests bestanden' -ForegroundColor Green
