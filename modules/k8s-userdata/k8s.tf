data "ignition_file" "hostname" {
  count = "${var.ignition_mode ? var.count : 0 }"
  path = "/etc/hostname"
  filesystem = "root"
  mode = 420
  content {
    content = "${var.name}-${count.index}"
  }
}

data "ignition_systemd_unit" "docker_service" {
  name = "docker.service"
  enabled = true
}

data "ignition_systemd_unit" "kubelet_service" {
  name = "kubelet.service"
  enabled = true
  content = <<CONTENT
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=http://kubernetes.io/docs/

[Service]
ExecStart=/opt/k8s/bin/kubelet --address=0.0.0.0 \
  --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf \
  --pod-manifest-path=/etc/kubernetes/manifests --allow-privileged=true \
  --network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin \
  --cluster-dns=${cidrhost(var.service_cidr, 10)} --cluster-domain=${var.datacenter}.${var.domain} \
  --authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt \
  --rotate-certificates=true
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
CONTENT
}

data "ignition_file" "kubeconfig" {
  count = "${var.ignition_mode ? var.count : 0 }"
  path = "/etc/kubernetes/kubeadm/config.yaml"
  filesystem = "root"
  content {
    content = <<CONTENT
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
etcd:
  endpoints:
  - https://127.0.0.1:2379
  caFile: /opt/etcd/certs/ca.pem
  certFile: /opt/etcd/certs/cert.pem
  keyFile: /opt/etcd/certs/cert-key.pem
kubeProxy:
  config:
    mode: iptables
networking:
  dnsDomain: ${var.datacenter}.${var.domain}
  serviceSubnet: ${var.service_cidr}
  podSubnet: ${var.pod_cidr}
kubernetesVersion: 1.9.2
nodeName: ${var.name}-${count.index}
authorizationModes:
- Node
- RBAC
selfHosted: false
apiServerCertSANs:
${join("\n", formatlist("- %s", var.ipv4_addrs))}
certificatesDir: "/etc/kubernetes/pki"
CONTENT
  }
}

data "ignition_systemd_unit" "k8s-init-service" {
  name = "k8s-init.service"
  content = <<CONTENT
[Unit]
Description=Bootstrap a Kubernetes cluster with kubeadm
Wants=etcd.service
ConditionPathExists=!/opt/k8s/init.done

[Service]
RemainAfterExit=true
Restart=on-failure
StartLimitInterval=0
RestartSec=10
Environment=MASTER_AS_WORKER=${var.master_as_worker}
ExecStartPre=/usr/bin/systemctl is-active etcd.service
ExecStart=/opt/k8s/k8s-init

[Install]
WantedBy=multi-user.target
CONTENT
}

data "ignition_file" "cni-rbac" {
  path = "/etc/kubernetes/cni/cni-rbac.yaml"
  filesystem = "root"
  content {
    content = <<CONTENT
# Calico Roles
# Pulled from https://docs.projectcalico.org/v2.5/getting-started/kubernetes/installation/hosted/rbac-kdd.yaml
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: calico
rules:
  - apiGroups: [""]
    resources:
      - namespaces
    verbs:
      - get
      - list
      - watch
  - apiGroups: [""]
    resources:
      - pods/status
    verbs:
      - update
  - apiGroups: [""]
    resources:
      - pods
    verbs:
      - get
      - list
      - watch
  - apiGroups: [""]
    resources:
      - nodes
    verbs:
      - get
      - list
      - update
      - watch
  - apiGroups: ["extensions"]
    resources:
      - networkpolicies
    verbs:
      - get
      - list
      - watch
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - globalfelixconfigs
      - bgppeers
      - globalbgpconfigs
      - ippools
      - globalnetworkpolicies
    verbs:
      - create
      - get
      - list
      - update
      - watch

---

# Flannel roles
# Pulled from https://github.com/coreos/flannel/blob/master/Documentation/kube-flannel-rbac.yml
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: flannel
rules:
  - apiGroups:
      - ""
    resources:
      - pods
    verbs:
      - get
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - nodes/status
    verbs:
      - patch
---

# Bind the flannel ClusterRole to the canal ServiceAccount.
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: canal-flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: canal
  namespace: kube-system

---

# Bind the calico ClusterRole to the canal ServiceAccount.
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: canal-calico
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: calico
subjects:
- kind: ServiceAccount
  name: canal
  namespace: kube-system
CONTENT
  }
}

