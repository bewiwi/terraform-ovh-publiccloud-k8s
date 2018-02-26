provider "openstack" {
  version   = "~> 1.2.0"
  region    = "${var.os_region_name}"
  tenant_id = "${var.os_tenant_id}"
  auth_url  = "${var.os_auth_url}"
}

# Terraform version
terraform {
  required_version = ">= 0.10.4"
}

resource "openstack_compute_keypair_v2" "ovh_kubernetes" {
  name = "ovh_package"
  public_key = "${file("${var.public_sshkey}")}"
}
resource "openstack_compute_instance_v2" "singlenet_k8s" {
  count    = 1
  name     = "packageme"
  image_name = "CoreOS Stable"
  key_pair = "${openstack_compute_keypair_v2.ovh_kubernetes.name}"
  flavor_name = "s1-2"

  network {
    name = "Ext-Net"
  }
}



module "post_install_cfssl" {
  source  = "ovh/publiccloud-cfssl/ovh//modules/install-cfssl"
  version = ">= 0.1.2"
  count                   = 1
  triggers                = "${openstack_compute_instance_v2.singlenet_k8s.*.id}"
  ipv4_addrs              = "${openstack_compute_instance_v2.singlenet_k8s.*.access_ip_v4}"
  ssh_user                = "core"
  ssh_private_key         = "${file("${var.ssh_private_key}")}"
}

module "post_install_etcd" {
  source  = "ovh/publiccloud-etcd/ovh//modules/install-etcd"
  version = ">= 0.1.0"

  count                   = 1
  triggers                = "${openstack_compute_instance_v2.singlenet_k8s.*.id}"
  ipv4_addrs              = "${openstack_compute_instance_v2.singlenet_k8s.*.access_ip_v4}"
  ssh_user                = "core"
  ssh_private_key         = "${file("${var.ssh_private_key}")}"
}

module "post_install_k8s" {
  source                  = "../../modules/install-k8s"
  count                   = 1
  triggers                = "${openstack_compute_instance_v2.singlenet_k8s.*.id}"
  ipv4_addrs              = "${openstack_compute_instance_v2.singlenet_k8s.*.access_ip_v4}"
  ssh_user                = "core"
  ssh_private_key         = "${file("${var.ssh_private_key}")}"
}

resource "null_resource" "post_backup" {

  connection {
    host                = "${openstack_compute_instance_v2.singlenet_k8s.0.access_ip_v4}"
    user                = "core"
    private_key         = "${file("${var.ssh_private_key}")}"
  }


  provisioner "remote-exec" {
    inline = <<EOF
sudo rm -fr /etc/machine-id /etc/hostname
EOF
  }
}