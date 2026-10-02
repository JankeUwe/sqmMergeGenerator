<#
	WinForms-Aufbau und Logik der GUI. Alle Handler greifen ueber $script:smgUi auf die
	Controls zu (Modul-Scope), nicht ueber Variablen der aufrufenden Funktion - so laufen
	sie auch nach Show-sqmMergeGeneratorGui -PassThru noch korrekt.
#>

$script:smgIgnore      = '<nicht uebernehmen>'
$script:smgNone        = '<keine>'
$script:smgChangeTypes = [ordered]@{
	'Typ 2 - Historie'      = 'Type2'
	'Typ 1 - Ueberschreiben' = 'Type1'
	'Fest - nie aendern'    = 'Fixed'
}

# ===========================================================================================
# Konfiguration
# ===========================================================================================
function Read-smgConfig {
	$cfg = [pscustomobject]@{ Servers = @(); Auth = 'Windows'; Login = '' }
	try {
		if (Test-Path $script:smgConfigPath) {
			$j = Get-Content $script:smgConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
			$cfg.Servers = @($j.Servers | Where-Object { $_ })
			if ($j.Auth)  { $cfg.Auth = $j.Auth }
			if ($j.Login) { $cfg.Login = $j.Login }
		}
	} catch { }
	$cfg
}

function Save-smgConfig {
	param([string]$Server, [string]$Auth, [string]$Login)
	try {
		$cfg = Read-smgConfig
		$servers = @($Server) + @($cfg.Servers | Where-Object { $_ -and $_ -ne $Server }) | Select-Object -First 10
		$dir = Split-Path $script:smgConfigPath
		if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
		[pscustomobject]@{ Servers = @($servers); Auth = $Auth; Login = $Login } |
			ConvertTo-Json | Set-Content -Path $script:smgConfigPath -Encoding UTF8
	} catch { }
}

# ===========================================================================================
# Formularaufbau
# ===========================================================================================
function New-smgLabel([string]$Text) {
	$l = New-Object System.Windows.Forms.Label
	$l.Text = $Text
	$l.AutoSize = $true
	$l.Anchor = 'Left'
	$l.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
	$l
}

function New-smgFieldLabel([string]$Text) {
	# Fuer TableLayoutPanel-Zellen: vertikal zentriert statt fester Top-Margin
	$l = New-smgLabel $Text
	$l.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
	$l
}

function New-smgCombo([int]$Width, [switch]$Editable) {
	$c = New-Object System.Windows.Forms.ComboBox
	$c.DropDownStyle = if ($Editable) { 'DropDown' } else { 'DropDownList' }
	if ($Width) { $c.Width = $Width } else { $c.Anchor = 'Left, Right' }
	$c.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3)
	$c
}

function New-smgButton([string]$Text, [int]$Width = 110) {
	$b = New-Object System.Windows.Forms.Button
	$b.Text = $Text
	$b.Width = $Width
	$b.Height = 27
	$b
}

