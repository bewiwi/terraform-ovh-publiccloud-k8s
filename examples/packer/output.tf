
output "helper" {
  description = "This output is a human friendly helper on how to interact with the k8s cluster"
  value = <<HELP
Your kubernetes cluster is up.

You can connect in one of the instances:

    $ ssh core@${openstack_compute_instance_v2.singlenet_k8s.access_ip_v4}

Enjoy!
HELP
}
