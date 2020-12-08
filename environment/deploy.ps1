## Variable
$env = "mvp"
$AzureRmSubscriptionName = "sub-$env-001"           # <-- REPLACE the variable values with your own values.
$resourceGroupName = "rg-in-$env-monitor-001"         # <-- 
$azFunctionName = "func-in-$env-monitor-001"          # <-- The Azure App Function Name
$appServicePlanName = "plan-in-$env-monitor-001"      # <--
$storageAccountName = "stin$($env)funcmonitor001"         # <-- Ensure the storage account name is unique
$appInsightsName = "appi-in-$env-monitor-001"         # <--
$systemTopicsName = "evgst-in-$env-monitor-001"       # <--
$location = "francecentral"                           # <-- Ensure that the location is a valid Azure location
$functionName = "TagWithCreator"                      # <-- The Function Name that will tag
$params = @{
    storageAccountName = $storageAccountName.ToLower()
    appServicePlanName = $appServicePlanName
    appInsightsName    = $appInsightsName
    functionName       = $azFunctionName
}

## Connectivity
# Login first with Connect-AzAccount if not using Cloud Shell
$AzureRmContext = Get-AzSubscription -SubscriptionName $AzureRmSubscriptionName | Set-AzContext -ErrorAction Stop
$Subscription = Select-AzSubscription -Name $AzureRmSubscriptionName -Context $AzureRmContext -Force -ErrorAction Stop

# Creating the Resource Group if needed 
Get-AzResourceGroup -Name $resourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
if ($notPresent) {
    New-AzResourceGroup -Name $resourceGroupName -Location $location -Force -Tag @{ creator = $AzureRmContext.Account.Id }
}

## Deploy the function App
$output = New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
    -TemplateFile .\azuredeploy-function.json `
    -TemplateParameterObject $params `
    -confirm

## Storage Account Firewall Rules, Ref. https://docs.microsoft.com/en-us/azure/azure-functions/ip-addresses
### WARNING THIS IS NOT SUPPORTED YET --> https://github.com/Azure/Azure-Functions/issues/1349
<#
$IpRules = $($($output.Outputs.possibleOutboundIpAddresses.Value) + "," + $($output.Outputs.outboundIpAddresses.Value)).Split(",") | Select-Object -Unique
$PsIpRule = @(
    $IpRules | ForEach-Object { @{IPAddressOrRange = $_; Action = "allow" } }
)
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $resourceGroupName -AccountName $storageAccountName -IpRule $PsIpRule -DefaultAction Deny -Bypass Azureservices -ErrorAction Stop
#>

## Assign privileges
New-AzRoleAssignment -RoleDefinitionName "Reader" -ObjectId $output.Outputs.managedIdentityId.Value -ErrorAction SilentlyContinue -Verbose
New-AzRoleAssignment -RoleDefinitionName "Tag Contributor" -ObjectId $output.Outputs.managedIdentityId.Value -ErrorAction SilentlyContinue -Verbose

## Zip Deploy the function App
Push-Location
Set-Location ..\functions
Compress-Archive -Path * -DestinationPath ..\environment\functions.zip -Force -Verbose
Pop-Location

$file = (Get-ChildItem .\functions.zip).FullName
Publish-AzWebApp -ResourceGroupName $resourceGroupName -Name $azFunctionName -ArchivePath $file -Verbose -Force
Remove-Item $file -Force

# Deploy the EventGrid system Topic, feature request to use : resourceUrisToExclude --> https://feedback.azure.com/forums/909934-azure-event-grid/suggestions/42036640-support-stringnotcontains-advanced-filters-on-even?WT.mc_id=AZ-MVP-5003548
$params = @{
    resourceId                = $output.Outputs.resourceId.Value 
    systemTopicsName          = $systemTopicsName
    eventGridSubscriptionName = $functionName
}

New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
    -TemplateFile .\azuredeploy-eventSubscriptions.json `
    -TemplateParameterObject $params `
    -confirm

## Deploy the Azure Monitor Workbook
$workbookDisplayName = "Compliance - Tag Workbook - $env"
$workbookSourceId = "azure monitor"
$workbookType = "workbook"
#$workbookId = "Existong-Workbok-GUID-To-Use-If-UpdateInplace"
$workbookSerializedData = (Get-Content -Path ".\azuredeploy-workbook-gallery.json") `
    -replace "<AppInsightId>", $output.Outputs.appInsightsId.Value `
    -replace "<SubscriptionId>", $Subscription.Subscription.Id `
    -replace "<FunctionName>", $functionName `
| ConvertFrom-Json

New-AzResourceGroupDeployment -Name $(("$workbookType-$workbookDisplayName").replace(' ', '')) -ResourceGroupName $resourceGroupName `
    -TemplateFile .\azuredeploy-workbook.json `
    -workbookDisplayName $workbookDisplayName `
    -workbookType $workbookType `
    -workbookSourceId $workbookSourceId `
    -workbookSerializedData ($workbookSerializedData | ConvertTo-Json -Depth 20) `
    -Confirm -ErrorAction Stop