"""
Azure Automation documentation : https://aka.ms/azure-automation-python-documentation
Azure Python SDK documentation : https://aka.ms/azure-python-sdk
"""
# AZURE
from azure.storage.common import CloudStorageAccount
from azure.storage.blob import BlockBlobService, PublicAccess
from azure.storage.file import FileService, ContentSettings
import automationassets
from azure.graphrbac import GraphRbacManagementClient
from azure.common.credentials import ServicePrincipalCredentials
from azure.graphrbac.models import GroupCreateParameters, GroupAddMemberParameters, CheckGroupMembershipParameters
from msrestazure.azure_active_directory import AdalAuthentication
import adal
from msrestazure.azure_cloud import AZURE_PUBLIC_CLOUD

# OCI
import oci
from oci.config import validate_config, from_file
from oci.identity import IdentityClient

# GENERAL
import logging,datetime,io,os,random,uuid,sys,requests,json

# Functions
def getCompartmentRecurse(client,compartmentId):
    logging.debug("getCompartmentRecurse: current id %s" % compartmentId)
    comps = {}
    for compartment in (client.list_compartments(compartmentId).data):
        logging.debug("getCompartmentRecurse: loop id %s" % compartment.id)
        if compartment.id != compartmentId:
            comps.update({compartment.name.lower() : compartment})
            comps.update(getCompartmentRecurse(client,compartment.id))
    return comps

def sendMail(to,sbjct,msg=" "):
    bdy = """
    {
        "TO":"%s",
        "Subject":"%s",
        "Body":"%s"
    }""" % to,sbjct,msg
    requests.post(automationassets.get_automation_variable('EmailRestEndpoint'), data=bdy)

# Main
logging.basicConfig(format='%(asctime)s %(name)-20s %(levelname)-5s %(message)s', level=logging.INFO)

logging.info(sys.version)
logging.info("%s - Starting" % datetime.datetime.now())
logging.info("INPUT: %s" %sys.argv)

#try:
prsArg = json.loads(json.loads(sys.argv[1])['RequestBody'])
print(prsArg)
newCompartmentName = prsArg['subname']
newCompartmentOwner = prsArg['owner']
newCompartmentBudget = float(prsArg['monthlybudget'])

storage_account = automationassets.get_automation_variable('oci_storage_account')
storage_share = automationassets.get_automation_variable('oci_storage_share_name')

AZTenantId = "78820852-55fa-450b-908d-45c0d911e76b"

logging.info("Getting OCI config files from file share - account: %s " % storage_account)
file_service = FileService(account_name=storage_account,
                            account_key=automationassets.get_automation_variable('oci_storage_account_key'))

# Create target Directory if don't exist
if not os.path.exists('.oci'):
    os.mkdir('.oci')
    logging.info("Created the .oci directory")

logging.info("Downloading config files to .oci")
file_service.get_file_to_path(storage_share, '.oci', 'config', '.oci/config')
file_service.get_file_to_path(storage_share, '.oci', 'oci_api_key.pem', '.oci/oci_api_key.pem')
file_service.get_file_to_path(storage_share, '.oci', 'oci_api_key_public.pem', '.oci/oci_api_key_public.pem')

if not os.path.exists('.oci/config'):
    logging.error("File .oci/config missing!")
    exit(1)

if not os.path.exists('.oci/oci_api_key.pem'):
    logging.error("File .oci/oci_api_key.pem missing!")
    exit(1)

if not os.path.exists('.oci/oci_api_key_public.pem'):
    logging.error("File .oci/oci_api_key_public.pem missing!")
    exit(1)

logging.info("Loading configuration from .oci")
config = from_file(file_location=".oci/config")
logging.info("Validating configuration from .oci")
validate_config(config)

identity = IdentityClient(config)
tenant_compartment_id = config["tenancy"]

logging.info("Retrieving all compartments")
compartments = getCompartmentRecurse(identity,tenant_compartment_id)
logging.debug(compartments)

if compartments.get(newCompartmentName) is not None:
    logging.error("Compartment already exists!")
    sendMail(newCompartmentOwner,"Subscription already exists","Subscription %s already exists!" % newCompartmentName)
    exit(2)

