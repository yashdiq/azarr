terraform {
  required_providers {
    alicloud = {
      source = "aliyun/alicloud"
      version = "1.234.0"
    }
  }
}

provider "alicloud" {
  access_key = var.my_access_key
  secret_key = var.my_secret_key
  region     = var.my_region
}

data "alicloud_zones" "abc_zones" {}