function New-smgMainForm {
	$ui = @{
		Loading = $false; Instance = $null; Cred = $null
		SrcTables = @(); TgtTables = @(); SrcCols = @(); TgtCols = @()
		KeyNames = @(); KeyAutoPick = $true; KeyOverride = $null
	}
	$script:smgUi = $ui

	$form = New-Object System.Windows.Forms.Form
	$form.Text = "sqmMergeGenerator $script:smgModuleVersion - T-SQL MERGE Generator"
	$form.Size = New-Object System.Drawing.Size(1420, 940)
	$form.MinimumSize = New-Object System.Drawing.Size(1100, 760)
	$form.StartPosition = 'CenterScreen'
	$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
	$ui.Form = $form

	$root = New-Object System.Windows.Forms.TableLayoutPanel
	$root.Dock = 'Fill'
	$root.ColumnCount = 1
	$root.RowCount = 3
	$root.Padding = New-Object System.Windows.Forms.Padding(6)
	[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 62)))
	[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 62)))
	[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))

	# ---------------------------------------------------------------------------------------
	# Verbindung
	# ---------------------------------------------------------------------------------------
	$gConn = New-Object System.Windows.Forms.GroupBox
	$gConn.Text = 'Verbindung'
	$gConn.Dock = 'Fill'
	$fConn = New-Object System.Windows.Forms.FlowLayoutPanel
	$fConn.Dock = 'Fill'
	$fConn.WrapContents = $false

	$ui.Server   = New-smgCombo 240 -Editable
	$ui.Auth     = New-smgCombo 150
	[void]$ui.Auth.Items.AddRange(@('Windows-Authentifizierung', 'SQL-Authentifizierung'))
	$ui.Login    = New-Object System.Windows.Forms.TextBox; $ui.Login.Width = 130
	$ui.Password = New-Object System.Windows.Forms.TextBox; $ui.Password.Width = 130; $ui.Password.UseSystemPasswordChar = $true
	foreach ($t in $ui.Login, $ui.Password) { $t.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3) }
	$ui.Trust    = New-Object System.Windows.Forms.CheckBox
	$ui.Trust.Text = 'TrustServerCertificate'; $ui.Trust.Checked = $true; $ui.Trust.AutoSize = $true
	$ui.Trust.Margin = New-Object System.Windows.Forms.Padding(8, 6, 3, 3)
	$ui.Connect  = New-smgButton 'Verbinden'
	$ui.Status   = New-smgLabel ''
	$ui.Status.ForeColor = [System.Drawing.Color]::DimGray

	$fConn.Controls.AddRange(@(
		(New-smgLabel 'Server:'), $ui.Server, (New-smgLabel 'Anmeldung:'), $ui.Auth,
		(New-smgLabel 'Login:'), $ui.Login, (New-smgLabel 'Passwort:'), $ui.Password,
		$ui.Trust, $ui.Connect, $ui.Status))
	$gConn.Controls.Add($fConn)
	$root.Controls.Add($gConn, 0, 0)

	# ---------------------------------------------------------------------------------------
	# Quelle / Ziel
	# ---------------------------------------------------------------------------------------
	$tSel = New-Object System.Windows.Forms.TableLayoutPanel
	$tSel.Dock = 'Fill'; $tSel.ColumnCount = 2; $tSel.RowCount = 1; $tSel.Margin = New-Object System.Windows.Forms.Padding(0)
	[void]$tSel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
	[void]$tSel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
	[void]$tSel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
	foreach ($side in 'Src', 'Tgt') {
		$g = New-Object System.Windows.Forms.GroupBox
		$g.Text = if ($side -eq 'Src') { 'Quelle' } else { 'Ziel' }
		$g.Dock = 'Fill'
		$t = New-Object System.Windows.Forms.TableLayoutPanel
		$t.Dock = 'Fill'; $t.ColumnCount = 4; $t.RowCount = 1
		[void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
		[void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
		[void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 38)))
		[void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
		[void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 62)))
		$ui["${side}Db"]    = New-smgCombo 0
		$ui["${side}Table"] = New-smgCombo 0
		$ui["${side}Table"].MaxDropDownItems = 25
		$t.Controls.Add((New-smgFieldLabel 'Datenbank:'), 0, 0)
		$t.Controls.Add($ui["${side}Db"], 1, 0)
		$t.Controls.Add((New-smgFieldLabel 'Tabelle:'), 2, 0)
		$t.Controls.Add($ui["${side}Table"], 3, 0)
		$g.Controls.Add($t)
		$tSel.Controls.Add($g, $(if ($side -eq 'Src') { 0 } else { 1 }), 0)
	}
	$root.Controls.Add($tSel, 0, 1)

	# ---------------------------------------------------------------------------------------
	# Split: oben Spalten + Optionen, unten Statement
	# ---------------------------------------------------------------------------------------
	$split = New-Object System.Windows.Forms.SplitContainer
	$split.Dock = 'Fill'
	$split.Orientation = 'Horizontal'
	$ui.Split = $split
	$root.Controls.Add($split, 0, 2)

	$tTop = New-Object System.Windows.Forms.TableLayoutPanel
	$tTop.Dock = 'Fill'; $tTop.ColumnCount = 1; $tTop.RowCount = 2; $tTop.Margin = New-Object System.Windows.Forms.Padding(0)
	[void]$tTop.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
	[void]$tTop.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 92)))
	$split.Panel1.Controls.Add($tTop)

	$tCols = New-Object System.Windows.Forms.TableLayoutPanel
	$tCols.Dock = 'Fill'; $tCols.ColumnCount = 3; $tCols.RowCount = 1; $tCols.Margin = New-Object System.Windows.Forms.Padding(0)
	[void]$tCols.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 24)))
	[void]$tCols.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 54)))
	[void]$tCols.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 22)))
	$tTop.Controls.Add($tCols, 0, 0)

	# 1. Quellspalten
	$g1 = New-Object System.Windows.Forms.GroupBox; $g1.Text = '1. Quellspalten'; $g1.Dock = 'Fill'
	$t1 = New-Object System.Windows.Forms.TableLayoutPanel; $t1.Dock = 'Fill'; $t1.RowCount = 2; $t1.ColumnCount = 1
	[void]$t1.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
	[void]$t1.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 34)))
	$ui.SrcList = New-Object System.Windows.Forms.CheckedListBox
	$ui.SrcList.Dock = 'Fill'; $ui.SrcList.CheckOnClick = $true; $ui.SrcList.IntegralHeight = $false
	$f1 = New-Object System.Windows.Forms.FlowLayoutPanel; $f1.Dock = 'Fill'
	$ui.SrcAll  = New-smgButton 'Alle' 70
	$ui.SrcNone = New-smgButton 'Keine' 70
	$f1.Controls.AddRange(@($ui.SrcAll, $ui.SrcNone))
	$t1.Controls.Add($ui.SrcList, 0, 0); $t1.Controls.Add($f1, 0, 1)
	$g1.Controls.Add($t1)
	$tCols.Controls.Add($g1, 0, 0)

	# 2. Mapping
	$g2 = New-Object System.Windows.Forms.GroupBox; $g2.Text = '2. Mapping Quelle -> Ziel'; $g2.Dock = 'Fill'
	$grid = New-Object System.Windows.Forms.DataGridView
	$grid.Dock = 'Fill'
	$grid.AllowUserToAddRows = $false
	$grid.AllowUserToDeleteRows = $false
	$grid.AllowUserToResizeRows = $false
	$grid.RowHeadersVisible = $false
	$grid.SelectionMode = 'CellSelect'
	$grid.EditMode = 'EditOnEnter'
	$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
	$grid.AutoSizeColumnsMode = 'Fill'
	$grid.ShowCellToolTips = $true
	$c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$c.Name = 'Src'; $c.HeaderText = 'Quellspalte'; $c.ReadOnly = $true; $c.FillWeight = 26; [void]$grid.Columns.Add($c)
	$c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$c.Name = 'SrcType'; $c.HeaderText = 'Typ'; $c.ReadOnly = $true; $c.FillWeight = 16
	$c.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray; [void]$grid.Columns.Add($c)
	$c = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
	$c.Name = 'Tgt'; $c.HeaderText = 'Zielspalte'; $c.FillWeight = 28; $c.FlatStyle = 'Flat'; [void]$grid.Columns.Add($c)
	$c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$c.Name = 'TgtType'; $c.HeaderText = 'Typ'; $c.ReadOnly = $true; $c.FillWeight = 16
	$c.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray; [void]$grid.Columns.Add($c)
	$c = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
	$c.Name = 'Change'; $c.HeaderText = 'Aenderungsart (SCD)'; $c.FillWeight = 22; $c.FlatStyle = 'Flat'
	$c.ToolTipText = 'Typ 2: neue Version (nur SCD-2-Modus) | Typ 1: ueberschreiben | Fest: nie aktualisieren'
	[void]$c.Items.AddRange([string[]]@($script:smgChangeTypes.Keys))
	[void]$grid.Columns.Add($c)
	$ui.Grid = $grid
	$g2.Controls.Add($grid)
	$tCols.Controls.Add($g2, 1, 0)

	# 3. Schluessel
	$g3 = New-Object System.Windows.Forms.GroupBox; $g3.Text = '3. Schluesselspalten (Join)'; $g3.Dock = 'Fill'
	$ui.KeyList = New-Object System.Windows.Forms.CheckedListBox
	$ui.KeyList.Dock = 'Fill'; $ui.KeyList.CheckOnClick = $true; $ui.KeyList.IntegralHeight = $false
	$g3.Controls.Add($ui.KeyList)
	$tCols.Controls.Add($g3, 2, 0)

	# Optionen
	$gOpt = New-Object System.Windows.Forms.GroupBox; $gOpt.Text = 'Optionen'; $gOpt.Dock = 'Fill'
	$tOpt = New-Object System.Windows.Forms.TableLayoutPanel; $tOpt.Dock = 'Fill'; $tOpt.RowCount = 2; $tOpt.ColumnCount = 1
	[void]$tOpt.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 32)))
	[void]$tOpt.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 34)))
	$fo1 = New-Object System.Windows.Forms.FlowLayoutPanel; $fo1.Dock = 'Fill'; $fo1.WrapContents = $false
	$fo2 = New-Object System.Windows.Forms.FlowLayoutPanel; $fo2.Dock = 'Fill'; $fo2.WrapContents = $false
	$mk = {
		param($type, $text, $checked)
		$o = New-Object "System.Windows.Forms.$type"
		$o.Text = $text; $o.AutoSize = $true; $o.Checked = $checked
		$o.Margin = New-Object System.Windows.Forms.Padding(3, 5, 12, 3)
		$o
	}
	$ui.ModeUpsert  = & $mk RadioButton 'Upsert / SCD Typ 1' $true
	$ui.ModeScd2    = & $mk RadioButton 'SCD Typ 2 (Historie)' $false
	$ui.OnlyChanged = & $mk CheckBox 'Nur bei Aenderung aktualisieren' $true
	$ui.NotInSource = & $mk CheckBox 'Nicht in Quelle: loeschen' $false
	$ui.HoldLock    = & $mk CheckBox 'WITH (HOLDLOCK)' $true
	$ui.OutputAct   = & $mk CheckBox 'OUTPUT $action' $false
	$ui.DupCheck    = & $mk CheckBox 'Duplikatpruefung Quelle' $true
	$ui.ModeUpsert.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
	$ui.ModeScd2.Font   = $ui.ModeUpsert.Font
	$fo1.Controls.AddRange(@($ui.ModeUpsert, $ui.ModeScd2, $ui.OnlyChanged, $ui.NotInSource, $ui.HoldLock, $ui.OutputAct, $ui.DupCheck))

	$ui.ValidFrom   = New-smgCombo 140
	$ui.ValidTo     = New-smgCombo 140
	$ui.CurrentFlag = New-smgCombo 140
	$ui.OpenEnd     = New-smgCombo 150 -Editable
	[void]$ui.OpenEnd.Items.AddRange(@('NULL', "'9999-12-31'", "'9999-12-31 23:59:59'"))
	$ui.OpenEnd.Text = 'NULL'
	$ui.Filter = New-Object System.Windows.Forms.TextBox; $ui.Filter.Width = 320
	$ui.Filter.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3)
	$ui.ScdLabels = @((New-smgLabel 'Gueltig ab:'), (New-smgLabel 'Gueltig bis:'), (New-smgLabel 'Aktuell-Flag:'), (New-smgLabel 'Offenes Ende:'))
	$fo2.Controls.AddRange(@(
		$ui.ScdLabels[0], $ui.ValidFrom, $ui.ScdLabels[1], $ui.ValidTo, $ui.ScdLabels[2], $ui.CurrentFlag,
		$ui.ScdLabels[3], $ui.OpenEnd, (New-smgLabel '    Quellfilter WHERE:'), $ui.Filter))
	$tOpt.Controls.Add($fo1, 0, 0); $tOpt.Controls.Add($fo2, 0, 1)
	$gOpt.Controls.Add($tOpt)
	$tTop.Controls.Add($gOpt, 0, 1)

	# Statement
	$tBot = New-Object System.Windows.Forms.TableLayoutPanel
	$tBot.Dock = 'Fill'; $tBot.ColumnCount = 1; $tBot.RowCount = 2
	[void]$tBot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
	[void]$tBot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 38)))
	$ui.Output = New-Object System.Windows.Forms.TextBox
	$ui.Output.Multiline = $true; $ui.Output.ScrollBars = 'Both'; $ui.Output.WordWrap = $false
	$ui.Output.Dock = 'Fill'; $ui.Output.ReadOnly = $true
	$ui.Output.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
	$ui.Output.Font = New-Object System.Drawing.Font('Consolas', 10)
	$fb = New-Object System.Windows.Forms.FlowLayoutPanel; $fb.Dock = 'Fill'
	$ui.BtnCopy    = New-smgButton 'In Zwischenablage' 130
	$ui.BtnSave    = New-smgButton 'Speichern ...' 110
	$ui.BtnCheck   = New-smgButton 'Syntax pruefen' 120
	$ui.BtnExecute = New-smgButton 'Ausfuehren ...' 110
	$fb.Controls.AddRange(@($ui.BtnCopy, $ui.BtnSave, $ui.BtnCheck, $ui.BtnExecute))
	$tBot.Controls.Add($ui.Output, 0, 0); $tBot.Controls.Add($fb, 0, 1)
	$split.Panel2.Controls.Add($tBot)

	$form.Controls.Add($root)

	Register-smgEvents
	Set-smgModeState
	$form.Add_Shown({ try { $script:smgUi.Split.SplitterDistance = [int]($script:smgUi.Split.Height * 0.52) } catch { } })
	$form
}

