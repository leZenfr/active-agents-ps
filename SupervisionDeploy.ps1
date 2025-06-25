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

$FRGroupsName = @("Lecteurs des journaux d’événements","Admins du domaine")
$ENGroupsName = @("Lecteurs des journaux d’événements","Admins du domaine") # TODO : récupérer les noms anglais

Set-Location -Path $PSScriptRoot
$configPath = ".\config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "[!]Fichier de configuration introuvable : $configPath"
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

$languageDC            = $config.LanguageDC

$scriptPathSource      = $config.ScriptPathSource
$scriptPathDestination = $config.ScriptPathDestination

$GDLGroupOU            = $config.GDLGroupOU
$GDLSVCGroupName       = $config.GDLSVCGroupName
$GDLSMBGroupName       = $config.GDLSMBGroupName

$accountsOU            = $config.AccountsOU
$accounts              = $config.Accounts

$serverName            = $env:COMPUTERNAME
$DNSRootName           = (Get-ADDOmain).DNSRoot

#endregion  PARAMETRAGES ------
####~~-------------------------




####~~-------------------------
#region FONCTIONS
####~~-------------------------

Function New-LurchPassphrase {
    $wordDatabase = "Bad;Feeling;Plan;Grrr;Coach;Play;Give;Chance;Handle;The;Rock;Dog;Crap;Hate;Spider;Down;42;Handball;Squash;Pumpkin;Bat;Skull;Black;Adams;Family;Telephone;Trainer;Close;Please;Shrink;Clique;Quiet;Belt;Clue;Alive;Academy;Litigation;Dedicate;Bush;Air;Compete;Grandfather;Sausage;Copyright;Middle;Enfix;Comprehensive;Acute;Aviation;Plagiarize;Write;Strong;Preach;Pan;Peasant;Scan;Quiet;Bird;Track;So;Output;Deserve;Enter;Tail;Give;Represent;Topple;Print;Pardon;Bar;Restrain;Disk;Prey;Create"
    $LurchWordsList = [array]($wordDatabase -split ';')
    $LurchKnownWord = $LurchWordsList.Count
    $passphraseBomb = @('-','+','=','_',' ')

    $words = 0
    $passphrase = ""
    While ($words -lt 4) {
        $Random = Get-Random -Minimum 0 -Maximum ($LurchKnownWord -1)
        $newWord = $LurchWordsList[$Random]
        if ($passphrase -ne "") {
            $random = Get-Random -Minimum 0 -Maximum 4
            $newWord = "$($passphraseBomb[$random])$newWord"
        }
        $passphrase += $newWord
        $words++
    }

    return $passphrase
} # New-LurchPassphrase---

