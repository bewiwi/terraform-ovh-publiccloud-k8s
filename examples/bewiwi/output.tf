locals {
  etcd_test_command = "/opt/etcd/bin/etcdctl --ca-file /opt/etcd/certs/ca.pem --cert-file /opt/etcd/certs/cert.pem --key-file /opt/etcd/certs/cert-key.pem --endpoints https://${module.k8s.public_ipv4_addrs[0]}:2379 member list"
  k8s_test_command = "sudo /opt/k8s/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes"
}

output "tf_test_etcd" {
  description = "This output can be used to check if the cluster is up & running by typing `terraform output tf_test | sh`"
  value = <<TEST
ssh -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    core@${module.k8s.public_ipv4_addrs[0]} sh -c '"[ \$(${local.etcd_test_command} | wc -l) == ${var.count} ] && ${local.etcd_test_command} | grep -q isLeader=true"'
TEST
}

output "tf_test" {
  description = "This output can be used to check if the cluster is up & running by typing `terraform output tf_test | sh`"
  value = <<TEST
ssh -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    core@${module.k8s.public_ipv4_addrs[0]} sh -c '"[ \$(${local.k8s_test_command} | grep master | grep -iw ready| wc -l) == ${var.count} ]"'
TEST
}

output "helper" {
  description = "This output is a human friendly helper on how to interact with the k8s cluster"
  value = <<HELP
Your kubernetes cluster is up.

You can connect in one of the instances:

    $ ssh core@${module.k8s.public_ipv4_addrs[0]}

Check your etcd cluster:

    $ ${local.etcd_test_command}

Check your k8s cluster:

    $ ${local.k8s_test_command}

Run a pod:

    $ ...

Enjoy!
HELP
}
