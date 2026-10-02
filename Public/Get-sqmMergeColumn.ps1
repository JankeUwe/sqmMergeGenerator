function Get-sqmMergeColumn {
	<#
	.SYNOPSIS
		Liefert die Spalten einer Tabelle/View mit allen Eigenschaften, die der Generator braucht.
	.DESCRIPTION
		IsWritable ist $false fuer berechnete Spalten, rowversion/timestamp und GENERATED ALWAYS
		(Temporal-Periodenspalten) - solche Spalten koennen kein Mapping-Ziel sein.
	.EXAMPLE
		Get-sqmMergeColumn -SqlInstance DEV01 -SqlCredential $cred -Database DWH -Schema dim -Table Customer
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory)][string]$Database,
		[string]$Schema = 'dbo',
		[Parameter(Mandatory)][string]$Table
	)
	$cs = New-smgConnectionString -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database
	$q  = @"
SELECT c.column_id                       AS ColumnId,
       c.name                            AS ColumnName,
       TYPE_NAME(c.user_type_id)         AS DataType,
       TYPE_NAME(c.system_type_id)       AS BaseType,
       c.max_length                      AS MaxLength,
       c.[precision]                     AS [Precision],
       c.scale                           AS Scale,
       c.is_nullable                     AS IsNullable,
       c.is_identity                     AS IsIdentity,
       c.is_computed                     AS IsComputed,
       ty.is_assembly_type               AS IsClrType,
       CAST(CASE WHEN c.system_type_id = 189 THEN 1 ELSE 0 END AS bit) AS IsRowVersion,
       CAST(ISNULL(COLUMNPROPERTY(c.object_id, c.name, 'GeneratedAlwaysType'), 0) AS int) AS GeneratedAlwaysType,
       CAST(CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END AS bit) AS IsPrimaryKey
FROM sys.columns AS c
JOIN sys.types   AS ty ON ty.user_type_id = c.user_type_id
LEFT JOIN (SELECT ic.object_id, ic.column_id
           FROM sys.indexes AS i
           JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
           WHERE i.is_primary_key = 1) AS pk
       ON pk.object_id = c.object_id AND pk.column_id = c.column_id
WHERE c.object_id = OBJECT_ID(@ObjectName)
ORDER BY c.column_id;
"@
	$obj  = '{0}.{1}' -f (ConvertTo-smgQuotedName $Schema), (ConvertTo-smgQuotedName $Table)
	$rows = @(Invoke-smgSqlQuery -ConnectionString $cs -Query $q -Parameters @{ ObjectName = $obj })
	if ($rows.Count -eq 0) {
		throw "Objekt $obj in Datenbank [$Database] nicht gefunden oder keine Spalten sichtbar."
	}
	foreach ($r in $rows) {
		$t = $r.DataType
		$len = switch -Regex ($r.BaseType) {
			'^(n?varchar|n?char)$' {
				if ($r.MaxLength -eq -1) { '(max)' }
				elseif ($r.BaseType -like 'n*') { '({0})' -f ($r.MaxLength / 2) }
				else { '({0})' -f $r.MaxLength }
			}
			'^(varbinary|binary)$' { if ($r.MaxLength -eq -1) { '(max)' } else { '({0})' -f $r.MaxLength } }
			'^(decimal|numeric)$'  { '({0},{1})' -f $r.Precision, $r.Scale }
			'^(datetime2|time|datetimeoffset)$' { '({0})' -f $r.Scale }
			default { '' }
		}
		if ($t -ne $r.BaseType -and -not $r.IsClrType) { $len = '' }   # Alias-Typ: Name reicht
		[pscustomobject]@{
			ColumnId     = [int]$r.ColumnId
			ColumnName   = $r.ColumnName
			DataType     = $t
			BaseType     = $r.BaseType
			TypeDisplay  = "$t$len"
			IsNullable   = [bool]$r.IsNullable
			IsIdentity   = [bool]$r.IsIdentity
			IsComputed   = [bool]$r.IsComputed
			IsClrType    = [bool]$r.IsClrType
			IsRowVersion = [bool]$r.IsRowVersion
			IsPrimaryKey = [bool]$r.IsPrimaryKey
			IsWritable   = -not ($r.IsComputed -or $r.IsRowVersion -or $r.GeneratedAlwaysType -ne 0)
		}
	}
}
