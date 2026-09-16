terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

# Both providers read the admin kubeconfig AKS emits, rather than a file on
# disk: a fresh checkout then works with only `az login`, and no cluster
# credential is written anywhere this stack does not control.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.this.kube_admin_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_admin_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_admin_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_admin_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.this.kube_admin_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_admin_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_admin_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_admin_config[0].cluster_ca_certificate)
  }
}
