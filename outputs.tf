output "gateway_frontend_ip" {
  value = "http://${azurerm_public_ip.webserver.ip_address}"
}