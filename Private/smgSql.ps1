<#
	SqlClient-Hilfsfunktionen. Bewusst ohne dbatools: der Generator braucht nur Metadaten
	und soll auch auf Servern ohne PSGallery-Zugang sofort laufen.
#>

function New-smgConnectionString {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$SqlInstance,
		[string]$Database = 'master',
		[System.Management.Automation.PSCredential]$SqlCredential,
		[bool]$TrustServerCertificate = $true
	)
	$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
	$b['Data Source']      = $SqlInstance
	$b['Initial Catalog']  = $Database
	$b['Application Name'] = 'sqmMergeGenerator'
	$b['Connect Timeout']  = 15
	if ($SqlCredential) {
		$b['User ID']  = $SqlCredential.UserName
		$b['Password'] = $SqlCredential.GetNetworkCredential().Password
	} else {
		$b['Integrated Security'] = $true
	}
	$b['TrustServerCertificate'] = $TrustServerCertificate
	$b.ConnectionString
}

function Set-smgConnectionDatabase {
	param([Parameter(Mandatory)][string]$ConnectionString, [Parameter(Mandatory)][string]$Database)
	$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionString
	$b['Initial Catalog'] = $Database
	$b.ConnectionString
}

function Invoke-smgSqlQuery {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$ConnectionString,
		[Parameter(Mandatory)][string]$Query,
		[hashtable]$Parameters,
		[switch]$NonQuery,
		[int]$CommandTimeout = 60
	)
	$conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
	try {
		$conn.Open()
		$cmd = $conn.CreateCommand()
		$cmd.CommandText    = $Query
		$cmd.CommandTimeout = $CommandTimeout
		if ($Parameters) {
			foreach ($k in $Parameters.Keys) {
				$v = $Parameters[$k]
				if ($null -eq $v) { $v = [DBNull]::Value }
				[void]$cmd.Parameters.AddWithValue("@$k", $v)
			}
		}
		if ($NonQuery) { return $cmd.ExecuteNonQuery() }

		$table   = New-Object System.Data.DataTable
		$adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
		[void]$adapter.Fill($table)
		foreach ($row in $table.Rows) {
			$o = [ordered]@{}
			foreach ($col in $table.Columns) {
				$val = $row[$col]
				$o[$col.ColumnName] = if ($val -is [DBNull]) { $null } else { $val }
			}
			[pscustomobject]$o
		}
	} finally {
		$conn.Dispose()
	}
}

function ConvertTo-smgQuotedName {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
	'[' + $Name.Replace(']', ']]') + ']'
}
