<#
.SYNOPSIS
This script converts a specific template to a VM, exports it from one vCenter, and imports it into another using PowerCLI.

.DESCRIPTION
The script prompts the user for source and destination vCenter information.
If the source and destination vCenter names do not contain "dev", it asks for confirmation.
It connects to the vCenters, compares the list of templates with the name "tmpl-*", and then converts the specified template to a VM,
exports it from the source, imports it into the destination, moves it to the "templates" folder on the destination,
and deletes local files created during the export.
The script prints a rotating cat in different colors to visualize the progress.
User must confirm before executing the export and import operations.

.NOTES
Requires LATEST PowerCLI to function on vSphere 8.x
Sanitized for external use

.TODO
Error handling
Might need to find a way to refresh $destinationVCenter before starting the import, since the export takes so long and we connect at the start
#>

# Display a warning about the perils of running the script
Write-Host "WARNING: This script exports and imports a specific template between vCenters. Use with caution in production environments." -ForegroundColor Yellow

# Display a red 5x5 ASCII cat
Write-Host @'
                 /\_/\ 
                ( o.o ) 
                > ^ < 
'@ -ForegroundColor Red

# Prompt for source and destination vCenter
$sourceVCenter = Read-Host "Enter the source vCenter name"
$destinationVCenter = Read-Host "Enter the destination vCenter name"

# Check if source and destination vCenter names contain "dev"
if ($sourceVCenter -notlike "*dev*" -or $destinationVCenter -notlike "*dev*") {
    # Prompt for confirmation due to non-"dev" vCenter names
    $confirmation = Read-Host "WARNING: Source or destination vCenter is not 'dev'. Proceed with caution? (y/n)"
    if ($confirmation -ne 'y') {
        Write-Host "Operation canceled."
        Exit
    }
}

# Connect to source and destination vCenters
Connect-VIServer -Server $sourceVCenter -WarningAction SilentlyContinue
Connect-VIServer -Server $destinationVCenter -WarningAction SilentlyContinue

# Get a list of templates with the name "tmpl-*" on the source
$sourceTemplates = Get-Template -Name "tmpl-*" -Server $sourceVCenter -ErrorAction SilentlyContinue

# Check if any templates are found on the source
if ($sourceTemplates.Count -eq 0) {
    Write-Host "No templates found with the name 'tmpl-*' on the source. Exiting."
    Exit
}

# Get a list of templates with the name "tmpl-*" on the destination
$destinationTemplates = Get-Template -Name "tmpl-*" -Server $destinationVCenter -ErrorAction SilentlyContinue

# Check if any templates are found on the destination
if ($destinationTemplates.Count -eq 0) {
    Write-Host "No templates found with the name 'tmpl-*' on the destination. All source templates are available for selection."
} else {
    # Exclude templates that already exist on the destination from the selectable list
    $sourceTemplates = $sourceTemplates | Where-Object { $template = $_; $destinationTemplates -notcontains { $_.Name -eq $template.Name } }
}

# Display a numbered list of template names for the user to choose from
$templateChoice = $sourceTemplates | Out-GridView -Title "Select a template to export and import" -PassThru

# Check if the user made a selection
if ($templateChoice -eq $null) {
    Write-Host "Operation canceled. No template selected."
    Exit
}


# Display a summary of the operation and prompt for confirmation
Write-Host "Source vCenter: $sourceVCenter"
Write-Host "Destination vCenter: $destinationVCenter"
Write-Host "Template to export and import: $($templateChoice.Name)"
$confirmation = Read-Host "Press 'y' to confirm and start the export and import operation, or 'n' to cancel."

if ($confirmation -ne 'y') {
    Write-Host "Operation canceled."
    Exit
}

# Function to print a rotating cat
function Print-RotatingCat($progress) {
    $colors = @("Red", "Yellow", "Green")
    $cat = @'
                 /\_/\
                ( o.o )
                > ^ <
'@
    $color = $colors[$progress % $colors.Count]
    Write-Host $cat -ForegroundColor $color
}

# Print rotating cat based on progress
Print-RotatingCat 0

# Convert the template to a VM
Set-Template -Server $sourceVCenter -Template $templateChoice -ToVM -Confirm:$false

# Wait for 30 seconds while template operation executes
Start-Sleep -Seconds 30

# Remove any mounted CD drives
Get-VM -Server $sourceVCenter -Name $templateChoice | Get-CDDrive | Set-CDDrive -NoMedia -confirm:$false

# Wait for 30 seconds while template operation executes
Start-Sleep -Seconds 30

# Export the VM using PowerCLI with SHA1 algorithm
$exportedTemplatePath = Get-VM $templateChoice | Export-VApp -Server $sourceVCenter -Force -Destination "$env:USERPROFILE\Downloads" -SHAAlgorithm SHA1

# Print rotating cat based on progress
Print-RotatingCat 1

# This could be done more elegantly probably, also only works on dev

$VMName = $templateChoice
$datacenterName = ""
$clusterName = ""
$provisioningDataStoreName = ""
$portGroupName = ""

$newVMDatacenter = Get-Datacenter -Name $datacenterName -Server $destinationVCenter
$newVMCluster = Get-Cluster -Name $clusterName -Server $destinationVCenter
$provisioningDatastore = Get-Datastore -Name $provisioningDataStoreName -Location $newVMDatacenter -Server $destinationVCenter
$newVMHost = Get-VMHost -Location $newVMCluster -Server $destinationVCenter | Select-Object -first 1

# Import the VM into the destination using PowerCLI
if (Import-VApp -Source "$env:USERPROFILE\Downloads\$templateChoice\$templateChoice.ovf" -Location $newVMCluster -VMHost $newVMHost -Datastore $provisioningDatastore -Server $destinationVCenter -Force) {
    # Import successful, proceed to set the VM back to a template on the destination server
    Print-RotatingCat 2

    # Set the VM back to a template on the destination server, then to template on destination server
    Get-VM -Name $templateChoice | Set-VM -Server $sourceVCenter -ToTemplate -Confirm:$false
    
    # Wait for 30 seconds while template operation executes
    Start-Sleep -Seconds 30
    
    # Move the template to the "templates" folder on the destination
    Move-Template -Template -Destination (Get-Folder -Name "Templates" -Server $destinationVCenter)
    

    # Delete local files associated with the export (including the folder)
    # Still need to delete the folder manually
    Remove-Item -Path $exportedTemplatePath -Recurse -Force

    # Print a green cat at the end
    Print-RotatingCat 3

    Write-Host "Template export and import completed successfully."

} else {
    # Import failed, display an error message
    Write-Host "Import failed. Operation aborted."

}

# Disconnect from vCenters
Disconnect-VIServer -Server $sourceVCenter -Force -Confirm:$false
Disconnect-VIServer -Server $destinationVCenter -Force -Confirm:$false
