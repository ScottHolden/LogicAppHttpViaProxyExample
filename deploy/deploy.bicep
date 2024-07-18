@description('Location for main resources.')
param location string = resourceGroup().location

@description('A prefix to add to the start of all resource names. Note: A "unique" suffix will also be added')
@minLength(3)
@maxLength(10)
param prefix string = 'proxy'

@description('Tags to apply to all deployed resources')
param tags object = {}

param sshAllowedSourceIp string
param proxyVmUsername string = 'proxydebug'
param proxyVmPublicKey string
param logicAppArtifact string = 'https://raw.githubusercontent.com/ScottHolden/LogicAppHttpViaProxyExample/main/artifacts/proxy-logicapp.zip'

var vnetAddressPrefix = '10.180.0.0/16'
var logicAppSubnetName = 'LogicApp'
var logicAppSubnetAddressPrefix = '10.180.10.0/24'
var proxySubnetName = 'Proxy'
var proxySubnetAddressPrefix = '10.180.11.0/24'
var proxyStaticIp = cidrHost(proxySubnetAddressPrefix, 10)

var logicAppProxyUser = 'logicappuser'
var logicAppProxyPass = 'TmvdUSs1_xAm4zO1QN4aa'
var proxySetupScript = format(
  '''
sudo apt -y update
sudo apt -y install squid apache2-utils

sudo htpasswd -bc /etc/squid/passwords {0} {1}

cat > /etc/squid/squid.conf <<EOF
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm proxy

acl localnet src {2}
acl remote_test src {3}
acl auth_users proxy_auth REQUIRED

http_access allow localnet auth_users
http_access allow remote_test auth_users
http_access allow localhost
http_access deny all

include /etc/squid/conf.d/*.conf

http_port 3128
coredump_dir /var/spool/squid
EOF

sudo systemctl restart squid
''',
  logicAppProxyUser,
  logicAppProxyPass,
  vnetAddressPrefix,
  sshAllowedSourceIp
)

var usablePrefix = toLower(trim(prefix))
var uniqueSuffix = uniqueString(resourceGroup().id, prefix)
var uniqueNameFormat = '${usablePrefix}-{0}-${uniqueSuffix}'
var uniqueShortNameFormat = '${usablePrefix}{0}${uniqueSuffix}'

resource proxyNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: format(uniqueNameFormat, 'proxy-nsg')
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-ExternalProxy-SSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sshAllowedSourceIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-ExternalProxy-Proxy'
        properties: {
          priority: 300
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sshAllowedSourceIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3128'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: format(uniqueNameFormat, 'vnet')
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: logicAppSubnetName
        properties: {
          addressPrefix: logicAppSubnetAddressPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverfarms'
              }
            }
          ]
        }
      }
      {
        name: proxySubnetName
        properties: {
          addressPrefix: proxySubnetAddressPrefix
          networkSecurityGroup: {
            id: proxyNsg.id
          }
        }
      }
    ]
  }
  resource logicAppSubnet 'subnets' existing = {
    name: logicAppSubnetName
  }
  resource proxySubnet 'subnets' existing = {
    name: proxySubnetName
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: format(uniqueNameFormat, 'logs')
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: format(uniqueNameFormat, 'insights')
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  #disable-next-line BCP334
  name: take(format(uniqueShortNameFormat, 'st'), 24)
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    defaultToOAuthAuthentication: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }

  resource blobs 'blobServices' existing = {
    name: 'default'
    resource functionAppContainer 'containers' = {
      name: 'app-package-${format(uniqueNameFormat, 'func')}'
    }
  }
}

resource logicAppPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: format(uniqueNameFormat, 'logicapp')
  location: location
  tags: tags
  sku: {
    tier: 'WorkflowStandard'
    name: 'WS1'
  }
  properties: {
    maximumElasticWorkerCount: 3
    zoneRedundant: false
  }
}

resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: format(uniqueNameFormat, 'logicapp')
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: logicAppPlan.id
    virtualNetworkSubnetId: vnet::logicAppSubnet.id
    vnetRouteAllEnabled: true
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      use32BitWorkerProcess: false
      ftpsState: 'FtpsOnly'
      netFrameworkVersion: 'v6.0'
      appSettings: [
        { name: 'APP_KIND', value: 'workflowApp' }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '[1.*, 2.0.0)' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION', value: '~18' }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        { name: 'WEBSITE_CONTENTSHARE', value: format(uniqueShortNameFormat, 'logicapp') }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }

        { name: 'DEMO_PROXY_USER', value: logicAppProxyUser }
        { name: 'DEMO_PROXY_PASS', value: logicAppProxyPass }
        { name: 'DEMO_PROXY_URL', value: 'http://${proxyStaticIp}:3128' }
      ]
    }
  }
  resource disableBasicScm 'basicPublishingCredentialsPolicies' = {
    name: 'scm'
    properties: {
      allow: false
    }
  }
  resource disableBasicFtp 'basicPublishingCredentialsPolicies' = {
    name: 'ftp'
    properties: {
      allow: false
    }
  }
  resource MSDeploy 'extensions@2021-02-01' = if (!empty(trim(logicAppArtifact))) {
    name: 'MSDeploy'
    properties: {
      packageUri: logicAppArtifact
    }
  }
}

resource proxyPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: format(uniqueNameFormat, 'pip')
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource proxyNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: format(uniqueNameFormat, 'nic')
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet::proxySubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: proxyStaticIp
          publicIPAddress: {
            id: proxyPip.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: proxyNsg.id
    }
  }
}

resource proxyVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: format(uniqueNameFormat, 'vm')
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v3'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }
    osProfile: {
      computerName: proxyVmUsername
      adminUsername: proxyVmUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${proxyVmUsername}/.ssh/authorized_keys'
              keyData: proxyVmPublicKey
            }
          ]
        }
      }
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      securityType: 'TrustedLaunch'
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: proxyNic.id
        }
      ]
    }
  }
  resource customScript 'extensions' = {
    name: 'CustomScript'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Extensions'
      type: 'CustomScript'
      typeHandlerVersion: '2.1'
      autoUpgradeMinorVersion: true
      settings: {
        script: base64(proxySetupScript)
      }
    }
  }
}