function Create-ADAccount {
    param (
        [string]$userName,
        [string]$password,
        [string]$OU
    )
    $securePwd = ConvertTo-SecureString $password -AsPlainText -Force
    New-ADUser `
        -Name $userName `
        -SamAccountName $userName `
        -AccountPassword $securePwd `
        -Path $OU `
        -Enabled $true

    Write-Host "[+] Utilisateur ($userName) créé. Veuillez prendre note du mot de passe : $password" -ForegroundColor Green
    sleep 5
} # Create-ADAccount---

function Add-InGroup {
    param(
        [string]$userName,
        [string]$utile,
        [string]$GDLSVCGroupName,
        [string]$GDLSMBGroupName,
        [Array]$permGroupsName
    )

    Add-ADGroupMember -Identity $GDLSVCGroupName -Members $userName
    Write-Host "    [+] Ajouté dans le groupe ($GDLSVCGroupName)" -ForegroundColor Green
    Add-ADGroupMember -Identity $GDLSMBGroupName -Members $userName
    Write-Host "    [+] Ajouté dans le groupe ($GDLSMBGroupName)" -ForegroundColor Green

    if ($utile -eq "Log") {
        Add-ADGroupMember -Identity $permGroupsName[0] -Members $userName
        Write-Host "    [+] Ajouté dans le groupe ($($permGroupsName[0]))" -ForegroundColor Green
    }
    else {
        Add-ADGroupMember -Identity $permGroupsName[1] -Members $userName
        Write-Host "    [+] Ajouté dans les groupes ($GDLSVCGroupName) et ($($permGroupsName[1]))" -ForegroundColor Green
    }
} # Add-InGroup---

function Create-Task {
    param (
        [string]$taskName,
        [string]$scriptPath,
        [string]$username,
        [string]$password,
    )

    $userFQDN = "$env:USERDOMAIN\$username"
    $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File $scriptPath"
    $taskTrigger = New-ScheduledTaskTrigger -Daily -At "3pm"
    
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -User $userFQDN -Password $password

    Write-Host "[+] Tâche planifiée ($taskName) créée pour $username." -ForegroundColor Green
} # Create-Task---

#endregion FONCTIONS ----------
####~~-------------------------





####~~-------------------------
#region MAIN 
####~~-------------------------
if ($languageDC -notin @("FR","EN")) {
    Write-Host "[!] languageDC n'est pas configuré sur ""FR"" ou ""EN"". Actuel = ($languageDC)" -ForegroundColor Red
    Exit 1
}

foreach ($account in $accounts) {
    if ($account.Utile -notin @("Log","Param")) {
        Write-Host "[!] Le champ Utile n'est pas configuré sur ""Log"" ou ""Param"" pour l'utilisateur $($account.Username). Actuel = ($($account.Utile))" -ForegroundColor Red
        Exit 3
    }
}

#----------

if ($languageDC -eq "FR" ) {
    $permGroupsName = $FRGroupsName
} else {
    $permGroupsName = $ENGroupsName
}

if (!(Test-Path $scriptPathDestination)) { 
    New-Item -Path $scriptPathDestination -ItemType Directory -Force | Out-Null 
    Write-Host "[+] Répertoire ($scriptPathDestination) créé." -ForegroundColor Green
}
Copy-Item -Path "$scriptPathSource\*" -Destination "$scriptPathDestination" -Recurse -Force
Write-Host "[+] Copie des scripts dans ($scriptPathDestination) OK." -ForegroundColor Green


try { $testGroupExist = Get-ADGroup -Identity $GDLSVCGroupName -ErrorAction SilentlyContinue } catch{}
if ($testGroupExist) {
    Write-Host "[!] Le groupe ($GDLSVCGroupName) existe déjà." -ForegroundColor Red
} else {
    New-ADGroup `
        -Name $GDLSVCGroupName `
        -SamAccountName $GDLSVCGroupName `
        -GroupScope DomainLocal `
        -GroupCategory Security `
        -Path $GDLGroupOU `
        -Description "Groupe regroupant les objets autorisés à ouvrir une session en tant que tâche"
    Write-Host "[+] Groupe ($GDLSVCGroupName) créé." -ForegroundColor Green
}

foreach ($account in $accounts) {

    $userName = $account.Username
    $password = New-LurchPassphrase

    try { $testAccountExist = Get-ADUser -Identity $username -ErrorAction SilentlyContinue } catch{}
    if ($testAccountExist) { # Si compte existe déjà
        Set-ADAccountPassword -Identity $userName -Reset -NewPassword (ConvertTo-SecureString $password -AsPlainText -Force)
        Write-Host "[!] Utilisateur ($userName) déjà existant. Création d'un nouveau mot de passe, veuillez en prendre note : $password" -ForegroundColor Red
    } 
    else {
        Create-ADAccount `
            -username $userName `
            -password $password `
            -OU $accountsOU
    }

    Add-InGroup `
        -userName $userName `
        -utile $account.Utile `
        -GDLSVCGroupName $GDLSVCGroupName `
        -GDLSMBGroupName $GDLSMBGroupName `
        -permGroupsName $permGroupsName


    $scriptPath = "$scriptPathDestination$($account.ScriptName)"

    # TODO : tester si la task existe déjà (recréation ou changement du mot de passe du compte si possible)
    Create-Task `
        -taskName $account.TaskName `
        -scriptPath $scriptPath `
        -username $Username `
        -password $password
}