param($eventGridEvent, $TriggerMetadata)

# By default, stop on any error
# (for more details, see <link to the doc, e.g. https://docs.microsoft.com/powershell/module/microsoft.powershell.core/about/about_preference_variables#erroractionpreference>)
$ErrorActionPreference = 'Stop'

# Evaluate
$modification_date = $eventGridEvent.eventTime
$eventType = $eventGridEvent.eventType
$resourceId = $eventGridEvent.data.resourceUri
Write-Verbose "resourceId = $resourceId"
$caller = $eventGridEvent.data.claims.name
if ($null -eq $caller) {
    if ($eventGridEvent.data.authorization.evidence.principalType -eq "ServicePrincipal") {
        $caller = (Get-AzADServicePrincipal -ObjectId $eventGridEvent.data.authorization.evidence.principalId).DisplayName
        if ($null -eq $caller) {
            Write-Host "MSI may not have permission to read the applications from the directory"
            $caller = $eventGridEvent.data.authorization.evidence.principalId
        }
    }
}
else {
    #Prefer to output the UPN for users, Refere to : https://docs.microsoft.com/en-us/azure/event-grid/event-schema-resource-groups
    $caller = $eventGridEvent.data.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn"
    if ($null -eq $caller) {
        $caller = $eventGridEvent.data.claims.name
        Write-Host "User : $caller doesn't share it's upn."
    }
}

if (($null -eq $caller) -or ($null -eq $resourceId)) {
    Write-Host "Skipping event as ResourceId or Caller is null"
    exit;
}
elseif ($caller -eq $env:WEBSITE_SITE_NAME) {
    Write-Warning "Skipping event as last editor is the function itself : $caller for resourceId : $resourceId"
    exit;
}

$ignoreTypes = @("providers/Microsoft.Resources/deployments", "providers/Microsoft.Resources/tags", "providers/Microsoft.Network/frontdoor", "providers/microsoft.insights/autoscalesettings", "Microsoft.Compute/virtualMachines/extensions", "Microsoft.Compute/restorePointCollections", "Microsoft.Classic")
foreach ($case in $ignoreTypes) {
    if ($resourceId -match $case) {
        Write-Host "Skipping event as resourceId contains: $case for resourceId : $resourceId"
        exit;
    }
}

$ignoreRgNames = @("Add-Here-Rg-To-Exclude-If-Needed")
foreach ($case in $ignoreRgNames) {
    if ($resourceId -match $case) {
        Write-Host "Skipping event as resource contained in resource group name: $case"
        exit;
    }
}

if ($eventType -eq "Microsoft.Resources.ResourceDeleteSuccess") {
    $resource = Get-AzResource -ResourceId $($resourceId.Split("/")[0..8] -join "/") -ErrorVariable notPresent -ErrorAction SilentlyContinue
    if ($notPresent) {
        Write-Host "Skipping as resource has been deleted for resourceId : $resourceId"
        exit;
    }
    else { $resourceId = $resource.Id }
}
else {
    if ($resourceId.Split("/").Count -eq 5) {
        #Case for Resource Groups
        $resource = Get-AzResourceGroup -ResourceId $resourceId
        $resourceId = $resource.ResourceId
    }
    else {
        #Case for Resources
        $resource = Get-AzResource -ResourceId $resourceId
        $resourceId = $resource.Id
    }
    
}

# Variable
$tags = (Get-AzTag -ResourceId $resourceId).Properties
$RGTags = (Get-AzResourceGroup -Name $resource.ResourceGroupName).Tags
$resourcetags = [System.Collections.Hashtable]::new($tags.TagsProperty) #convert dictionary to hashtable

# Function
Function Merge-Hashtables {
    $Output = @{}
    ForEach ($Hashtable in ($Input + $Args)) {
        If ($Hashtable -is [Hashtable]) {
            ForEach ($Key in $Hashtable.Keys) { $Output.$Key = $Hashtable.$Key }
        }
    }
    $Output
}

# Action
if (!($tags.TagsProperty.ContainsKey('creator')) -or ($null -eq $tags)) {
    Write-Host "Tag creator doesn't exist"
    $newtags = @{
        creator         = $caller
        creationdate    = $modification_date	
        editor          = $caller
        lasteditiondate = $modification_date	
    }
    $messsage = "Just added creator tag with user: $caller on resourceId : $resourceId"
}
else {
    Write-Host "Tag creator already exists"
    $newtags = @{
        editor          = $caller
        lasteditiondate = $modification_date	
    }
    $messsage = "Just added editor tag with user: $caller on resourceId : $resourceId"
}

$targetTags = $RGTags, $resourcetags, $newtags | Merge-Hashtables #$newtags overwrites $resourcetags that overwites $RGTags
Update-AzTag -ResourceId $resourceId -Operation Merge -Tag $targetTags
Write-Host $messsage