<#
	===========================================================================
	 Module Name: sqmMergeGenerator
	===========================================================================
#>

$script:smgModuleVersion = '0.1.0.0'
# Letzte Verbindungsangaben der GUI (ohne Passwort)
$script:smgConfigPath    = Join-Path $env:APPDATA 'sqmMergeGenerator\config.json'
# Zustand der (einen) offenen GUI-Instanz - Event-Handler laufen im Modul-Kontext und
# finden ihn hier auch dann, wenn Show-sqmMergeGeneratorGui -PassThru schon zurueckgekehrt ist.
$script:smgUi            = $null

$PublicPath  = Join-Path $PSScriptRoot 'Public'
$PrivatePath = Join-Path $PSScriptRoot 'Private'

Get-ChildItem -Path $PrivatePath -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}
Get-ChildItem -Path $PublicPath -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}

# Export wird ausschliesslich durch FunctionsToExport in sqmMergeGenerator.psd1 gesteuert.
