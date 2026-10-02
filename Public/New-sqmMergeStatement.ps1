function New-sqmMergeStatement {
	<#
	.SYNOPSIS
		Erzeugt ein T-SQL MERGE-Statement aus Quelle, Ziel, Spalten-Mapping und Schluesselspalten.

	.DESCRIPTION
		Reiner Text-Generator, keine Datenbankverbindung noetig.

		Modus 'Upsert' (Standard, entspricht SCD Typ 1):
		  MERGE mit UPDATE (optional nur bei echter Aenderung, NULL-sicher per EXCEPT),
		  INSERT und optional DELETE fuer Zeilen, die in der Quelle fehlen.

		Modus 'Scd2' (Slowly Changing Dimension Typ 2):
		  Pro Spalte bestimmt ChangeType das Verhalten:
		    Type2 - Aenderung schliesst die aktuelle Version und fuegt eine neue ein (Historie)
		    Type1 - Aenderung wird in ALLEN Versionen des Schluessels ueberschrieben
		    Fixed - wird nie aktualisiert, nur beim Einfuegen gesetzt
		  Umgesetzt als MERGE ... OUTPUT INTO #Temp plus INSERT der neuen Versionen in einer
		  Transaktion (kein Composable DML, daher auch mit Triggern und Fremdschluesseln am Ziel).
		  Am Ende liefert das Statement eine Zeile mit NeueSchluessel, NeueVersionen,
		  GeschlosseneSchluessel und Typ1Aktualisiert.
		  Benoetigt mindestens -CurrentFlagColumn oder -ValidToColumn.

		Im Upsert-Modus werden Type1 und Type2 gleich behandelt (ueberschreiben), Fixed wird
		nicht aktualisiert.

	.PARAMETER ColumnMapping
		Liste von Objekten/Hashtables mit SourceColumn, TargetColumn und optional ChangeType
		(Type1|Type2|Fixed, Default Type1 bzw. Type2 im Scd2-Modus), TargetDataType,
		TargetIsClrType und TargetIsIdentity. Alternativ eine einzelne Hashtable Quelle=Ziel.

	.PARAMETER KeyColumns
		Join-Spalten (Zielspaltennamen; Quellspaltennamen werden ebenfalls aufgeloest).
		Im Scd2-Modus der fachliche Schluessel (Business Key), nicht der Surrogatschluessel.

	.EXAMPLE
		New-sqmMergeStatement -SourceDatabase Staging -SourceTable Customer `
			-TargetDatabase DWH -TargetTable Customer `
			-ColumnMapping @{ CustomerNo='CustomerNo'; Name='Name'; City='City' } `
			-KeyColumns CustomerNo -DeleteNotMatchedBySource

	.EXAMPLE
		$map = @(
			@{ SourceColumn='CustomerNo'; TargetColumn='CustomerNo' }
			@{ SourceColumn='Name';       TargetColumn='Name';  ChangeType='Type1' }
			@{ SourceColumn='City';       TargetColumn='City';  ChangeType='Type2' }
		)
		New-sqmMergeStatement -SourceDatabase Staging -SourceTable Customer -TargetDatabase DWH `
			-TargetSchema dim -TargetTable Customer -ColumnMapping $map -KeyColumns CustomerNo `
			-Mode Scd2 -ValidFromColumn ValidFrom -ValidToColumn ValidTo -CurrentFlagColumn IsCurrent
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)][string]$SourceDatabase,
		[string]$SourceSchema = 'dbo',
		[Parameter(Mandatory)][string]$SourceTable,
		[Parameter(Mandatory)][string]$TargetDatabase,
		[string]$TargetSchema = 'dbo',
		[Parameter(Mandatory)][string]$TargetTable,
		[Parameter(Mandatory)][object[]]$ColumnMapping,
		[Parameter(Mandatory)][string[]]$KeyColumns,
		[ValidateSet('Upsert', 'Scd2')][string]$Mode = 'Upsert',
		[bool]$UpdateOnlyChanged = $true,
		# Upsert: fehlende Zeilen loeschen / Scd2: aktuelle Version fehlender Schluessel schliessen
		[switch]$DeleteNotMatchedBySource,
		[switch]$HoldLock,
		[switch]$OutputAction,
		[switch]$DuplicateKeyCheck,
		[switch]$IdentityInsert,
		[string]$SourceFilter,
		[string]$ValidFromColumn,
		[string]$ValidToColumn,
		[string]$CurrentFlagColumn,
		[string]$OpenEndValue = 'NULL'
	)

	$Q = { param($n) '[' + $n.Replace(']', ']]') + ']' }
	$nl = "`r`n"

	# ---------------------------------------------------------------------------------------
	# Mapping normalisieren
	# ---------------------------------------------------------------------------------------
	$items = @($ColumnMapping)
	if ($items.Count -eq 1 -and $items[0] -is [System.Collections.IDictionary] -and
		-not $items[0].Contains('SourceColumn')) {
		$items = @($items[0].GetEnumerator() | ForEach-Object { @{ SourceColumn = [string]$_.Key; TargetColumn = [string]$_.Value } })
	}
	$defaultChange = if ($Mode -eq 'Scd2') { 'Type2' } else { 'Type1' }
	$map = foreach ($m in $items) {
		$get = { param($o, $p) if ($o -is [System.Collections.IDictionary]) { $o[$p] } else { $o.$p } }
		$src = [string](& $get $m 'SourceColumn')
		$tgt = [string](& $get $m 'TargetColumn')
		if (-not $src -or -not $tgt) { continue }
		$ct = [string](& $get $m 'ChangeType'); if (-not $ct) { $ct = $defaultChange }
		if ($ct -notin 'Type1', 'Type2', 'Fixed') { throw "Ungueltiger ChangeType '$ct' fuer Spalte '$tgt' (erlaubt: Type1, Type2, Fixed)." }
		[pscustomobject]@{
			Src        = $src
			Tgt        = $tgt
			ChangeType = $ct
			TgtType    = [string](& $get $m 'TargetDataType')
			IsClr      = [bool](& $get $m 'TargetIsClrType')
			IsIdentity = [bool](& $get $m 'TargetIsIdentity')
			IsKey      = $false
		}
	}
	$map = @($map)
	if ($map.Count -eq 0) { throw 'Kein Spalten-Mapping angegeben.' }
	$dup = $map | Group-Object Tgt | Where-Object Count -gt 1
	if ($dup) { throw ("Zielspalte(n) mehrfach gemappt: {0}" -f (($dup | ForEach-Object Name) -join ', ')) }

	# Schluessel aufloesen (Ziel- oder Quellname)
	$keys = foreach ($k in $KeyColumns) {
		$hit = $map | Where-Object { $_.Tgt -eq $k } | Select-Object -First 1
		if (-not $hit) { $hit = $map | Where-Object { $_.Src -eq $k } | Select-Object -First 1 }
		if (-not $hit) { throw "Schluesselspalte '$k' ist nicht im Mapping enthalten." }
		$hit.IsKey = $true
		$hit
	}
	$seen = @{}
	$keys = @($keys | Where-Object { if ($seen.ContainsKey($_.Tgt)) { $false } else { $seen[$_.Tgt] = 1; $true } })
	if ($keys.Count -eq 0) { throw 'Mindestens eine Schluesselspalte ist erforderlich.' }

	if ($Mode -eq 'Scd2') {
		if (-not $CurrentFlagColumn -and -not $ValidToColumn) {
			throw 'SCD Typ 2 benoetigt eine Aktuell-Kennzeichen-Spalte und/oder eine Gueltig-bis-Spalte.'
		}
		foreach ($c in @($ValidFromColumn, $ValidToColumn, $CurrentFlagColumn) | Where-Object { $_ }) {
			if ($map | Where-Object Tgt -eq $c) { throw "SCD-Verwaltungsspalte '$c' darf nicht gleichzeitig gemappt sein." }
		}
		if (@($ValidFromColumn, $ValidToColumn, $CurrentFlagColumn | Where-Object { $_ } | Select-Object -Unique).Count -ne
			@($ValidFromColumn, $ValidToColumn, $CurrentFlagColumn | Where-Object { $_ }).Count) {
			throw 'Gueltig ab, Gueltig bis und Aktuell-Kennzeichen muessen verschiedene Spalten sein.'
		}
	}
	if (-not $OpenEndValue) { $OpenEndValue = 'NULL' }

	# Vergleichsausdruck fuer EXCEPT: Typen, die nicht vergleichbar sind, werden gecastet
	$cmp = {
		param($alias, $col, $type, $isClr)
		$e = "$alias.$(& $Q $col)"
		if ($isClr -or $type -in 'geography', 'geometry', 'hierarchyid') { return "CAST($e AS varbinary(max))" }
		switch ($type) {
			'text'  { "CAST($e AS varchar(max))" }
			'ntext' { "CAST($e AS nvarchar(max))" }
			'xml'   { "CAST($e AS nvarchar(max))" }
			'image' { "CAST($e AS varbinary(max))" }
			default { $e }
		}
	}
	$changeCheck = {
		param($cols, $indent)
		$s = ($cols | ForEach-Object { & $cmp 'S' $_.Src $_.TgtType $_.IsClr }) -join ', '
		$t = ($cols | ForEach-Object { & $cmp 'T' $_.Tgt $_.TgtType $_.IsClr }) -join ', '
		"EXISTS (SELECT $s$nl$indent        EXCEPT$nl$indent        SELECT $t)"
	}

	$srcName = '{0}.{1}.{2}' -f (& $Q $SourceDatabase), (& $Q $SourceSchema), (& $Q $SourceTable)
	$tgtName = '{0}.{1}.{2}' -f (& $Q $TargetDatabase), (& $Q $TargetSchema), (& $Q $TargetTable)

	$srcCols  = @($map | ForEach-Object Src | Select-Object -Unique)
	$using    = "    SELECT " + (($srcCols | ForEach-Object { & $Q $_ }) -join ",$nl           ") + "$nl    FROM $srcName"
	if ($SourceFilter -and $SourceFilter.Trim()) { $using += "$nl    WHERE $($SourceFilter.Trim())" }
	$usingBlock = "USING ($nl$using$nl) AS S"

	$on = ($keys | ForEach-Object { "T.$(& $Q $_.Tgt) = S.$(& $Q $_.Src)" }) -join "$nl   AND "
	$hold = if ($HoldLock) { ' WITH (HOLDLOCK)' } else { '' }

	$identity = $IdentityInsert -or [bool]($map | Where-Object IsIdentity)
	if ($Mode -eq 'Scd2') {
		$idCols = @($map | Where-Object IsIdentity)
		if ($idCols) {
			throw ("Identitaetsspalte(n) im SCD-2-Modus nicht mappen (Surrogatschluessel vergibt die Tabelle selbst): {0}" -f (($idCols | ForEach-Object Tgt) -join ', '))
		}
		$identity = $false
	}

	# ---------------------------------------------------------------------------------------
	# Kopf
	# ---------------------------------------------------------------------------------------
	$modeText = if ($Mode -eq 'Scd2') { 'SCD Typ 2 (Historisierung)' } else { 'Upsert / SCD Typ 1' }
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.Append("/* ==========================================================================$nl")
	[void]$sb.Append("   MERGE - generiert mit sqmMergeGenerator v$script:smgModuleVersion$nl")
	[void]$sb.Append("   Quelle    : $srcName$nl")
	[void]$sb.Append("   Ziel      : $tgtName$nl")
	[void]$sb.Append("   Schluessel: $(($keys | ForEach-Object Tgt) -join ', ')$nl")
	[void]$sb.Append("   Modus     : $modeText$nl")
	[void]$sb.Append("   ========================================================================== */$nl")
	[void]$sb.Append("SET XACT_ABORT ON;$nl$nl")

	if ($DuplicateKeyCheck) {
		$grp = ($keys | ForEach-Object { "S.$(& $Q $_.Src)" }) -join ', '
		[void]$sb.Append("-- Abbruch, wenn die Quelle denselben Schluessel mehrfach liefert$nl")
		[void]$sb.Append("-- (MERGE wuerde sonst mit Fehler 8672 scheitern oder falsch historisieren)$nl")
		[void]$sb.Append("IF EXISTS (SELECT 1$nl           FROM ($nl$($using -replace "(?m)^", '        ')$nl           ) AS S$nl           GROUP BY $grp$nl           HAVING COUNT(*) > 1)$nl")
		[void]$sb.Append("    THROW 50001, N'Quelle enthaelt doppelte Schluesselwerte - MERGE abgebrochen.', 1;$nl$nl")
	}

	if ($Mode -eq 'Upsert') {
		# -----------------------------------------------------------------------------------
		# Upsert / SCD 1
		# -----------------------------------------------------------------------------------
		$upd = @($map | Where-Object { -not $_.IsKey -and $_.ChangeType -ne 'Fixed' -and -not $_.IsIdentity })
		$ins = $map

		if ($identity) { [void]$sb.Append("SET IDENTITY_INSERT $tgtName ON;$nl$nl") }
		[void]$sb.Append("MERGE INTO $tgtName$hold AS T$nl$usingBlock$nl    ON $on$nl")
		if ($upd.Count -gt 0) {
			$when = 'WHEN MATCHED'
			if ($UpdateOnlyChanged) { $when += " AND $(& $changeCheck $upd '')" }
			[void]$sb.Append("$when THEN$nl    UPDATE SET$nl")
			[void]$sb.Append((($upd | ForEach-Object { "        T.$(& $Q $_.Tgt) = S.$(& $Q $_.Src)" }) -join ",$nl") + $nl)
		}
		[void]$sb.Append("WHEN NOT MATCHED BY TARGET THEN$nl")
		[void]$sb.Append("    INSERT (" + (($ins | ForEach-Object { & $Q $_.Tgt }) -join ', ') + ")$nl")
		[void]$sb.Append("    VALUES (" + (($ins | ForEach-Object { "S.$(& $Q $_.Src)" }) -join ', ') + ")$nl")
		if ($DeleteNotMatchedBySource) {
			[void]$sb.Append("WHEN NOT MATCHED BY SOURCE THEN$nl    DELETE$nl")
		}
		if ($OutputAction) {
			$outCols = foreach ($k in $keys) {
				"COALESCE(inserted.$(& $Q $k.Tgt), deleted.$(& $Q $k.Tgt)) AS $(& $Q $k.Tgt)"
			}
			[void]$sb.Append("OUTPUT `$action AS MergeAction, " + ($outCols -join ', ') + $nl)
		}
		[void]$sb.Append(";$nl")
		if ($identity) { [void]$sb.Append("$nl" + "SET IDENTITY_INSERT $tgtName OFF;$nl") }
		return $sb.ToString()
	}

	# ---------------------------------------------------------------------------------------
	# SCD Typ 2
	# ---------------------------------------------------------------------------------------
	$type1 = @($map | Where-Object { -not $_.IsKey -and $_.ChangeType -eq 'Type1' })
	$type2 = @($map | Where-Object { -not $_.IsKey -and $_.ChangeType -eq 'Type2' })

	$currentCond = if ($CurrentFlagColumn) { "T.$(& $Q $CurrentFlagColumn) = 1" }
	               elseif ($OpenEndValue -eq 'NULL') { "T.$(& $Q $ValidToColumn) IS NULL" }
	               else { "T.$(& $Q $ValidToColumn) = $OpenEndValue" }
	$closeSet = @()
	if ($ValidToColumn)     { $closeSet += "T.$(& $Q $ValidToColumn) = @Now" }
	if ($CurrentFlagColumn) { $closeSet += "T.$(& $Q $CurrentFlagColumn) = 0" }
	$closeSet = $closeSet -join ",$nl            "

	$scdCols = @(); $scdVals = @()
	if ($ValidFromColumn)   { $scdCols += & $Q $ValidFromColumn;   $scdVals += '@Now' }
	if ($ValidToColumn)     { $scdCols += & $Q $ValidToColumn;     $scdVals += $OpenEndValue }
	if ($CurrentFlagColumn) { $scdCols += & $Q $CurrentFlagColumn; $scdVals += '1' }

	$insCols  = @($map | ForEach-Object { & $Q $_.Tgt }) + $scdCols
	$tmp      = '#smgMergeOutput'
	$keyOut   = "$tmp.$(& $Q $keys[0].Tgt)"

	[void]$sb.Append("DECLARE @Now datetime2(7) = SYSDATETIME();$nl")
	[void]$sb.Append("DECLARE @Type1Rows int = 0;$nl$nl")
	# Zwischentabelle mit den Zieltypen. Der LEFT JOIN ON 1 = 0 macht alle Spalten NULL-faehig
	# (OUTPUT liefert bei NOT MATCHED BY SOURCE NULL in den S-Spalten) und verhindert, dass
	# SELECT INTO eine IDENTITY-Eigenschaft uebernimmt.
	[void]$sb.Append("-- Zwischentabelle fuer die OUTPUT-Zeilen des MERGE (Typen wie im Ziel)$nl")
	[void]$sb.Append("IF OBJECT_ID('tempdb..$tmp') IS NOT NULL DROP TABLE $tmp;$nl")
	[void]$sb.Append("SELECT TOP (0) CAST(NULL AS nvarchar(10)) AS [__MergeAction],$nl       " +
		(($map | ForEach-Object { "T.$(& $Q $_.Tgt)" }) -join ",$nl       ") + $nl)
	[void]$sb.Append("INTO $tmp$nl" + "FROM (VALUES (1)) AS D(X)$nl" + "LEFT JOIN $tgtName AS T ON 1 = 0;$nl$nl")

	[void]$sb.Append("BEGIN TRANSACTION;$nl$nl")

	if ($type1.Count -gt 0) {
		[void]$sb.Append("-- Typ-1-Spalten: in allen Versionen des Schluessels ueberschreiben$nl")
		[void]$sb.Append("UPDATE T$nl   SET " + (($type1 | ForEach-Object { "T.$(& $Q $_.Tgt) = S.$(& $Q $_.Src)" }) -join ",$nl       ") + $nl)
		[void]$sb.Append("FROM $tgtName AS T$nl")
		[void]$sb.Append("INNER JOIN ($nl$using$nl) AS S$nl    ON $on$nl")
		[void]$sb.Append("WHERE $(& $changeCheck $type1 '');$nl")
		[void]$sb.Append("SET @Type1Rows = @@ROWCOUNT;$nl$nl")
	}

	[void]$sb.Append("-- Typ 2: neue Schluessel einfuegen, aktuelle Version bei Aenderung schliessen$nl")
	if ($type2.Count -eq 0) {
		[void]$sb.Append("-- (keine Typ-2-Spalte gewaehlt: es entstehen nur neue Schluessel, keine neuen Versionen)$nl")
	}
	[void]$sb.Append("MERGE INTO $tgtName$hold AS T$nl$usingBlock$nl")
	[void]$sb.Append("    ON $on$nl   AND $currentCond$nl")
	[void]$sb.Append("WHEN NOT MATCHED BY TARGET THEN$nl")
	[void]$sb.Append("    INSERT (" + ($insCols -join ', ') + ")$nl")
	[void]$sb.Append("    VALUES (" + ((@($map | ForEach-Object { "S.$(& $Q $_.Src)" }) + $scdVals) -join ', ') + ")$nl")
	if ($type2.Count -gt 0) {
		[void]$sb.Append("WHEN MATCHED AND $(& $changeCheck $type2 '') THEN$nl")
		[void]$sb.Append("    UPDATE SET $closeSet$nl")
	}
	if ($DeleteNotMatchedBySource) {
		[void]$sb.Append("WHEN NOT MATCHED BY SOURCE AND $currentCond THEN$nl")
		[void]$sb.Append("    UPDATE SET $closeSet$nl")
	}
	[void]$sb.Append("OUTPUT `$action, " + (($map | ForEach-Object { "S.$(& $Q $_.Src)" }) -join ', ') + $nl)
	[void]$sb.Append("  INTO $tmp ([__MergeAction], " + (($map | ForEach-Object { & $Q $_.Tgt }) -join ', ') + ");$nl$nl")

	# Bei NOT MATCHED BY SOURCE liefert OUTPUT ebenfalls 'UPDATE', aber mit NULL in allen S-Spalten
	[void]$sb.Append("-- Neue Version fuer jede geschlossene Zeile, deren Schluessel noch in der Quelle ist$nl")
	[void]$sb.Append("INSERT INTO $tgtName$nl       (" + ($insCols -join ', ') + ")$nl")
	[void]$sb.Append("SELECT " + ((@($map | ForEach-Object { "$tmp.$(& $Q $_.Tgt)" }) + $scdVals) -join ', ') + $nl)
	[void]$sb.Append("FROM $tmp$nl" + "WHERE $tmp.[__MergeAction] = 'UPDATE'$nl  AND $keyOut IS NOT NULL;$nl$nl")
	[void]$sb.Append("COMMIT TRANSACTION;$nl$nl")

	[void]$sb.Append("-- Zusammenfassung$nl")
	[void]$sb.Append("SELECT SUM(CASE WHEN [__MergeAction] = 'INSERT' THEN 1 ELSE 0 END) AS NeueSchluessel,$nl")
	[void]$sb.Append("       SUM(CASE WHEN [__MergeAction] = 'UPDATE' AND $keyOut IS NOT NULL THEN 1 ELSE 0 END) AS NeueVersionen,$nl")
	[void]$sb.Append("       SUM(CASE WHEN [__MergeAction] = 'UPDATE' AND $keyOut IS NULL THEN 1 ELSE 0 END) AS GeschlosseneSchluessel,$nl")
	[void]$sb.Append("       @Type1Rows AS Typ1Aktualisiert$nl")
	[void]$sb.Append("FROM $tmp;$nl$nl")
	[void]$sb.Append("DROP TABLE $tmp;$nl")
	if ($OutputAction) {
		[void]$sb.Append("-- Hinweis: Im SCD-2-Modus liefert die Zusammenfassung oben die Zaehler.$nl")
	}
	$sb.ToString()
}