# ===========================================================================================
# Events
# ===========================================================================================
function Register-smgEvents {
	$ui = $script:smgUi

	$ui.Auth.Add_SelectedIndexChanged({
		$sql = $script:smgUi.Auth.SelectedIndex -eq 1
		$script:smgUi.Login.Enabled = $sql
		$script:smgUi.Password.Enabled = $sql
	})
	$ui.Connect.Add_Click({ Connect-smgServer })
	$ui.Password.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; Connect-smgServer } })
	$ui.Server.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; Connect-smgServer } })

	$ui.SrcDb.Add_SelectedIndexChanged({ Update-smgTableList -Side Src })
	$ui.TgtDb.Add_SelectedIndexChanged({ Update-smgTableList -Side Tgt })
	$ui.SrcTable.Add_SelectedIndexChanged({ Update-smgColumns -Side Src })
	$ui.TgtTable.Add_SelectedIndexChanged({ Update-smgColumns -Side Tgt })

	$ui.SrcList.Add_ItemCheck({
		if ($script:smgUi.Loading) { return }
		Update-smgMapping -OverrideIndex $_.Index -OverrideChecked ($_.NewValue -eq 'Checked')
	})
	$ui.SrcAll.Add_Click({ Set-smgAllSourceChecked $true })
	$ui.SrcNone.Add_Click({ Set-smgAllSourceChecked $false })

	$ui.Grid.Add_CurrentCellDirtyStateChanged({
		if ($script:smgUi.Grid.IsCurrentCellDirty) { [void]$script:smgUi.Grid.CommitEdit('CurrentCellChange') }
	})
	$ui.Grid.Add_CellValueChanged({
		if ($script:smgUi.Loading -or $_.RowIndex -lt 0) { return }
		if ($script:smgUi.Grid.Columns[$_.ColumnIndex].Name -eq 'Tgt') {
			$row = $script:smgUi.Grid.Rows[$_.RowIndex]
			$tc  = $script:smgUi.TgtCols | Where-Object { $_.ColumnName -eq $row.Cells['Tgt'].Value } | Select-Object -First 1
			$row.Cells['TgtType'].Value = if ($tc) { $tc.TypeDisplay } else { '' }
			Update-smgRowStyle $row
			Update-smgKeyList
		}
		Update-smgStatement
	})
	$ui.Grid.Add_DataError({ $_.ThrowException = $false })

	$ui.KeyList.Add_ItemCheck({
		if ($script:smgUi.Loading) { return }
		$script:smgUi.KeyOverride = @{ Index = $_.Index; Checked = ($_.NewValue -eq 'Checked') }
		Update-smgStatement
		$script:smgUi.KeyOverride = $null
	})

	$ui.ModeUpsert.Add_CheckedChanged({ Set-smgModeState; Update-smgStatement })
	foreach ($cb in $ui.OnlyChanged, $ui.NotInSource, $ui.HoldLock, $ui.OutputAct, $ui.DupCheck) {
		$cb.Add_CheckedChanged({ Update-smgStatement })
	}
	foreach ($cb in $ui.ValidFrom, $ui.ValidTo, $ui.CurrentFlag, $ui.OpenEnd) {
		$cb.Add_SelectedIndexChanged({ Update-smgStatement })
	}
	$ui.OpenEnd.Add_TextChanged({ Update-smgStatement })
	$ui.Filter.Add_TextChanged({ Update-smgStatement })

	$ui.BtnCopy.Add_Click({
		if ($script:smgUi.Output.Text) {
			[System.Windows.Forms.Clipboard]::SetText($script:smgUi.Output.Text)
			Set-smgStatus 'Statement in die Zwischenablage kopiert.'
		}
	})
	$ui.BtnSave.Add_Click({ Save-smgStatement })
	$ui.BtnCheck.Add_Click({ Invoke-smgStatement -CheckOnly })
	$ui.BtnExecute.Add_Click({ Invoke-smgStatement })
}