data "ignition_file" "cni-manifest" {
  filesystem = "root"
  path = "/etc/kubernetes/cni/cni-manifest.yaml"
  content {
    content = <<CONTENT
# Canal Version v2.6.7
# https://docs.projectcalico.org/v2.6/releases#v2.6.7
# This manifest includes the following component versions:
#   calico/node:v2.6.7
#   calico/cni:v1.11.2
#   coreos/flannel:v0.9.1
 
# This ConfigMap can be used to configure a self-hosted Canal installation.
kind: ConfigMap
apiVersion: v1
metadata:
  name: canal-config
  namespace: kube-system
data:
  # The interface used by canal for host <-> host communication.
  # If left blank, then the interface is chosen using the node's
  # default route.
  canal_iface: ""
 
  # Whether or not to masquerade traffic to destinations not within
  # the pod network.
  masquerade: "true"
 
  # The CNI network configuration to install on each node.
  cni_network_config: |-
    {
        "name": "k8s-pod-network",
        "cniVersion": "0.3.0",
        "plugins": [
            {
                "type": "calico",
                "log_level": "info",
                "datastore_type": "kubernetes",
                "nodename": "__KUBERNETES_NODE_NAME__",
                "ipam": {
                    "type": "host-local",
                    "subnet": "usePodCidr"
                },
                "policy": {
                    "type": "k8s",
                    "k8s_auth_token": "__SERVICEACCOUNT_TOKEN__"
                },
                "kubernetes": {
                    "k8s_api_root": "https://__KUBERNETES_SERVICE_HOST__:__KUBERNETES_SERVICE_PORT__",
                    "kubeconfig": "__KUBECONFIG_FILEPATH__"
                }
            },
            {
                "type": "portmap",
                "capabilities": {"portMappings": true},
                "snat": true
            }
        ]
    }
 
  # Flannel network configuration. Mounted into the flannel container.
  net-conf.json: |
    {
      "Network": "${var.pod_cidr}",
      "Backend": {
        "Type": "vxlan"
      }
    }
 
---
 
# This manifest installs the calico/node container, as well
# as the Calico CNI plugins and network config on
# each master and worker node in a Kubernetes cluster.
kind: DaemonSet
apiVersion: extensions/v1beta1
metadata:
  name: canal
  namespace: kube-system
  labels:
    k8s-app: canal
spec:
  selector:
    matchLabels:
      k8s-app: canal
  template:
    metadata:
      labels:
        k8s-app: canal
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      hostNetwork: true
      serviceAccountName: canal
      tolerations:
        # Tolerate this effect so the pods will be schedulable at all times
        - effect: NoSchedule
          operator: Exists
        # Mark the pod as a critical add-on for rescheduling.
        - key: "CriticalAddonsOnly"
          operator: "Exists"
        - effect: NoExecute
          operator: Exists
      # Minimize downtime during a rolling upgrade or deletion; tell Kubernetes to do a "force
      # deletion": https://kubernetes.io/docs/concepts/workloads/pods/pod/#termination-of-pods.
      terminationGracePeriodSeconds: 0
      containers:
        # Runs calico/node container on each Kubernetes node.  This
        # container programs network policy and routes on each
        # host.
        - name: calico-node
          image: quay.io/calico/node:v2.6.7
          env:
            # Use Kubernetes API as the backing datastore.
            - name: DATASTORE_TYPE
              value: "kubernetes"
            # Enable felix logging.
            - name: FELIX_LOGSEVERITYSYS
              value: "info"
            # Don't enable BGP.
            - name: CALICO_NETWORKING_BACKEND
              value: "none"
            # Cluster type to identify the deployment type
            - name: CLUSTER_TYPE
              value: "k8s,canal"
            # Disable file logging so `kubectl logs` works.
            - name: CALICO_DISABLE_FILE_LOGGING
              value: "true"
            # Period, in seconds, at which felix re-applies all iptables state
            - name: FELIX_IPTABLESREFRESHINTERVAL
              value: "60"
            # Disable IPV6 support in Felix.
            - name: FELIX_IPV6SUPPORT
              value: "false"
            # Wait for the datastore.
            - name: WAIT_FOR_DATASTORE
              value: "true"
            # No IP address needed.
            - name: IP
              value: ""
            - name: NODENAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            # Set Felix endpoint to host default action to ACCEPT.
            - name: FELIX_DEFAULTENDPOINTTOHOSTACTION
              value: "ACCEPT"
            - name: FELIX_HEALTHENABLED
              value: "true"
          securityContext:
            privileged: true
          resources:
            requests:
              cpu: 250m
          livenessProbe:
            httpGet:
              path: /liveness
              port: 9099
            periodSeconds: 10
            initialDelaySeconds: 10
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /readiness
              port: 9099
            periodSeconds: 10
          volumeMounts:
            - mountPath: /lib/modules
              name: lib-modules
              readOnly: true
            - mountPath: /var/run/calico
              name: var-run-calico
              readOnly: false
        # This container installs the Calico CNI binaries
        # and CNI network config file on each node.
        - name: install-cni
          image: quay.io/calico/cni:v1.11.2
          command: ["/install-cni.sh"]
          env:
            - name: CNI_CONF_NAME
              value: "10-calico.conflist"
            # The CNI network config to install on each node.
            - name: CNI_NETWORK_CONFIG
              valueFrom:
                configMapKeyRef:
                  name: canal-config
                  key: cni_network_config
            - name: KUBERNETES_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - mountPath: /host/opt/cni/bin
              name: cni-bin-dir
            - mountPath: /host/etc/cni/net.d
              name: cni-net-dir
        # This container runs flannel using the kube-subnet-mgr backend
        # for allocating subnets.
        - name: kube-flannel
          image: quay.io/coreos/flannel:v0.9.1
          command: [ "/opt/bin/flanneld", "--ip-masq", "--kube-subnet-mgr" ]
          securityContext:
            privileged: true
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: FLANNELD_IFACE
              valueFrom:
                configMapKeyRef:
                  name: canal-config
                  key: canal_iface
            - name: FLANNELD_IP_MASQ
              valueFrom:
                configMapKeyRef:
                  name: canal-config
                  key: masquerade
          volumeMounts:
          - name: run
            mountPath: /run
          - name: flannel-cfg
            mountPath: /etc/kube-flannel/
      volumes:
        # Used by calico/node.
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: var-run-calico
          hostPath:
            path: /var/run/calico
        # Used to install CNI.
        - name: cni-bin-dir
          hostPath:
            path: /opt/cni/bin
        - name: cni-net-dir
          hostPath:
            path: /etc/cni/net.d
        # Used by flannel.
        - name: run
          hostPath:
            path: /run
        - name: flannel-cfg
          configMap:
            name: canal-config
 
 
# Create all the CustomResourceDefinitions needed for
# Calico policy-only mode.
---
 
apiVersion: apiextensions.k8s.io/v1beta1
description: Calico Global Felix Configuration
kind: CustomResourceDefinition
metadata:
   name: globalfelixconfigs.crd.projectcalico.org
spec:
  scope: Cluster
  group: crd.projectcalico.org
  version: v1
  names:
    kind: GlobalFelixConfig
    plural: globalfelixconfigs
    singular: globalfelixconfig
 
---
 
apiVersion: apiextensions.k8s.io/v1beta1
description: Calico Global BGP Configuration
kind: CustomResourceDefinition
metadata:
  name: globalbgpconfigs.crd.projectcalico.org
spec:
  scope: Cluster
  group: crd.projectcalico.org
  version: v1
  names:
    kind: GlobalBGPConfig
    plural: globalbgpconfigs
    singular: globalbgpconfig
 
---
 
apiVersion: apiextensions.k8s.io/v1beta1
description: Calico IP Pools
kind: CustomResourceDefinition
metadata:
  name: ippools.crd.projectcalico.org
spec:
  scope: Cluster
  group: crd.projectcalico.org
  version: v1
  names:
    kind: IPPool
    plural: ippools
    singular: ippool
 
---
 
apiVersion: apiextensions.k8s.io/v1beta1
description: Calico Global Network Policies
kind: CustomResourceDefinition
metadata:
  name: globalnetworkpolicies.crd.projectcalico.org
spec:
  scope: Cluster
  group: crd.projectcalico.org
  version: v1
  names:
    kind: GlobalNetworkPolicy
    plural: globalnetworkpolicies
    singular: globalnetworkpolicy
 
---
 
apiVersion: v1
kind: ServiceAccount
metadata:
  name: canal
  namespace: kube-system
CONTENT
  }
}

