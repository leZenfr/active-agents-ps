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
$HostNameSRV = "srv-ActiveV"       # Nom du serveur de supervision ActiveVision
$logFile     = ".\logs-Param.txt"  # Emplacement du fichier de log
$SleepTime   = 600                 # Intervalle entre les exécutions
$OUList = @(                       # Liste des OU à superviser (Utilisateur, Groupes, Ordinateurs)
    "CN=Users,DC=cat,DC=love", 
    "CN=Computers,DC=cat,DC=love" 
)

$OutputPath  = "\\$hostNameSRV\partage\objects" # Path SMB sur le serveur de supervision ActiveVision
$saveFile    = ".\ObjectsSave.json"             # Fichier contenant la totalité des objets, sert à détecter les différences entre les traitements

$userProperties = @(        # Liste des paramètres récupérés sur les objets utilisateur
    "objectClass", "objectSid", "badPasswordTime", "lastlogon", "lockoutTime",
    "DisplayName", "userPrincipalName", "sAMAccountName", "title","l", 
    "postalCode", "streetAddress", "company", "manager","distinguishedName", 
    "accountExpires", "whenChanged", "whenCreated", "pwdLastSet", "userAccountControl"
)

$computerProperties = @(    # Liste des paramètres récupérés sur les objets ordinateur
    "objectClass", 'objectSid', 'logonCount', 'operatingSystem', 'distinguishedName',
    'whenChanged', 'whenCreated'
)

$groupProperties = @(       # Liste des paramètres récupérés sur les objets groupe
    "objectClass", 'objectSid', 'member', 'distinguishedName', 'whenChanged',
    'whenCreated'
)
#endregion  PARAMETRAGES ------
####~~-------------------------



####~~-------------------------
#region MAIN 
####~~-------------------------
try{ New-SmbMapping -RemotePath $outputPath -ErrorAction SilentlyContinue } # Connexion au partage SMB
catch { "[!] Erreur lors de la tentative de connexion au partage SMB ($outputPath), arrêt du script" >> $logFile; exit 1 }

$serverName     = $env:COMPUTERNAME
$dateLog = Get-Date -Format "dddd dd MMMM yyyy à HH:mm"
"`n[INFO] $dateLog | Démarrage récupération objets sur $ServerName (OU: $($OUList -join ' | '))" >> $logFile

while ($true) {
    $allObjects = @{
        users = @()
        computers = @()
        groups = @()
    }

    foreach ($OU in $OUList) { # Récupération de tous les objets dans les OU
        $allObjects.users     += Get-ADObject -Filter { objectClass -eq 'user' -and objectClass -ne 'computer' } `
            -SearchBase $OU -Properties $userProperties | 
                Select-Object -Property $userProperties
        $allObjects.computers += Get-ADObject -Filter { objectClass -eq 'computer' } `
            -SearchBase $OU -Properties $computerProperties | 
                Select-Object -Property $computerProperties
        $allObjects.groups    += Get-ADObject -Filter { objectClass -eq 'group' } `
            -SearchBase $OU -Properties $groupProperties | 
                Select-Object -Property $groupProperties
    }

    $currentSidDict = @{}
    foreach($objectClass in $allObjects.Keys) { 
        foreach ($object in $allObjects.$objectClass) {
            $object.objectSid = $object.objectSid.Value  # traitement de l'object objectSid pour ne garder que sa valeur Value
            $currentSidDict[$object.objectSid] = $object # remplissage du dictionnaire par Sid pour faciliter le traitement des différences
        }
    }

    $date = Get-Date -Format "-yyyyMMdd-HHmm-ss"
    $differenceFile = "$OUtputPath\difference$date.json" 

    if (Test-Path $saveFile) { # Si script déjà exécuté, différenciation pour n'envoyer que les nouveaux objets et ceux ayant eu des modifications
        $oldSidDict = Get-Content $saveFile | ConvertFrom-Json 

        $diffs = @{}
        foreach ($sid in $currentSidDict.Keys) { # travail sur les SID, valeur unique de chaque compte ayant très peu de chance d'être modifié.
            if ($oldSidDict.PSObject.Properties.Name -contains $sid) { # Si l'objet récupéré pendant l'exécution existe dans la save, challenge compare pour savoir si modification il y a eu
                $before = $oldSidDict.$sid
                $after = $currentSidDict.$sid
                if (Compare-Object $before $after) { 
                    $diffs[$sid] = $after
                }

            } else { # Sinon nouvel objet donc ajout direct dans la liste à envoyer
                $diffs[$sid] = $currentSidDict.$sid
            }
        }

        if($diffs.Count -gt 0) { 
            $diffs | ConvertTo-Json | Out-File $differenceFile -Encoding UTF8 # Export des différences en json de tous les objets trouvés lors de cette exécution
            "[+] OutFile difference réduite à l'emplacement $differenceFile" >> $logFile

            $currentSidDict | ConvertTo-Json | Out-File $saveFile -Encoding UTF8  # Export en json de tous les objets trouvés lors de cette exécution
            "[+] OutFile sauvegarde à l'emplacement $saveFile" >> $logFile
        } else { "[INFO] Pas de différence trouvé durant ce scan" >> $logFile }

    } else { # Si première execution, export de toutes les données en tant que différence
        $currentSidDict | ConvertTo-Json | Out-File $differenceFile -Encoding UTF8 # Export en json de tous les objets trouvés lors de cette exécution
        "[+] OutFile difference complete à l'emplacement $differenceFile" >> $logFile

        $currentSidDict | ConvertTo-Json | Out-File $saveFile -Encoding UTF8  # Export en json de tous les objets trouvés lors de cette exécution
        "[+] OutFile sauvegarde à l'emplacement $saveFile" >> $logFile
    } 

    Start-Sleep -Seconds $SleepTime 
}
#endregion MAIN ---------------
####~~-------------------------