# ===========================================================================================
# Logik
# ===========================================================================================
function Set-smgStatus([string]$Text, [switch]$IsError) {
	$ui = $script:smgUi
	$ui.Status.Text = $Text
	$ui.Status.ForeColor = if ($IsError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DarkGreen }
}

function Get-smgCurrentScd2 { [bool]$script:smgUi.ModeScd2.Checked }

function Set-smgModeState {
	$ui = $script:smgUi
	$scd = Get-smgCurrentScd2
	foreach ($c in @($ui.ValidFrom, $ui.ValidTo, $ui.CurrentFlag, $ui.OpenEnd) + $ui.ScdLabels) { $c.Enabled = $scd }
	$ui.OnlyChanged.Enabled = -not $scd
	$ui.NotInSource.Text = if ($scd) { 'Nicht in Quelle: Version schliessen' } else { 'Nicht in Quelle: loeschen' }
	$ui.OutputAct.Enabled = -not $scd
}

function Connect-smgServer {
	$ui = $script:smgUi
	$server = $ui.Server.Text.Trim()
	if (-not $server) { Set-smgStatus 'Bitte einen Server angeben.' -IsError; return }
	$cred = $null
	if ($ui.Auth.SelectedIndex -eq 1) {
		if (-not $ui.Login.Text) { Set-smgStatus 'Bitte Login angeben.' -IsError; return }
		$pw = New-Object System.Security.SecureString
		foreach ($ch in $ui.Password.Text.ToCharArray()) { $pw.AppendChar($ch) }
		$cred = New-Object System.Management.Automation.PSCredential($ui.Login.Text, $pw)
	}
	$ui.Form.Cursor = 'WaitCursor'
	try {
		$cs = New-smgConnectionString -SqlInstance $server -SqlCredential $cred -TrustServerCertificate $ui.Trust.Checked
		$ver = Invoke-smgSqlQuery -ConnectionString $cs -Query "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(30)) AS V, CAST(SERVERPROPERTY('Edition') AS nvarchar(100)) AS E"
		$dbs = @(Invoke-smgSqlQuery -ConnectionString $cs -Query "SELECT name FROM sys.databases WHERE state = 0 AND HAS_DBACCESS(name) = 1 ORDER BY CASE WHEN database_id <= 4 THEN 1 ELSE 0 END, name" | ForEach-Object name)
		$ui.Instance = $server; $ui.Cred = $cred; $ui.ConnBase = $cs
		$ui.Loading = $true
		foreach ($cb in $ui.SrcDb, $ui.TgtDb, $ui.SrcTable, $ui.TgtTable) { $cb.Items.Clear() }
		$ui.SrcList.Items.Clear(); $ui.KeyList.Items.Clear(); $ui.Grid.Rows.Clear()
		$ui.SrcCols = @(); $ui.TgtCols = @()
		foreach ($d in $dbs) { [void]$ui.SrcDb.Items.Add($d); [void]$ui.TgtDb.Items.Add($d) }
		$ui.Loading = $false
		Set-smgStatus ("Verbunden: {0} ({1}, {2}) - {3} Datenbanken" -f $server, $ver.V, $ver.E, $dbs.Count)
		$authName = if ($cred) { 'SQL' } else { 'Windows' }
		Save-smgConfig -Server $server -Auth $authName -Login $ui.Login.Text
		if (-not $ui.Server.Items.Contains($server)) { $ui.Server.Items.Insert(0, $server) }
		Update-smgStatement
	} catch {
		$ui.Loading = $false
		Set-smgStatus ("Verbindung fehlgeschlagen: {0}" -f (Get-smgErrorText $_)) -IsError
	} finally {
		$ui.Form.Cursor = 'Default'
	}
}

