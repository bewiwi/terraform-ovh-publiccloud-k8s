output "rendered" {
  description = "The representation of the userdata according to `var.ignition_mode`"
  value = ["${coalescelist(data.ignition_config.coreos.*.rendered, data.template_cloudinit_config.config.*.rendered)}"]
}

output "etcd_initial_cluster" {
  description = "The etcd initial cluster that can be used to join the cluster"
  value = "${module.etcd.etcd_initial_cluster}"
}

output "cfssl_endpoint" {
  description = "The cfssl endpoint"
  value = "${module.cfssl.endpoint}"
}
