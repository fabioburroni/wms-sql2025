# Esporta schema + dati di un database come script T-SQL compatibile con SQL Server 2016
# (usa SMO, lo stesso motore di "Generate Scripts" di SSMS).
param(
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$Password,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$SqlInstance = 'localhost'
)
$ErrorActionPreference = 'Stop'

Import-Module dbatools
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true | Out-Null
Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false | Out-Null

$cred   = [pscredential]::new('sa', (ConvertTo-SecureString $Password -AsPlainText -Force))
$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $cred
$db     = $server.Databases[$Database]
if (-not $db) { throw "Database '$Database' non trovato sul server." }

# Oggetti utente da esportare
$urns = [System.Collections.Generic.List[Microsoft.SqlServer.Management.Sdk.Sfc.Urn]]::new()

# Schemi creati dall'utente (esclusi dbo, guest, sys, INFORMATION_SCHEMA e schemi dei ruoli)
foreach ($s in $db.Schemas) {
    if ($s.ID -ge 5 -and $s.ID -lt 16384) { $urns.Add($s.Urn) }
}
$collections = @(
    $db.UserDefinedDataTypes,
    $db.UserDefinedTableTypes,
    $db.Tables,
    $db.UserDefinedFunctions,
    $db.Views,
    $db.StoredProcedures
)
foreach ($c in $collections) {
    foreach ($o in $c) {
        if ($o.PSObject.Properties['IsSystemObject'] -and $o.IsSystemObject) { continue }
        $urns.Add($o.Urn)
    }
}
if ($urns.Count -eq 0) { throw "Nessun oggetto utente trovato nel database." }

$scripter = [Microsoft.SqlServer.Management.Smo.Scripter]::new($server)
$opt = $scripter.Options
$opt.TargetServerVersion      = [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version130   # SQL Server 2016
$opt.TargetDatabaseEngineType = [Microsoft.SqlServer.Management.Common.DatabaseEngineType]::Standalone
$opt.ScriptSchema             = $true
$opt.ScriptData               = $true
$opt.WithDependencies         = $true    # ordina gli oggetti per dipendenza (tabelle referenziate prima)
$opt.DriAll                   = $true    # PK, FK, unique, check, default
$opt.Indexes                  = $true
$opt.Triggers                 = $true
$opt.FullTextIndexes          = $true
$opt.ExtendedProperties       = $true
$opt.Permissions              = $false
$opt.ScriptOwner              = $false
$opt.IncludeHeaders           = $false
$opt.ScriptBatchTerminator    = $true
$opt.ToFileOnly               = $true
$opt.AppendToFile             = $false
$opt.FileName                 = $OutFile
$opt.Encoding                 = [System.Text.Encoding]::Unicode   # UTF-16: nessun problema con caratteri accentati

$null = $scripter.EnumScript($urns.ToArray())

# Gli schemi devono appartenere a dbo (gli utenti originali non esistono sul server 2016)
$text = [System.IO.File]::ReadAllText($OutFile)
$text = [regex]::Replace($text, '(CREATE SCHEMA \[[^\]]+\] AUTHORIZATION )\[[^\]]+\]', '$1[dbo]')
[System.IO.File]::WriteAllText($OutFile, $text, [System.Text.Encoding]::Unicode)

Write-Host "Esportati $($urns.Count) oggetti in $OutFile"
