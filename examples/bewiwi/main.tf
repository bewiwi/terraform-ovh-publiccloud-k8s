provider "openstack" {
  version   = "~> 1.2.0"
  region    = "${var.os_region_name}"
  tenant_id = "${var.os_tenant_id}"
  auth_url  = "${var.os_auth_url}"
}

data "http" "myip" {
  url = "https://api.ipify.org/"
}

resource "openstack_networking_secgroup_v2" "sg" {
  name        = "${var.name}_ssh_sg"
  description = "${var.name} security group for k8s provisionning"
}
//
//resource "openstack_networking_secgroup_rule_v2" "in_traffic_ssh" {
//  direction         = "ingress"
//  ethertype         = "IPv4"
//  protocol          = "tcp"
//  remote_ip_prefix  = "${data.http.myip.body}/32"
//  port_range_min    = 22
//  port_range_max    = 22
//  security_group_id = "${openstack_networking_secgroup_v2.sg.id}"
//}
//
//resource "openstack_networking_secgroup_rule_v2" "in_k8s_api" {
//  direction         = "ingress"
//  ethertype         = "IPv4"
//  protocol          = "tcp"
//  remote_ip_prefix  = "${data.http.myip.body}/32"
//  port_range_min    = 6443
//  port_range_max    = 6443
//  security_group_id = "${openstack_networking_secgroup_v2.sg.id}"
//}

resource "openstack_networking_secgroup_rule_v2" "in_k8s_all_ports" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  remote_ip_prefix  = "${data.http.myip.body}/32"
  port_range_min    = 1
  port_range_max    = 65535
  security_group_id = "${openstack_networking_secgroup_v2.sg.id}"
}

module "k8s" {
  source                    = "../.."
  region                    = "${var.os_region_name}"
  name                      = "${var.name}"
  count                     = "${var.count}"
  master_mode               = true
  cfssl                     = true
  etcd                      = true
  post_install_modules      = true
  //image_name                = "k8s-packer"
  flavor_name               = "${var.os_flavor_name}"
  ignition_mode             = true
  public_security_group_ids = ["${openstack_networking_secgroup_v2.sg.id}"]
  ssh_user                  = "core"
  ssh_authorized_keys       = ["${file("${var.public_sshkey}")}"]
  ssh_private_key           = "${file("${var.private_sshkey}")}"
  associate_public_ipv4     = true
  associate_private_ipv4    = false
  master_as_worker          = true
}