newCompartmentNameParts = newCompartmentName.split('-')
newCompartmentParent = compartments[newCompartmentNameParts[1].lower()]

logging.info("Creating compartment under parent '%s'" % newCompartmentParent.name)
newCompartment = identity.create_compartment(oci.identity.models.CreateCompartmentDetails(compartment_id=newCompartmentParent.id,name=newCompartmentName,description=newCompartmentName)).data
logging.info("New compartment: %s" % newCompartment)

logging.info("Creating compartment Admins group")
newCompartmentGroup = identity.create_group(oci.identity.models.CreateGroupDetails(compartment_id=tenant_compartment_id,name=newCompartmentName + "-Admins",description=newCompartmentName + "-Admins")).data

context = adal.AuthenticationContext(AZURE_PUBLIC_CLOUD.endpoints.active_directory + '/' + AZTenantId)
credentials = AdalAuthentication(
    context.acquire_token_with_client_credentials,
    "https://graph.windows.net",
    automationassets.get_automation_variable('AzutomationAccountSPId'),
    automationassets.get_automation_variable('AutomationAccountSP_Key')
)
graphrbac_client = GraphRbacManagementClient(credentials,AZTenantId)
AZgrp_name = "cloud-"+newCompartmentName+"-Admins"
AZgrp = next(graphrbac_client.groups.list(filter="startswith(displayName,'"+ AZgrp_name +"')"),None)

if AZgrp is None:
    graphrbac_client.groups.create(GroupCreateParameters(display_name=AZgrp_name, mail_nickname=AZgrp_name))
    logging.info("Creating azure AD group for admins")
else:
    logging.warning("Azure AD group for admins already exists")

AZgrp = graphrbac_client.groups.list(filter="startswith(displayName,'"+ AZgrp_name +"')").next()

logging.info("Adding %s to new group for admins" % newCompartmentOwner)
AZOwner = graphrbac_client.users.get(upn_or_object_id=newCompartmentOwner)
if graphrbac_client.groups.is_member_of(CheckGroupMembershipParameters(group_id=AZgrp.id,member_id=AZOwner.id)):
    logging.warning("%s already in the Azure admins group" % newCompartmentOwner)
else:
    graphrbac_client.groups.add_member(group_object_id=AZgrp.id,url="https://graph.windows.net/" + AZTenantId + "/directoryObjects/" + AZOwner.id)

logging.info("Getting SAML2 Identity Provider")
identity_provider_id = identity.list_identity_providers(protocol="SAML2",compartment_id=tenant_compartment_id).data[0]
logging.info("SAML2 Identity Provider: %s" % identity_provider_id)

logging.info("Creating Identity Mapping for new groups in both clouds - provider id is %s" % identity_provider_id.id)
identity.create_idp_group_mapping(oci.identity.models.CreateIdpGroupMappingDetails(group_id=newCompartmentGroup.id,idp_group_name=AZgrp.object_id),identity_provider_id=identity_provider_id.id)

logging.info("Creating Policy for new compartment with admin permissions for Admins group")
identity.create_policy(oci.identity.models.CreatePolicyDetails(compartment_id=newCompartment.id,description=newCompartmentName + "-Policy",name=newCompartmentName + "-Policy",statements=[("ALLOW GROUP {}-Admins to manage all-resources IN compartment {}".format(newCompartmentName,newCompartmentName))]))

logging.info("Setting monthly budget %s for new compartment" % newCompartmentBudget)
budgetClient = oci.budget.BudgetClient(config)
print(newCompartment.id)
budgetClient.create_budget(oci.budget.models.CreateBudgetDetails(amount=newCompartmentBudget,target_type='COMPARTMENT',reset_period='MONTHLY',display_name=newCompartmentName + "-Budget",compartment_id=tenant_compartment_id,target_compartment_id=newCompartment.id))

sendMail(newCompartmentOwner,"Compartment created Successfully","Compartment {} was created with a budget of {}. https://console.us-ashburn-1.oraclecloud.com".format(newCompartmentName,newCompartmentBudget))

exit(0)
#except Exception as e:
#    print(e)
#    logging.error(e)
    #sendMail(newCompartmentOwner,"Error while creating Compartment","blabla")