function Get-smgErrorText($err) {
	$e = $err.Exception
	while ($e.InnerException) { $e = $e.InnerException }
	$e.Message
}

function Update-smgTableList {
	param([ValidateSet('Src', 'Tgt')][string]$Side)
	$ui = $script:smgUi
	if ($ui.Loading -or -not $ui.ConnBase) { return }
	$db = $ui["${Side}Db"].SelectedItem
	if (-not $db) { return }
	try {
		$cs = Set-smgConnectionDatabase -ConnectionString $ui.ConnBase -Database $db
		$views = if ($Side -eq 'Src') { 1 } else { 0 }
		$tables = @(Invoke-smgSqlQuery -ConnectionString $cs -Parameters @{ V = $views } -Query @"
SELECT s.name AS SchemaName, o.name AS TableName, o.type AS T
FROM sys.objects AS o JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0 AND (o.type = 'U' OR (@V = 1 AND o.type = 'V'))
ORDER BY s.name, o.name;
"@)
		$ui.Loading = $true
		$combo = $ui["${Side}Table"]
		$combo.Items.Clear()
		foreach ($t in $tables) {
			$suffix = if ($t.T.Trim() -eq 'V') { '  (View)' } else { '' }
			[void]$combo.Items.Add(('{0}.{1}{2}' -f $t.SchemaName, $t.TableName, $suffix))
		}
		$ui["${Side}Tables"] = $tables
		$ui.Loading = $false
		if ($Side -eq 'Src') { $ui.SrcCols = @(); $ui.SrcList.Items.Clear() } else { $ui.TgtCols = @() }
		Update-smgMapping -Reset
		Set-smgStatus ("[{0}]: {1} Objekte" -f $db, $tables.Count)
	} catch {
		$ui.Loading = $false
		Set-smgStatus ("Tabellen konnten nicht gelesen werden: {0}" -f (Get-smgErrorText $_)) -IsError
	}
}

function Get-smgSelectedTable([string]$Side) {
	$ui = $script:smgUi
	$i = $ui["${Side}Table"].SelectedIndex
	if ($i -lt 0 -or -not $ui["${Side}Db"].SelectedItem) { return $null }
	$t = @($ui["${Side}Tables"])[$i]
	[pscustomobject]@{ Database = [string]$ui["${Side}Db"].SelectedItem; Schema = $t.SchemaName; Table = $t.TableName }
}

function Update-smgColumns {
	param([ValidateSet('Src', 'Tgt')][string]$Side)
	$ui = $script:smgUi
	if ($ui.Loading) { return }
	$sel = Get-smgSelectedTable $Side
	if (-not $sel) { return }
	try {
		$cols = @(Get-sqmMergeColumn -SqlInstance $ui.Instance -SqlCredential $ui.Cred -Database $sel.Database -Schema $sel.Schema -Table $sel.Table)
	} catch {
		Set-smgStatus ("Spalten konnten nicht gelesen werden: {0}" -f (Get-smgErrorText $_)) -IsError
		return
	}
	$ui.Loading = $true
	try {
		if ($Side -eq 'Src') {
			$ui.SrcCols = $cols
			$ui.SrcList.Items.Clear()
			foreach ($c in $cols) {
				$flag = if ($c.IsPrimaryKey) { '  [PK]' } else { '' }
				# rowversion/berechnete Spalten der Quelle sind lesbar, aber selten sinnvoll
				[void]$ui.SrcList.Items.Add(('{0}   {1}{2}' -f $c.ColumnName, $c.TypeDisplay, $flag), (-not $c.IsRowVersion))
			}
		} else {
			$ui.TgtCols = $cols
			Update-smgScdCombos
		}
		$ui.KeyAutoPick = $true
	} finally { $ui.Loading = $false }
	Update-smgMapping -Reset
	Set-smgStatus ("{0}.{1}.{2}: {3} Spalten" -f $sel.Database, $sel.Schema, $sel.Table, $cols.Count)
}

function Update-smgScdCombos {
	$ui = $script:smgUi
	$names = @($ui.TgtCols | Where-Object IsWritable | ForEach-Object ColumnName)
	$pick = @{
		ValidFrom   = '^(Valid_?From|G(ue|ü)ltig_?(Ab|Von)|Start_?Date|Effective_?(From|Date)|Date_?From|Von_?Datum|Row_?Start.*)$'
		ValidTo     = '^(Valid_?To|G(ue|ü)ltig_?Bis|End_?Date|Expir(y|ation)_?Date|Effective_?To|Date_?To|Bis_?Datum|Row_?End.*)$'
		CurrentFlag = '^(Is_?Current|Current_?Flag|Is_?Active|Ist_?Aktuell|Aktuell|Current)$'
	}
	foreach ($k in $pick.Keys) {
		$cb = $ui[$k]
		$cb.Items.Clear()
		[void]$cb.Items.Add($script:smgNone)
		foreach ($n in $names) { [void]$cb.Items.Add($n) }
		$hit = $names | Where-Object { $_ -match $pick[$k] } | Select-Object -First 1
		$cb.SelectedItem = if ($hit) { $hit } else { $script:smgNone }
	}
	# Eine Historisierungs-Struktur in der Zieltabelle schaltet direkt in den SCD-2-Modus
	if (($ui.ValidTo.SelectedItem -ne $script:smgNone) -or ($ui.CurrentFlag.SelectedItem -ne $script:smgNone)) {
		$ui.ModeScd2.Checked = $true
	} else {
		$ui.ModeUpsert.Checked = $true
	}
	Set-smgModeState
}

function Get-smgScdColumnNames {
	$ui = $script:smgUi
	@($ui.ValidFrom, $ui.ValidTo, $ui.CurrentFlag) | ForEach-Object { $_.SelectedItem } |
		Where-Object { $_ -and $_ -ne $script:smgNone }
}

function Set-smgAllSourceChecked([bool]$Checked) {
	$ui = $script:smgUi
	$ui.Loading = $true
	for ($i = 0; $i -lt $ui.SrcList.Items.Count; $i++) { $ui.SrcList.SetItemChecked($i, $Checked) }
	$ui.Loading = $false
	Update-smgMapping
}

function Update-smgRowStyle($row) {
	$ignored = $row.Cells['Tgt'].Value -eq $script:smgIgnore
	$row.DefaultCellStyle.ForeColor = if ($ignored) { [System.Drawing.Color]::Gray } else { [System.Drawing.SystemColors]::ControlText }
}

function Update-smgMapping {
	param([int]$OverrideIndex = -1, [bool]$OverrideChecked, [switch]$Reset)
	$ui = $script:smgUi
	$grid = $ui.Grid
	$prev = @{}
	if (-not $Reset) {
		foreach ($r in $grid.Rows) {
			$prev[[string]$r.Cells['Src'].Value] = @{ Tgt = $r.Cells['Tgt'].Value; Change = $r.Cells['Change'].Value }
		}
	}
	$ui.Loading = $true
	try {
		$grid.Rows.Clear()
		$tgtColumn = $grid.Columns['Tgt']
		$tgtColumn.Items.Clear()
		[void]$tgtColumn.Items.Add($script:smgIgnore)
		$writable = @($ui.TgtCols | Where-Object IsWritable)
		foreach ($c in $writable) { [void]$tgtColumn.Items.Add($c.ColumnName) }
		$scdNames = @(Get-smgScdColumnNames)
		$scd = Get-smgCurrentScd2
		$defaultChange = if ($scd) { 'Typ 2 - Historie' } else { 'Typ 1 - Ueberschreiben' }

		for ($i = 0; $i -lt $ui.SrcCols.Count; $i++) {
			$checked = if ($i -eq $OverrideIndex) { $OverrideChecked } else { $ui.SrcList.GetItemChecked($i) }
			if (-not $checked) { continue }
			$sc = $ui.SrcCols[$i]
			if ($prev.ContainsKey($sc.ColumnName)) {
				$tgt = $prev[$sc.ColumnName].Tgt
				$chg = $prev[$sc.ColumnName].Change
			} else {
				$m = $writable | Where-Object { $_.ColumnName -eq $sc.ColumnName } | Select-Object -First 1
				$tgt = $script:smgIgnore
				if ($m -and $m.ColumnName -notin $scdNames -and -not ($scd -and $m.IsIdentity)) { $tgt = $m.ColumnName }
				$chg = $defaultChange
			}
			if (-not $tgt -or -not $tgtColumn.Items.Contains($tgt)) { $tgt = $script:smgIgnore }
			if (-not $chg) { $chg = $defaultChange }
			$tc = $writable | Where-Object { $_.ColumnName -eq $tgt } | Select-Object -First 1
			$idx = $grid.Rows.Add()
			$row = $grid.Rows[$idx]
			$row.Cells['Src'].Value     = $sc.ColumnName
			$row.Cells['SrcType'].Value = $sc.TypeDisplay
			$row.Cells['Tgt'].Value     = $tgt
			$row.Cells['TgtType'].Value = if ($tc) { $tc.TypeDisplay } else { '' }
			$row.Cells['Change'].Value  = $chg
			Update-smgRowStyle $row
		}
	} finally { $ui.Loading = $false }
	Update-smgKeyList
	Update-smgStatement
}

function Get-smgMappingFromGrid {
	$ui = $script:smgUi
	foreach ($r in $ui.Grid.Rows) {
		$tgt = [string]$r.Cells['Tgt'].Value
		if (-not $tgt -or $tgt -eq $script:smgIgnore) { continue }
		$tc = $ui.TgtCols | Where-Object { $_.ColumnName -eq $tgt } | Select-Object -First 1
		$label = [string]$r.Cells['Change'].Value
		[pscustomobject]@{
			SourceColumn     = [string]$r.Cells['Src'].Value
			TargetColumn     = $tgt
			ChangeType       = if ($script:smgChangeTypes.Contains($label)) { $script:smgChangeTypes[$label] } else { $null }
			TargetDataType   = if ($tc) { $tc.BaseType } else { $null }
			TargetIsClrType  = if ($tc) { $tc.IsClrType } else { $false }
			TargetIsIdentity = if ($tc) { $tc.IsIdentity } else { $false }
		}
	}
}

function Update-smgKeyList {
	$ui = $script:smgUi
	$prevChecked = @{}
	for ($i = 0; $i -lt $ui.KeyList.Items.Count; $i++) {
		if ($ui.KeyList.GetItemChecked($i)) { $prevChecked[$ui.KeyNames[$i]] = $true }
	}
	$map = @(Get-smgMappingFromGrid)
	$autoPick = $ui.KeyAutoPick -and $map.Count -gt 0
	# Vorbelegung: PK des Ziels. Ist der nicht gemappt (typisch SCD 2: PK = Surrogatschluessel),
	# dann der PK der Quelle als fachlicher Schluessel.
	$pkSide = 'Tgt'
	if ($autoPick) {
		$tgtPkMapped = $map | Where-Object { $tn = $_.TargetColumn; $ui.TgtCols | Where-Object { $_.ColumnName -eq $tn -and $_.IsPrimaryKey } }
		if (-not $tgtPkMapped) { $pkSide = 'Src' }
	}
	$wasLoading = $ui.Loading
	$ui.Loading = $true
	try {
		$ui.KeyList.Items.Clear()
		$names = @()
		foreach ($m in $map) {
			$tc = $ui.TgtCols | Where-Object { $_.ColumnName -eq $m.TargetColumn } | Select-Object -First 1
			$sc = $ui.SrcCols | Where-Object { $_.ColumnName -eq $m.SourceColumn } | Select-Object -First 1
			$check = if (-not $autoPick) { $prevChecked.ContainsKey($m.TargetColumn) }
			         elseif ($pkSide -eq 'Tgt') { [bool]($tc -and $tc.IsPrimaryKey) }
			         else { [bool]($sc -and $sc.IsPrimaryKey) }
			$text = if ($m.SourceColumn -eq $m.TargetColumn) { $m.TargetColumn } else { '{0}  <-  {1}' -f $m.TargetColumn, $m.SourceColumn }
			if ($tc -and $tc.IsPrimaryKey) { $text += '  [PK]' }
			[void]$ui.KeyList.Items.Add($text, $check)
			$names += $m.TargetColumn
		}
		$ui.KeyNames = $names
		if ($autoPick) { $ui.KeyAutoPick = $false }
	} finally { $ui.Loading = $wasLoading }
}

function Get-smgKeyColumns {
	$ui = $script:smgUi
	for ($i = 0; $i -lt $ui.KeyList.Items.Count; $i++) {
		$checked = $ui.KeyList.GetItemChecked($i)
		if ($ui.KeyOverride -and $ui.KeyOverride.Index -eq $i) { $checked = $ui.KeyOverride.Checked }
		if ($checked) { $ui.KeyNames[$i] }
	}
}

function Get-smgStatementParameters {
	$ui = $script:smgUi
	$src = Get-smgSelectedTable 'Src'
	$tgt = Get-smgSelectedTable 'Tgt'
	if (-not $ui.ConnBase) { return '-- Schritt 1: Server verbinden.' }
	if (-not $src) { return '-- Schritt 2: Quelldatenbank und -tabelle waehlen.' }
	if (-not $tgt) { return '-- Schritt 3: Zieldatenbank und -tabelle waehlen.' }
	$map = @(Get-smgMappingFromGrid)
	if ($map.Count -eq 0) { return '-- Schritt 4: Mindestens eine Quellspalte einer Zielspalte zuordnen.' }
	$keys = @(Get-smgKeyColumns)
	if ($keys.Count -eq 0) { return '-- Schritt 5: Schluesselspalte(n) fuer den Join anhaken.' }

	$p = @{
		SourceDatabase = $src.Database; SourceSchema = $src.Schema; SourceTable = $src.Table
		TargetDatabase = $tgt.Database; TargetSchema = $tgt.Schema; TargetTable = $tgt.Table
		ColumnMapping  = $map; KeyColumns = $keys
		UpdateOnlyChanged        = [bool]$ui.OnlyChanged.Checked
		DeleteNotMatchedBySource = [bool]$ui.NotInSource.Checked
		HoldLock          = [bool]$ui.HoldLock.Checked
		OutputAction      = [bool]$ui.OutputAct.Checked
		DuplicateKeyCheck = [bool]$ui.DupCheck.Checked
		SourceFilter      = $ui.Filter.Text
	}
	if (Get-smgCurrentScd2) {
		$p.Mode = 'Scd2'
		$p.OutputAction = $false
		foreach ($k in 'ValidFrom', 'ValidTo', 'CurrentFlag') {
			$v = $ui[$k].SelectedItem
			if ($v -and $v -ne $script:smgNone) { $p["${k}Column"] = [string]$v }
		}
		$p.OpenEndValue = $ui.OpenEnd.Text.Trim()
	}
	$p
}

function Update-smgStatement {
	$ui = $script:smgUi
	if (-not $ui -or $ui.Loading) { return }
	$p = Get-smgStatementParameters
	if ($p -is [string]) { $ui.Output.Text = $p; $ui.Statement = $null; return }
	try {
		$sql = New-sqmMergeStatement @p
		$ui.Output.Text = $sql
		$ui.Statement = $sql
	} catch {
		$ui.Output.Text = "-- Kein Statement: $(Get-smgErrorText $_)"
		$ui.Statement = $null
	}
}

function Save-smgStatement {
	$ui = $script:smgUi
	if (-not $ui.Statement) { Set-smgStatus 'Kein gueltiges Statement zum Speichern.' -IsError; return }
	$dlg = New-Object System.Windows.Forms.SaveFileDialog
	$dlg.Filter = 'SQL-Skript (*.sql)|*.sql|Alle Dateien (*.*)|*.*'
	$tgt = Get-smgSelectedTable 'Tgt'
	$dlg.FileName = 'MERGE_{0}_{1}.sql' -f $tgt.Schema, $tgt.Table
	if ($dlg.ShowDialog($ui.Form) -eq 'OK') {
		[System.IO.File]::WriteAllText($dlg.FileName, $ui.Statement, (New-Object System.Text.UTF8Encoding($true)))
		Set-smgStatus "Gespeichert: $($dlg.FileName)"
	}
}

function Invoke-smgStatement {
	param([switch]$CheckOnly, [switch]$Force)
	$ui = $script:smgUi
	if (-not $ui.Statement) { Set-smgStatus 'Kein gueltiges Statement.' -IsError; return }
	$tgt = Get-smgSelectedTable 'Tgt'
	if (-not $CheckOnly -and -not $Force) {
		$msg = "Das MERGE-Statement wird jetzt gegen`r`n`r`n    {0}  ->  [{1}].[{2}].[{3}]`r`n`r`nausgefuehrt und veraendert Daten. Fortfahren?" -f $ui.Instance, $tgt.Database, $tgt.Schema, $tgt.Table
		$r = [System.Windows.Forms.MessageBox]::Show($ui.Form, $msg, 'MERGE ausfuehren', 'YesNo', 'Warning', 'Button2')
		if ($r -ne 'Yes') { return }
	}
	$sql = if ($CheckOnly) { "SET NOEXEC ON;`r`n$($ui.Statement)`r`nSET NOEXEC OFF;" } else { $ui.Statement }
	$ui.Form.Cursor = 'WaitCursor'
	try {
		$cs = Set-smgConnectionDatabase -ConnectionString $ui.ConnBase -Database $tgt.Database
		if ($CheckOnly) {
			[void](Invoke-smgSqlQuery -ConnectionString $cs -Query $sql -NonQuery -CommandTimeout 0)
			Set-smgStatus 'Syntax und Objektnamen OK (kompiliert mit SET NOEXEC ON, nichts ausgefuehrt).'
		} elseif ($ui.Statement -match 'AS NeueSchluessel') {
			# SCD 2: das Statement liefert selbst eine Zusammenfassung
			$r = Invoke-smgSqlQuery -ConnectionString $cs -Query $sql -CommandTimeout 0 | Select-Object -First 1
			$text = 'Ausgefuehrt: {0} neue Schluessel, {1} neue Versionen, {2} geschlossen, {3} Typ-1-Updates' -f
				[int]$r.NeueSchluessel, [int]$r.NeueVersionen, [int]$r.GeschlosseneSchluessel, [int]$r.Typ1Aktualisiert
			Set-smgStatus $text
			$r
		} else {
			$n = Invoke-smgSqlQuery -ConnectionString $cs -Query $sql -NonQuery -CommandTimeout 0
			Set-smgStatus ("Ausgefuehrt: {0} Zeile(n) betroffen." -f $n)
			$n
		}
	} catch {
		$text = Get-smgErrorText $_
		Set-smgStatus ("Fehler: {0}" -f $text) -IsError
		if (-not $Force) {
			[void][System.Windows.Forms.MessageBox]::Show($ui.Form, $text, 'SQL-Fehler', 'OK', 'Error')
		}
	} finally {
		$ui.Form.Cursor = 'Default'
	}
}
