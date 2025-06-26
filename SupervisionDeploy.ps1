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

$configPath = ".\config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "[!]Fichier de configuration introuvable : $configPath"
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json  # Import du fichier config et récupération des paramètres.

$languageDC            = $config.LanguageDC             # Langage du DC 
$groupsName            = $config.GroupsName             # Les noms de groups différents selon le langage du DC ou custom

$scriptPathSource      = $config.ScriptPathSource       # Répertoire contenant les scripts utilisés par les tâches à déplacer
$scriptPathDestination = $config.ScriptPathDestination  # Répertoire cible où seront placés les script utilisées par les tâches

$GDLGroupOU            = $config.GDLGroupOU             # OU où seront placés les groupes créé pour les comptes de services.
$GDLGroupsName         = $config.GDLGroupsName          # Nom des groupes à créer pour les gMSA

$accountsOU            = $config.AccountsOU             # OU où seront placés les comptes de services
$accounts              = $config.Accounts               # Regroupement de paramètres nécessaires pour la création des deux comptes de services

$serverName            = $env:COMPUTERNAME              # Utilisé pour la création des gMSA
$DNSRootName           = (Get-ADDOmain).DNSRoot         # Utilisé pour la création des gMSA

$permGroupsName = $groupsName.$languageDC               # Récupère les bons SAM de groupes pour les comptes
#endregion  PARAMETRAGES ------
####~~-------------------------



####~~-------------------------
#region FONCTIONS
####~~-------------------------
function Create-Group {
    param (
        [string]$GroupName,
        [string]$GroupOU
    )
    
    try { $testGroupSMBExist = Get-ADGroup -Identity $GroupName -ErrorAction SilentlyContinue } catch{} 
    if ($testGroupSMBExist) { Write-Host "[!] Le groupe ($GroupName) existe déjà." -ForegroundColor Red; return } 
        
    New-ADGroup `
        -Name $GroupName `
        -SamAccountName $GroupName `
        -GroupScope DomainLocal `
        -GroupCategory Security `
        -Path $GroupOU
    Write-Host "[+] Groupe ($GroupName) créé." -ForegroundColor Green

}

function Create-ADgMSA {
    param (
        [string]$userName,
        [string]$serverName,
        [String]$DNSRootName,
        [string]$utile
    )
    
    try { $testgMSAExist = Get-ADServiceAccount -Identity $userName -ErrorAction SilentlyContinue } catch{} 
    if ($testgMSAExist) { Write-Host "[!] Le gMSA ($userName) existe déjà." -ForegroundColor Red; return }

    New-ADServiceAccount `
        -Name $userName `
        -Description "gMSA pour $serverName - SuperVisionAD $utile" `
        -DNSHostName "$userName.$DNSRootName" `
        -ManagedPasswordIntervalInDays 30 `
        -KerberosEncryptionType AES256 `
        -PrincipalsAllowedToRetrieveManagedPassword "$serverName$" `
        -Enabled $True

    Add-ADComputerServiceAccount -Identity $serverName -ServiceAccount $userName
    Install-ADServiceAccount $userName
    Write-Host "[+] gMSA ($userName) créé pour le serveur ($serverName)" -ForegroundColor Green
} # Create-ADgMSA---

function Add-InGroup {
    param(
        [string]$userName,
        [string]$utile,
        [Array]$GDLGroupsName,
        [Array]$permGroupsName
    )

    foreach ($group in $GDLGroupsName) {
        Add-ADGroupMember -Identity $group -Members $userName
        Write-Host "    [+] Ajouté dans le groupe ($group)" -ForegroundColor Green
    }

    if ($utile -eq "Log") {
        Add-ADGroupMember -Identity $permGroupsName[0] -Members $userName
        Write-Host "    [+] Ajouté dans le groupe ($($permGroupsName[0]))" -ForegroundColor Green
    }
    elseif ($utile -eq "Param") {
        Add-ADGroupMember -Identity $permGroupsName[1] -Members $userName
        Write-Host "    [+] Ajouté dans les groupes ($($permGroupsName[1]))" -ForegroundColor Green
    }
} # Add-InGroup---

function Create-Task {
    param (
        [string]$taskName,
        [string]$scriptPath,
        [string]$username,
        [string]$password
    )

    try { $testTaskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch{} 
    if ($testTaskExists) { Unregister-ScheduledTask -TaskName $taskName -TaskPath "\ActiveVision\" -Confirm:$false }

    $userFQDN = "$env:USERDOMAIN\$username"
    $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File $scriptPath"
    $taskTrigger = New-ScheduledTaskTrigger -Daily -At "3pm"
    
    $principal = New-ScheduledTaskPrincipal -UserId $userFQDN -LogonType Password -RunLevel Highest
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $taskAction `
        -TaskPath "\ActiveVision\" `
        -Trigger $taskTrigger `
        -Principal $principal

    Write-Host "[+] Tâche planifiée ($taskName) créée pour $username." -ForegroundColor Green
} # Create-Task---
#endregion FONCTIONS ----------
####~~-------------------------



####~~-------------------------
#region MAIN 
####~~-------------------------

## Check params
foreach ($account in $accounts) {
    if ($account.Utile -notin @("Log","Param")) {
        Write-Host "[!] Le champ Utile n'est pas configuré sur ""Log"" ou ""Param"" pour l'utilisateur $($account.Username). Actuel = ($($account.Utile))" -ForegroundColor Red
        Exit 3
    }
} 

#----------



## Traitement des scripts à copier
if (!(Test-Path $scriptPathDestination)) { # Création du répertoire de destination des scripts s'il n'existe pas
    New-Item -Path $scriptPathDestination -ItemType Directory -Force | Out-Null 
    Write-Host "[+] Répertoire ($scriptPathDestination) créé." -ForegroundColor Green
}
Copy-Item -Path "$scriptPathSource\*" -Destination "$scriptPathDestination" -Recurse -Force
Write-Host "[+] Copie des scripts dans ($scriptPathDestination) OK." -ForegroundColor Green

## Création des groupes 
foreach ($group in $GDLGroupsName) {
    Create-Group `
        -GroupName $group `
        -GroupOU $GDLGroupOU
}

## Création et paramétrage des gMSA
foreach ($account in $accounts) {
    $userName   = $account.Username
    $scriptPath = "$scriptPathDestination$($account.ScriptName)"
    $taskName   = $account.TaskName
    $utile      = $account.Utile

    ### Création KdsRootKey si nécessaire avec activation immédiate
    if (!(Get-KdsRootKey)) { 
        Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
        Write-Host "[+] Clef KDS généré." -ForegroundColor Green
    }

    ### Création des gMSA
    Create-ADgMSA `
        -userName $username `
        -serverName $serverName `
        -DNSRootName $DNSRootName `
        -utile $utile 

    $userName = "$($userName)$"

    ### Ajout des gMSA dans les groupes
    Add-InGroup `
        -userName $userName `
        -utile $utile `
        -GDLGroupsName $GDLGroupsName `
        -permGroupsName $permGroupsName

    ### Création des tasks
    Create-Task `
        -taskName $taskName `
        -scriptPath $scriptPath `
        -username $Username
}