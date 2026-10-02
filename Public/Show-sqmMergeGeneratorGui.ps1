function Show-sqmMergeGeneratorGui {
	<#
	.SYNOPSIS
		Startet die WinForms-Oberflaeche des MERGE-Generators.
	.DESCRIPTION
		Server verbinden, Quell- und Ziel-Datenbank/-Tabelle per Combobox waehlen, Spalten
		SSIS-artig mappen, Schluesselspalten anhaken - das MERGE-Statement wird bei jeder
		Aenderung sofort neu erzeugt. Optional SCD Typ 2 mit Aenderungsart pro Spalte.
	.PARAMETER PassThru
		Formular nur aufbauen, nicht-modal anzeigen und zurueckgeben (fuer automatisierte Tests).
	.EXAMPLE
		Show-sqmMergeGeneratorGui
	.EXAMPLE
		Show-sqmMergeGeneratorGui -SqlInstance DEV01 -SqlCredential (Get-Credential DEV)
	#>
	[CmdletBinding()]
	param(
		[string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[switch]$PassThru
	)
	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing
	[System.Windows.Forms.Application]::EnableVisualStyles()

	$form = New-smgMainForm
	$ui   = $script:smgUi

	# Letzte Verbindung vorbelegen
	$cfg = Read-smgConfig
	foreach ($s in @($cfg.Servers)) { if ($s) { [void]$ui.Server.Items.Add($s) } }
	$ui.Server.Text = if ($SqlInstance) { $SqlInstance } elseif ($cfg.Servers) { @($cfg.Servers)[0] } else { '' }
	if ($SqlCredential) {
		$ui.Auth.SelectedIndex = 1
		$ui.Login.Text = $SqlCredential.UserName
		$ui.Password.Text = $SqlCredential.GetNetworkCredential().Password
	} elseif ($cfg.Auth -eq 'SQL') {
		$ui.Auth.SelectedIndex = 1
		$ui.Login.Text = $cfg.Login
	} else {
		$ui.Auth.SelectedIndex = 0
	}
	Update-smgStatement

	if ($PassThru) {
		$form.Show()
		[System.Windows.Forms.Application]::DoEvents()
		if ($SqlInstance) { Connect-smgServer }
		return $form
	}
	# Server per Parameter uebergeben: direkt verbinden
	if ($SqlInstance) { $form.Add_Shown({ Connect-smgServer }) }
	[void]$form.ShowDialog()
	$form.Dispose()
	$script:smgUi = $null
}
