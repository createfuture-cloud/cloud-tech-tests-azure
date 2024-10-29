resource "random_pet" "rg_name" {
  prefix = "rg-interview"
}

resource "random_id" "kv_name" {
  byte_length = 3
}

resource "random_password" "vm_admin" {
  length  = 16
  special = true
}

resource "azurerm_resource_group" "rg" {
  location = "uksouth"
  name     = random_pet.rg_name.id
  # Please don't remove this tag!
  tags = {
    environment = "interview"
  }
}

resource "azurerm_key_vault" "certificates" {
  name                       = "kv-certificates-${random_id.kv_name.hex}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  enable_rbac_authorization  = true

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    certificate_permissions = [
      "Create",
      "Delete",
      "DeleteIssuers",
      "Get",
      "GetIssuers",
      "Import",
      "List",
      "ListIssuers",
      "ManageContacts",
      "ManageIssuers",
      "Purge",
      "SetIssuers",
      "Update",
    ]
  }
}

resource "azurerm_role_assignment" "key_vault_officer" {
  scope                = azurerm_key_vault.certificates.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_certificate" "azure_xdesign" {
  name         = "generated-cert"
  key_vault_id = azurerm_key_vault.certificates.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }

      trigger {
        days_before_expiry = 30
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      # Server Authentication = 1.3.6.1.5.5.7.3.1
      # Client Authentication = 1.3.6.1.5.5.7.3.2
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"]

      key_usage = [
        "cRLSign",
        "dataEncipherment",
        "digitalSignature",
        "keyAgreement",
        "keyCertSign",
        "keyEncipherment",
      ]

      subject_alternative_names {
        dns_names = ["azure.createfuture.cloud"]
      }

      subject            = "CN=azure-createfuture-cloud"
      validity_in_months = 12
    }
  }
}

resource "azurerm_virtual_network" "default" {
  name                = "vnet-default"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "frontend" {
  name                 = "snet-frontend"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "backend" {
  name                 = "snet-backend"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_public_ip" "webserver" {
  name                = "pip-webserver"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "webserver" {
  count               = 2
  name                = "nic-webserver-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipc-webserver-${count.index + 1}"
    subnet_id                     = azurerm_subnet.backend.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_application_gateway_backend_address_pool_association" "webserver" {
  count                   = 2
  network_interface_id    = azurerm_network_interface.webserver[count.index].id
  backend_address_pool_id = one(azurerm_application_gateway.main.backend_address_pool).id
  ip_configuration_name   = "ipc-webserver-${count.index + 1}"
}

resource "azurerm_application_gateway" "main" {
  name                = "appgw-webserver"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "agw-webserver"
    subnet_id = azurerm_subnet.frontend.id
  }

  frontend_port {
    name = "http"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "agw-frontend"
    public_ip_address_id = azurerm_public_ip.webserver.id
  }

  backend_address_pool {
    name = "backendpool"
  }

  backend_http_settings {
    name                  = "http-setting"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "agw-frontend"
    frontend_port_name             = "http"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "http"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "backendpool"
    backend_http_settings_name = "http-setting"
    priority                   = 10
  }
}

resource "azurerm_linux_virtual_machine" "webserver" {
  count                 = 2
  name                  = "webserver${count.index + 1}"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.webserver[count.index].id]
  size                  = "Standard_B1s"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  admin_username                  = "xd123"
  admin_password                  = random_password.vm_admin.result
  disable_password_authentication = false
}

resource "azurerm_virtual_machine_extension" "apache" {
  count                = 2
  name                 = "vm-ext-apache"
  virtual_machine_id   = azurerm_linux_virtual_machine.webserver[count.index].id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = <<SETTINGS
 {
  "commandToExecute": "sudo apt-get -y install apache2"
 }
SETTINGS
}
