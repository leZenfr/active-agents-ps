<#
    .SYNOPSIS
    Récupération des objets du DC pour le projet de supervision BSI.
        
    .DESCRIPTION
    Récupère les propriétés d'objets (groupe, utilisateur, ordinateur) dans les OU que l'utilisateur a définit, nécessaire pour le projet de supervision BSI

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
$hostNameSRV = "srv-ActiveV"
$logFile     = ".\logs-Param.txt"


$OutputPath = "\\$hostNameSRV\partage\objects"
$OUList = @( "CN=Users,DC=cat,DC=love", "CN=Computers,DC=cat,DC=love" )
$sauvegardeFile = ".\sauvegarde.json" 
$userProperties = @(
    "objectClass",
    "objectSid", 
    "badPasswordTime", 
    "lastlogon", 
    "lockoutTime",
    "DisplayName", 
    "userPrincipalName", 
    "sAMAccountName", 
    "title",
    "l", 
    "postalCode", 
    "streetAddress", 
    "company", 
    "manager",
    "distinguishedName", 
    "accountExpires", 
    "whenChanged", 
    "whenCreated",
    "userAccountControl"
)
$computerProperties = @(
    "objectClass",
    'objectSid',
    'logonCount',
    'operatingSystem',
    'distinguishedName',
    'whenChanged',
    'whenCreated'
)
$groupProperties = @(
    "objectClass",
    'objectSid',
    'member',
    'distinguishedName',
    'whenChanged',
    'whenCreated'
)



#endregion  PARAMETRAGES ------
####~~-------------------------



####~~-------------------------
#region MAIN 
####~~-------------------------
$serverName     = $env:COMPUTERNAME

New-SmbMapping -RemotePath $outputPath

$dateLog = Get-Date -Format "dddd dd MMMM yyyy à HH:mm"
"`n[INFO] $dateLog | Démarrage récupération objets sur $ServerName (OU: $($OUList -join ' | '))" >> $logFile

while ($true) {
    $allObjects = @{
        users = @()
        computers = @()
        groups = @()
    }

    foreach ($OU in $OUList) {
        $allObjects.users     += Get-ADObject -Filter { objectClass -eq 'user' -and objectClass -ne 'computer' } -SearchBase $OU -Properties $userProperties     | Select-Object -Property $userProperties
        $allObjects.computers += Get-ADObject -Filter { objectClass -eq 'computer' }                             -SearchBase $OU -Properties $computerProperties | Select-Object -Property $computerProperties
        $allObjects.groups    += Get-ADObject -Filter { objectClass -eq 'group' }                                -SearchBase $OU -Properties $groupProperties    | Select-Object -Property $groupProperties
    }

    $currentSidDict = @{}
    foreach($objectClass in $allObjects.Keys) {
        foreach ($object in $allObjects.$objectClass) {
            $object.objectSid = $object.objectSid.Value # traitement de l'object objectSid pour ne garder que sa valeur Sid finale
            $currentSidDict[$object.objectSid] = $object # remplissage du dictionnaire par Sid pour faciliter le traitement des différences
        }
    }

    $date = Get-Date -Format "-yyyyMMdd-HHmm-ss"
    $differenceFile = "$OUtputPath\difference$date.json" 

    if (Test-Path $sauvegardeFile) {
        $oldSidDict = Get-Content $sauvegardeFile | ConvertFrom-Json

        $diffs = @{}
        foreach ($sid in $currentSidDict.Keys) {
            if ($oldSidDict.PSObject.Properties.Name -contains $sid) {
                $before = $oldSidDict.$sid
                $after = $currentSidDict.$sid

                if (Compare-Object $before $after) {
                    $diffs[$sid] = $after
                }
            } else {
                $diffs[$sid] = $currentSidDict.$sid
                write-host $sid
            }
        }

        if($diffs.Count -gt 0) {
            $diffs | ConvertTo-Json | Out-File $differenceFile -Encoding UTF8 # Export des différences
            $diffs | ConvertTo-Json | Out-File "C:\scripts\difference$date.json" -Encoding UTF8 # A supprimer en prod
            "[+] OutFile difference réduite à l'emplacement $differenceFile" >> $logFile
        } else { "[INFO] Pas de différence trouvé durant ce scan" >> $logFile }
    } else { # Si première execution, export de toutes les données en tant que différence
        $currentSidDict | ConvertTo-Json | Out-File $differenceFile -Encoding UTF8 
        $currentSidDict | ConvertTo-Json | Out-File "C:\scripts\difference$date.json" -Encoding UTF8 # A supprimer en prod

        "[+] OutFile difference complete à l'emplacement $differenceFile" >> $logFile
    } 

    # Export en JSON
    $currentSidDict | ConvertTo-Json | Out-File $sauvegardeFile -Encoding UTF8
    "[+] OutFile sauvegarde à l'emplacement $sauvegardeFile" >> $logFile

    Start-Sleep -Seconds 7200
}
#endregion MAIN ---------------
####~~-------------------------