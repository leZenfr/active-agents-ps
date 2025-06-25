<#
    .SYNOPSIS
    Récupération des Logs du DC pour le projet de supervision BSI.
        
    .DESCRIPTION
    Récupère une liste de logs prédéfinies pour les exporter en .json afin d'être traités pour le serveur de supervision. Développer pour le projet de supervision BSI

    .Notes
    Author: yann.lucas@giboire.com
      Date: 04/06/2025
      Ver.: 01.00
          
    History : 
    
#>

####~~-------------------------
#region  PARAMETRAGES
####~~-------------------------
Set-Location -Path $PSScriptRoot
$HostNameSRV = "srv-ActiveV"
$logFile     = ".\logs-Param.txt"


$OutputPath = "\\$hostNameSRV\partage\objects"
$configIDParamFile = ".\Config-IDParam.json"
$lastIDFile        = ".\lastID.txt" 
$eventID = @(
    4720, 4722, 4725, 4726, 4738, 4740, 4781, # Audit User Account Management
    4731, 4732, 4733, 4734, 4735, 4727, 4737, 4728, 4729, 4730, 4754, 4755, 4756, 4757, 4758, 4764, # Audit Security Group Management
    4741,4742,4743 # Audit Computer Account Management
)

$actualLastID = 0
$recordIDHasBeenReset = $False
#endregion  PARAMETRAGES ------
####~~-------------------------



####~~-------------------------
#region MAIN 
####~~-------------------------
if (-not (Test-Path $configIDParamFile)) {
    if ($debug) { "[!] Fichier de configuration introuvable : $configIDParamFile" >> $logFile} ; exit 1 }
$configIDParam = Get-Content $configIDParamFile | ConvertFrom-Json

$serverName = $env:COMPUTERNAME
$serverSID  = (Get-ADComputer ($serverName+'$') -Properties objectSID).objectSID.Value
$serverIP   = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object -ExpandProperty IPAddress

New-SmbMapping -RemotePath $outputPath

$dateLog = Get-Date -Format "dddd dd MMMM yyyy à HH:mm"
"[INFO] $dateLog | Démarrage surveillance sur $ServerName | ($lastID) (ID: $($EventID -join ', '))" >> $logFile

while ($true) {
    
    if (Test-Path $lastIDFile) { 
        $lastID = Get-Content $lastIDFile | Out-String | ForEach-Object { $_.Trim() } 
        $actualLastID = (Get-WinEvent -MaxEvents 1 -FilterHashtable @{ logName = 'Security' }).RecordID
        if ($actualLastID -lt $lastID) {
            $recordIDHasBeenReset = $True
        }
    } else { 
        $lastID = 0 
    }

    # FilterHashtable iD fonctionne jusqu'à 22 ID maximum, j'ai donc coupé la fonction en deux, ne pas toucher sauf si autre solution, ça fonctionne bien comme ça
    # ($a -or ($b -and $c -and $d)) soit il récupère les RecordID plus elevé que lastID, soit il récupère aussi ceux entre 0 et actualLastID en cas de reset
    $events =  Get-WinEvent -FilterHashtable @{ logName = 'Security' ; iD = $EventID[0..15] }               | Where-Object { $_.RecordId -gt $lastID -Or ($_.RecordId -ge 0 -and $_.RecordId -le $actualLastID -and $recordIDHasBeenReset) } 
    $events += Get-WinEvent -FilterHashtable @{ logName = 'Security' ; iD = $EventID[15..$EventID.Length] } | Where-Object { $_.RecordId -gt $lastID -Or ($_.RecordId -ge 0 -and $_.RecordId -le $actualLastID -and $recordIDHasBeenReset) }
    
    if ($events.Count -gt 0) {
        $jsonList = @()

        foreach ($event in $events) {
            $lastID = [math]::Max($lastID, $event.RecordId)
            $xml = [xml]$event.ToXml()
            $data = @{}
            $index = 0

            foreach ($field in $xml.Event.EventData.Data) {
                $data[$configIDParam.$($event.ID)."Param$index"] = $field.'#text'
                $index++
            }

            $entry = [PSCustomObject]@{
                TimeCreated = $event.TimeCreated
                EventID     = $event.ID
                ServerName  = $serverName
                ServerSID   = $serverSID
                ServerIP    = $serverIP
                RecordID    = $event.RecordID
                Parameters  = $data
            }

            $jsonList += $entry
        }

        $date = Get-Date -Format "-yyyyMMdd-HHmm-ss"
        $logOutputFile = "$outputPath\Log-$serverName$date.json"

        $jsonList | ConvertTo-Json | Set-Content $logOutputFile -Encoding UTF8
        "[+] OutFile jsonList à l'emplacement $logOutputFile" >> $logFile

        if ($recordIDHasBeenReset) {
            $recordIDHasBeenReset = $False
            $lastID = $actualLastID
        }

        $lastID | Out-File -FilePath $lastIDFile -Encoding ASCII
        "[+] OutFile lastID à l'emplacement $lastIDFile" >> $logFile
    }
    "[INFO] Boucle finie" >> $logFile
    Start-Sleep -Seconds 120
}
#endregion MAIN ---------------
####~~-------------------------