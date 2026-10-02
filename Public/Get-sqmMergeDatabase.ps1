function Get-sqmMergeDatabase {
	<#
	.SYNOPSIS
		Listet die online-Datenbanken einer Instanz, auf die der Login zugreifen darf.
	.EXAMPLE
		Get-sqmMergeDatabase -SqlInstance DEV01 -SqlCredential $cred
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[switch]$IncludeSystem
	)
	$cs = New-smgConnectionString -SqlInstance $SqlInstance -SqlCredential $SqlCredential
	$q  = @"
SELECT d.name AS DatabaseName
FROM sys.databases AS d
WHERE d.state = 0
  AND HAS_DBACCESS(d.name) = 1
  AND (@IncludeSystem = 1 OR d.database_id > 4)
ORDER BY d.name;
"@
	Invoke-smgSqlQuery -ConnectionString $cs -Query $q -Parameters @{ IncludeSystem = [int][bool]$IncludeSystem } |
		ForEach-Object { $_.DatabaseName }
}
