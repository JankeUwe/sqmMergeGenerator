<#
	===========================================================================
	 Module Manifest
	-------------------------------------------------------------------------
	 Module Name: sqmMergeGenerator
	===========================================================================
#>

@{
	RootModule			   = 'sqmMergeGenerator.psm1'
	ModuleVersion		   = '0.1.0.0'
	GUID				   = '6f3d2c1e-8a4b-4f7e-9c2d-5b1a7e3f9d40'
	Author				   = 'Uwe Janke'
	CompanyName		       = 'dtcSoftware'
	Copyright			   = '(c) 2026 Uwe Janke. MIT License.'
	Description		       = 'T-SQL MERGE generator with WinForms GUI: pick server, source and target table, map columns SSIS-style, choose join keys and get a ready-to-run MERGE statement instantly. Supports plain upsert (SCD type 1) and slowly changing dimensions type 2 with per-column change type.'
	PowerShellVersion	   = '5.1'
	DotNetFrameworkVersion = '4.5'
	CLRVersion			   = '4.0'
	ProcessorArchitecture  = 'None'

	FunctionsToExport	   = @(
		'Get-sqmMergeDatabase'
		'Get-sqmMergeTable'
		'Get-sqmMergeColumn'
		'New-sqmMergeStatement'
		'Show-sqmMergeGeneratorGui'
	)
	CmdletsToExport	       = @()
	VariablesToExport	   = @()
	AliasesToExport	       = @()

	PrivateData		       = @{
		PSData = @{
			Tags	   = @('SQLServer', 'MERGE', 'T-SQL', 'SCD', 'SlowlyChangingDimension', 'DataWarehouse', 'WinForms')
			LicenseUri = 'https://github.com/JankeUwe/sqmMergeGenerator/blob/main/LICENSE'
			ProjectUri = 'https://github.com/JankeUwe/sqmMergeGenerator'
		}
	}
}
