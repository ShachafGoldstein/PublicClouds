## Snippets
* **General**
  * Comp hierarchy creation from mgs in AAD - (convention specific)
    ```
    $oraclecomps = (oci iam compartment list --all --compartment-id  "TENANT_OCID" | convertfrom-json).data
    $mgs = ($mgs.Children | %{Get-AzManagementGroup -Recurse -Expand -GroupName $_.name})
    $mgs.children | % {$aaa = $_; oci iam compartment create --name $aaa.name.split('-')[1] --description "$($aaa.displayname.split('-')[0])-$($aaa.name.split('-')[1])" -c (($oraclecomps | ? {$_.name -eq $aaa.displayname.split('-')[0]}).id)}
    ```

## Runbooks
* **OCI-Comp-Create.py**
  * Runbook to create OCI compartments with an owner group with idp mapping and a budget via webhook
  * **Variables**
    * oci_storage_account - The storage account where the .oci folder sits
    * oci_storage_share_name - The storage account file share where the .oci folder sits
    * oci_storage_account_key - The storage account key
    * EmailRestEndpoint - Email REST url to send email through
  