data "ignition_file" "kubeadm-init" {
  filesystem = "root"
  path = "/opt/kubeadm/kubeadm-init"
  mode = "0755"
  content {
    content = <<CONTENT
#!/bin/bash -e

# Prepare etcdctl command
export ETCDCTL_API=3
ETCDCTL_COMMAND="/opt/etcd/bin/etcdctl --cacert /opt/etcd/certs/ca.pem --cert /opt/etcd/certs/cert.pem --key /opt/etcd/certs/cert-key.pem --endpoints https://localhost:2379 "

# Expose k8s tools path for kubeadm
PATH=$PATH:/opt/k8s/bin

# Try to get PKI from etcd, if already generated by a previous run of kubeadm
pki=$($ETCDCTL_COMMAND get --print-value-only k8s-pki)
if [[ -z "$pki" ]];
then
  echo "First master, generating PKI"
  /opt/k8s/bin/kubeadm init --config=/etc/kubernetes/kubeadm/config.yaml
  if [[ "$?" -ne "0" ]]
  then
    echo "Failed to initialize with kubeadm..."
    exit 1
  fi

  (cd /etc/kubernetes && $ETCDCTL_COMMAND put k8s-pki "$(tar -cf - ./pki | base64)")
else
  echo "PKI already in etcd"
  (cd /etc/kubernetes && echo -e "$pki" | base64 -d | tar -xf -)
  /opt/k8s/bin/kubeadm init --config=/etc/kubernetes/kubeadm/config.yaml
fi
CONTENT
  }
}


data "ignition_file" "k8s-init" {
  filesystem = "root"
  path = "/opt/k8s/k8s-init"
  mode = "0755"
  content {
    content = <<CONTENT
#!/bin/bash -e

# Do not run if init has already been done
if [ -f /opt/kubeadm/init.done ]; then
   echo "init already done." >&1
   exit 0
fi

# Prepare etcdctl command
export ETCDCTL_API=3
ETCDCTL_COMMAND="/opt/etcd/bin/etcdctl --cacert /opt/etcd/certs/ca.pem --cert /opt/etcd/certs/cert.pem --key /opt/etcd/certs/cert-key.pem --endpoints https://localhost:2379 "

# Acquire lock on kubeadm-init script
$ETCDCTL_COMMAND lock k8s-lock /bin/bash /opt/kubeadm/kubeadm-init

# Untaint node if needed
if [ "$$MASTER_AS_WORKER" == 1 ]; then
   /opt/k8s/bin/kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/master-
fi

# Apply CNI manifests
/opt/k8s/bin/kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /etc/kubernetes/cni/cni-rbac.yaml
/opt/k8s/bin/kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /etc/kubernetes/cni/cni-manifest.yaml

touch /opt/k8s/init.done

CONTENT
  }
}
