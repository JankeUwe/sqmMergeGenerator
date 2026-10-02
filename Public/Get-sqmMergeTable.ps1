function Get-sqmMergeTable {
	<#
	.SYNOPSIS
		Listet die Benutzertabellen (optional auch Views) einer Datenbank.
	.DESCRIPTION
		Views sind als MERGE-Quelle sinnvoll, als Ziel nicht - die GUI fragt sie deshalb
		nur fuer die Quellseite mit ab.
	.EXAMPLE
		Get-sqmMergeTable -SqlInstance DEV01 -SqlCredential $cred -Database Staging -IncludeViews
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory)][string]$Database,
		[switch]$IncludeViews
	)
	$cs = New-smgConnectionString -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database
	$q  = @"
SELECT s.name AS SchemaName, o.name AS TableName,
       CASE o.type WHEN 'V' THEN 'View' ELSE 'Table' END AS ObjectType
FROM sys.objects AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND (o.type = 'U' OR (@IncludeViews = 1 AND o.type = 'V'))
ORDER BY s.name, o.name;
"@
	Invoke-smgSqlQuery -ConnectionString $cs -Query $q -Parameters @{ IncludeViews = [int][bool]$IncludeViews } |
		ForEach-Object {
			$_ | Add-Member -NotePropertyName FullName -NotePropertyValue ('{0}.{1}' -f $_.SchemaName, $_.TableName) -PassThru
		}
}
