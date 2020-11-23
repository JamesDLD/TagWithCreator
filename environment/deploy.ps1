## Variable
$AzureRmSubscriptionName = "sub-sbx-001"             # <-- REPLACE the variable values with your own values.
$resourceGroupName = "rg-in-sbx-monitor-001"         # <-- 
$functionName = "func-in-sbx-monitor-001"            # <--
$appServicePlanName = "plan-in-sbx-monitor-001"      # <--
$storageAccountName = "stinsbxmonitor001"            # <-- Ensure the storage account name is unique
$appInsightsName = "appi-in-sbx-monitor-001"         # <--
$systemTopicsName = "evgst-in-sbx-monitor-001"       # <--
$location = "francecentral"                          # <-- Ensure that the location is a valid Azure location
$params = @{
    storageAccountName = $storageAccountName.ToLower()
    appServicePlanName = $appServicePlanName
    appInsightsName    = $appInsightsName
    functionName       = $functionName
}

## Connectivity
# Login first with Connect-AzAccount if not using Cloud Shell
$AzureRmContext = Get-AzSubscription -SubscriptionName $AzureRmSubscriptionName | Set-AzContext -ErrorAction Stop
Select-AzSubscription -Name $AzureRmSubscriptionName -Context $AzureRmContext -Force -ErrorAction Stop

# Creating the Resource Grou if needed 
Get-AzResourceGroup -Name $resourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
if ($notPresent) {
    New-AzResourceGroup -Name $resourceGroupName -Location $location -Force -Tag @{creator = $AzureRmContext.Account.Id }
}

## Deploy the function App
$output = New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
    -TemplateFile .\azuredeploy-function.json `
    -TemplateParameterObject $params `
    -confirm

## Assign privileges
New-AzRoleAssignment -RoleDefinitionName "Reader" -ObjectId $output.Outputs.managedIdentityId.Value -ErrorAction SilentlyContinue -Verbose
New-AzRoleAssignment -RoleDefinitionName "Tag Contributor" -ObjectId $output.Outputs.managedIdentityId.Value -ErrorAction SilentlyContinue -Verbose

## Zip Deploy the function App
Push-Location
Set-Location ..\functions
Compress-Archive -Path * -DestinationPath ..\environment\functions.zip -Force -Verbose
Pop-Location

$file = (Get-ChildItem .\functions.zip).FullName
Publish-AzWebApp -ResourceGroupName $resourceGroupName -Name $functionName -ArchivePath $file -Verbose -Force
Remove-Item $file -Force

# Deploy the EventGrid system Topic
$params = @{
    resourceId                = $output.Outputs.resourceId.Value 
    systemTopicsName          = $systemTopicsName
    eventGridSubscriptionName = "TagWithCreator"
}

New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
    -TemplateFile .\azuredeploy-eventSubscriptions.json `
    -TemplateParameterObject $params `
    -confirm
