<# .SYNOPSIS
     Call To Arms data collection 
.DESCRIPTION
     Connects to vSphere and Veeam to collect data for the Call To Arms spreadsheet.
.NOTES
     Author: Guy Allen - ****@uca.ac.uk
.LINK
     
#>


#########################################################
################    Veeam backup stats    ###############


# Load the Veeam Snap-In 
If ((Get-PSSnapin -Name VeeamPSSnapin -ErrorAction SilentlyContinue) -eq $null) {add-pssnapin VeeamPSSnapin}

# Collect all attempted VM backups within the last 12 hours;
[System.Collections.ArrayList]$RawVMs = @(Get-VBRBackupSession | 
    where {$_.creationtime -gt (Get-Date).AddHours(-12) -and $_.JobType -eq "backup"} | 
        Get-VBRTaskSession | select name, status)

# An array is required to filter out duplicate entries for backups with a 'Failed' status. This is because
# if a VM fails to backup, it will attempt multiple times. If it then succeeds, $RawVMs will contain
# each failure, incorrecty increasing the amount of failed VMs.
$TotalVMs = @($RawVMs | Sort-Object name | Get-Unique -AsString)

# Create empty arrays to use for sorting VM backup statuses;
[System.Collections.ArrayList]$Success = @()
[System.Collections.ArrayList]$InProgress = @()
[System.Collections.ArrayList]$Warning = @()
[System.Collections.ArrayList]$Failed = @()

# Add each VM to an array depending on its backup status;
ForEach ($TotalVM in $TotalVMs) {
    if ($TotalVM.status -eq "Success") {
        $Success.Add($TotalVM) 
            }
    elseif ($TotalVM.status  -eq "Failed") {
        $Failed.Add($TotalVM) 
            }
    elseif ($TotalVM.status -eq "InProgress") {
        $InProgress.Add($TotalVM) 
            }
    else {
    ($TotalVM.status -eq "Warning") 
        $Warning.Add($TotalVM) 
         }
 }

# If a VM has a 'failed' backup status, it will most likely also have a duplicate entry
# with a 'successful' status as Veeam will try again to back it up. This means a VM may 
# appear in $TotalVMs more than once, i.e. as 'Failed' and as 'Successfull', inflating 
# the number of attempted backups. To check this, two seperate arrays need creating to 
# compare the existing arrays.

# Create new arrays for final count on successful and failed backups;
[System.Collections.ArrayList]$FinalSuccess = @() 
[System.Collections.ArrayList]$FinalFailed = @() 

# Every VM in $TotalVMs which is NOT in $Failed will be added to the $FinalSuccess array;
foreach ($VM in $TotalVMs) {
    if ($Failed -notcontains $VM) {
        $FinalSuccess.Add($VM)
                } 
}

# Every VM which is in $Failed but not in $FinalSuccess will be added to the $FinalFailed array;
foreach ($VM in $Failed.name) {
    if ($FinalSuccess.name -notcontains $VM) {
        $FinalFailed.Add($VM)
            } 
}

# Provide a count of completed backups (i.e. with statuses of 'Successful' or 'Warning');
$CompleteBackUps = $($FinalSuccess.count) - ($($InProgress.Count) + $($FinalFailed.Count))


#########################################################
################     DataDomain stats     ###############


# Collect free space data from the primary datadomain;
$repolist = Get-VBRBackupRepository -Name "DataDomain1"
$r = $repolist | select -First 1
$rFree = $r.Info.CachedFreeSpace / 1TB 
$datacentre2 = [math]::Round($rFree,1)

# Collect free space data from the seconday datadomain;
$repolist = Get-VBRBackupRepository -Name "DataDomain2"
$r = $repolist | select -First 1
$rFree = $r.Info.CachedFreeSpace / 1TB 
$datacentre1 = [math]::Round($rFree,1)


#########################################################
################       vSphere stats    #################


# Connect to datacentre1 and datacentre2 vSphere
Connect-VIServer -Credential (Import-Clixml C:\Users\Administrator\Documents\pass.dat) -server $Env:datacentre1, $Env:datacentre2

# Ignore no valid ceritificate and ignore VMware user feedback option;
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope User -ParticipateInCEIP $false -Confirm:$false


# Function to collect free space on datacentre1 and datacentre2 Datastores
function Get-DataStoreSpace {
    param($name) Get-DataStore -name $name | 
        Select-Object name,@{Name = "Freespace"; Expression={[math]::round($_.FreeSpaceGB / 1KB,2)}}
            }

#Use above Function;
$dc2_storage = Get-DataStoreSpace -name $Env:dc2vsan | select -ExpandProperty Freespace
$dc1_storage = Get-DataStoreSpace -name $Env:dc1vsan | select -ExpandProperty Freespace

# Collect free CPU information across the hosts at datacentre1 then add together and format output
$dc1_cpu = @(Get-vmhost -Name $Env:search1 | select @{N='CPU GHz Free';E={[math]::Round(($_.CpuTotalMhz - $_.CpuUsageMhz)/1000,2)}})
$dc1_usage = ($dc1_cpu -replace "@{CPU GHz Free=" -replace "}")
$dc1_finalusage = ($dc1_usage | Measure-Object -sum | select sum) -replace ".*=" -replace "}"

# Collect free CPU information across the hosts at datacentre2 then add together and format output
$dc2_cpu = @(Get-vmhost -Name $Env:search2 | select @{N='CPU GHz Free';E={[math]::Round(($_.CpuTotalMhz - $_.CpuUsageMhz)/1000,2)}})
$dc2_usage = ($dc2_cpu -replace "@{CPU GHz Free=" -replace "}")
$dc2_finalusage = ($dc2_usage | Measure-Object -sum | select sum) -replace ".*=" -replace "}"


#########################################################
###############       Send Email     #################### 

# New variables to format the output of VMs into comma seperated lists
$Warningname = $($Warning.name) -join ", "
$InProgressname = $($InProgress.name) -join ", "
$FinalFailedname = $FinalFailed -join ", " 

# Set date format for email
$date = (get-date -Format "dddd dd/MM/yyyy")

# Content of the email. This will display values plus names of the VMs which have statuses of
# either 'Failed', 'InProgress' or 'Warning'. Also contains vSphere stats;
$EmailBody = 
"Call To Arms data for $date; `
`
    Total backups attempted = $($FinalSuccess.count) `
    Failed Backups = $($FinalFailed.count)     $FinalFailedname `
    Backups in progress = $($InProgress.count)     $InProgressname `
    Backups with warnings = $($Warning.count)     $Warningname `
    Successful backups = $CompleteBackups `
`
    DataDomain free space (datacentre1) = $datacentre1 TB `
    DataDomain free space (datacentre2)  = $datacentre2 TB `     
`
    CPU available (datacentre1) = $dc1_finalusage GHz `
    CPU available (datacentre2) = $dc2_finalusage GHz `
`
    vSAN storage available (datacentre1) = $dc1_storage TB`
    vSAN storage available (datacentre2) = $dc2_storage TB"


# Email configuration
Send-MailMessage -from $Env:emailfrom -to $Env:emailrecip -Subject "CTA $date" -Body ($EmailBody | Out-String) -SmtpServer $Env:smtp
