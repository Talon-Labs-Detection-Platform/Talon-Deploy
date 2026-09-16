terraform {
  required_version = ">= 1.6"

  required_providers {
    http = {
      source = "hashicorp/http"
      # Reads the published cloud-config. 3.x is where response_body replaced
      # the deprecated body attribute this stack reads.
      version = "~> 3.4"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
  }
}

provider "azurerm" {
  features {}
}
