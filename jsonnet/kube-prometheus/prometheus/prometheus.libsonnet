local relabelings = import 'kube-prometheus/dropping-deprecated-metrics-relabelings.libsonnet';

{
  _config+:: {
    namespace: 'default',

    versions+:: { prometheus: 'v2.22.1' },
    imageRepos+:: { prometheus: 'quay.io/prometheus/prometheus' },
    alertmanager+:: { name: 'main' },

    prometheus+:: {
      name: 'k8s',
      replicas: 2,
      rules: {},
      namespaces: ['default', 'kube-system', $._config.namespace],
      labels: {
        'app.kubernetes.io/name': 'prometheus',
        'app.kubernetes.io/version': $._config.versions.prometheus,
        'app.kubernetes.io/component': 'prometheus',
        'app.kubernetes.io/part-of': 'kube-prometheus',
      },
      selectorLabels: {
        [labelName]: $._config.prometheus.labels[labelName]
        for labelName in std.objectFields($._config.prometheus.labels)
        if !std.setMember(labelName, ['app.kubernetes.io/version'])
      },
    },
  },

  prometheus+:: {
    local p = self,

    name:: $._config.prometheus.name,
    namespace:: $._config.namespace,
    roleBindingNamespaces:: $._config.prometheus.namespaces,
    replicas:: $._config.prometheus.replicas,
    prometheusRules:: $._config.prometheus.rules,
    alertmanagerName:: $.alertmanager.service.metadata.name,

    serviceAccount: {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: {
        name: 'prometheus-' + p.name,
        namespace: p.namespace,
        labels: $._config.prometheus.labels,
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: 'prometheus-' + p.name,
        namespace: p.namespace,
        labels: { prometheus: p.name } + $._config.prometheus.labels,
      },
      spec: {
        ports: [
          { name: 'web', targetPort: 'web', port: 9090 },
        ],
        selector: { app: 'prometheus', prometheus: p.name } + $._config.prometheus.selectorLabels,
        sessionAffinity: 'ClientIP',
      },
    },

    rules: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PrometheusRule',
      metadata: {
        labels: {
          prometheus: p.name,
          role: 'alert-rules',
        } + $._config.prometheus.labels,
        name: 'prometheus-' + p.name + '-rules',
        namespace: p.namespace,
      },
      spec: {
        groups: p.prometheusRules.groups,
      },
    },

    roleBindingSpecificNamespaces:
      local newSpecificRoleBinding(namespace) = {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: 'RoleBinding',
        metadata: {
          name: 'prometheus-' + p.name,
          namespace: namespace,
          labels: $._config.prometheus.labels,
        },
        roleRef: {
          apiGroup: 'rbac.authorization.k8s.io',
          kind: 'Role',
          name: 'prometheus-' + p.name,
        },
        subjects: [{
          kind: 'ServiceAccount',
          name: 'prometheus-' + p.name,
          namespace: p.namespace,
        }],
      };
      {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: 'RoleBindingList',
        items: [newSpecificRoleBinding(x) for x in p.roleBindingNamespaces],
      },

    clusterRole: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: {
        name: 'prometheus-' + p.name,
        labels: $._config.prometheus.labels,
      },
      rules: [
        {
          apiGroups: [''],
          resources: ['nodes/metrics'],
          verbs: ['get'],
        },
        {
          nonResourceURLs: ['/metrics'],
          verbs: ['get'],
        },
      ],
    },

    roleConfig: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'Role',
      metadata: {
        name: 'prometheus-' + p.name + '-config',
        namespace: p.namespace,
        labels: $._config.prometheus.labels,
      },
      rules: [{
        apiGroups: [''],
        resources: ['configmaps'],
        verbs: ['get'],
      }],
    },

    roleBindingConfig: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'RoleBinding',
      metadata: {
        name: 'prometheus-' + p.name + '-config',
        namespace: p.namespace,
        labels: $._config.prometheus.labels,
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'Role',
        name: 'prometheus-' + p.name + '-config',
      },
      subjects: [{
        kind: 'ServiceAccount',
        name: 'prometheus-' + p.name,
        namespace: p.namespace,
      }],
    },

    clusterRoleBinding: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: {
        name: 'prometheus-' + p.name,
        labels: $._config.prometheus.labels,
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'prometheus-' + p.name,
      },
      subjects: [{
        kind: 'ServiceAccount',
        name: 'prometheus-' + p.name,
        namespace: p.namespace,
      }],
    },

    roleSpecificNamespaces:
      local newSpecificRole(namespace) = {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: 'Role',
        metadata: {
          name: 'prometheus-' + p.name,
          namespace: namespace,
          labels: $._config.prometheus.labels,
        },
        rules: [
          {
            apiGroups: [''],
            resources: ['services', 'endpoints', 'pods'],
            verbs: ['get', 'list', 'watch'],
          },
          {
            apiGroups: ['extensions'],
            resources: ['ingresses'],
            verbs: ['get', 'list', 'watch'],
          },
        ],
      };
      {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: 'RoleList',
        items: [newSpecificRole(x) for x in p.roleBindingNamespaces],
      },

    prometheus: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'Prometheus',
      metadata: {
        name: p.name,
        namespace: p.namespace,
        labels: { prometheus: p.name } + $._config.prometheus.labels,
      },
      spec: {
        replicas: p.replicas,
        version: $._config.versions.prometheus,
        image: $._config.imageRepos.prometheus + ':' + $._config.versions.prometheus,
        podMetadata: {
          labels: $._config.prometheus.labels,
        },
        serviceAccountName: 'prometheus-' + p.name,
        serviceMonitorSelector: {},
        podMonitorSelector: {},
        probeSelector: {},
        serviceMonitorNamespaceSelector: {},
        podMonitorNamespaceSelector: {},
        probeNamespaceSelector: {},
        nodeSelector: { 'kubernetes.io/os': 'linux' },
        ruleSelector: {
          matchLabels: {
            role: 'alert-rules',
            prometheus: p.name,
          },
        },
        resources: {
          requests: { memory: '400Mi' },
        },
        alerting: {
          alertmanagers: [{
            namespace: p.namespace,
            name: p.alertmanagerName,
            port: 'web',
          }],
        },
        securityContext: {
          runAsUser: 1000,
          runAsNonRoot: true,
          fsGroup: 2000,
        },
      },
    },

    serviceMonitor: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'ServiceMonitor',
      metadata: {
        name: 'prometheus',
        namespace: p.namespace,
        labels: $._config.prometheus.labels,
      },
      spec: {
        selector: {
          matchLabels: { prometheus: p.name } + $._config.prometheus.selectorLabels,
        },
        endpoints: [{
          port: 'web',
          interval: '30s',
        }],
      },
    },

    serviceMonitorKubeScheduler: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'ServiceMonitor',
      metadata: {
        name: 'kube-scheduler',
        namespace: p.namespace,
        labels: { 'app.kubernetes.io/name': 'kube-scheduler' },
      },
      spec: {
        jobLabel: 'app.kubernetes.io/name',
        endpoints: [{
          port: 'https-metrics',
          interval: '30s',
          scheme: 'https',
          bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
          tlsConfig: { insecureSkipVerify: true },
        }],
        selector: {
          matchLabels: { 'app.kubernetes.io/name': 'kube-scheduler' },
        },
        namespaceSelector: {
          matchNames: ['kube-system'],
        },
      },
    },

    serviceMonitorKubelet: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'ServiceMonitor',
      metadata: {
        name: 'kubelet',
        namespace: p.namespace,
        labels: { 'app.kubernetes.io/name': 'kubelet' },
      },
      spec: {
        jobLabel: 'k8s-app',
        endpoints: [
          {
            port: 'https-metrics',
            scheme: 'https',
            interval: '30s',
            honorLabels: true,
            tlsConfig: { insecureSkipVerify: true },
            bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
            metricRelabelings: relabelings,
            relabelings: [{
              sourceLabels: ['__metrics_path__'],
              targetLabel: 'metrics_path',
            }],
          },
          {
            port: 'https-metrics',
            scheme: 'https',
            path: '/metrics/cadvisor',
            interval: '30s',
            honorLabels: true,
            honorTimestamps: false,
            tlsConfig: {
              insecureSkipVerify: true,
            },
            bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
            relabelings: [{
              sourceLabels: ['__metrics_path__'],
              targetLabel: 'metrics_path',
            }],
            metricRelabelings: [
              // Drop a bunch of metrics which are disabled but still sent, see
              // https://github.com/google/cadvisor/issues/1925.
              {
                sourceLabels: ['__name__'],
                regex: 'container_(network_tcp_usage_total|network_udp_usage_total|tasks_state|cpu_load_average_10s)',
                action: 'drop',
              },
            ],
          },
          {
            port: 'https-metrics',
            scheme: 'https',
            path: '/metrics/probes',
            interval: '30s',
            honorLabels: true,
            tlsConfig: { insecureSkipVerify: true },
            bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
            relabelings: [{
              sourceLabels: ['__metrics_path__'],
              targetLabel: 'metrics_path',
            }],
          },
        ],
        selector: {
          matchLabels: { 'k8s-app': 'kubelet' },
        },
        namespaceSelector: {
          matchNames: ['kube-system'],
        },
      },
    },

    serviceMonitorKubeControllerManager: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'ServiceMonitor',
      metadata: {
        name: 'kube-controller-manager',
        namespace: p.namespace,
        labels: { 'app.kubernetes.io/name': 'kube-controller-manager' },
      },
      spec: {
        jobLabel: 'app.kubernetes.io/name',
        endpoints: [{
          port: 'https-metrics',
          interval: '30s',
          scheme: 'https',
          bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
          tlsConfig: {
            insecureSkipVerify: true,
          },
          metricRelabelings: relabelings + [
            {
              sourceLabels: ['__name__'],
              regex: 'etcd_(debugging|disk|request|server).*',
              action: 'drop',
            },
          ],
        }],
        selector: {
          matchLabels: { 'app.kubernetes.io/name': 'kube-controller-manager' },
        },
        namespaceSelector: {
          matchNames: ['kube-system'],
        },
      },
    },

    serviceMonitorApiserver: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'ServiceMonitor',
      metadata: {
        name: 'kube-apiserver',
        namespace: p.namespace,
        labels: { 'app.kubernetes.io/name': 'apiserver' },
      },
      spec: {
        jobLabel: 'component',
        selector: {
          matchLabels: {
            component: 'apiserver',
            provider: 'kubernetes',
          },
        },
        namespaceSelector: {
          matchNames: ['default'],
        },
        endpoints: [{
          port: 'https',
          interval: '30s',
          scheme: 'https',
          tlsConfig: {
            caFile: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
            serverName: 'kubernetes',
          },
          bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
          metricRelabelings: relabelings + [
            {
              sourceLabels: ['__name__'],
              regex: 'etcd_(debugging|disk|server).*',
              action: 'drop',
            },
            {
              sourceLabels: ['__name__'],
              regex: 'apiserver_admission_controller_admission_latencies_seconds_.*',
              action: 'drop',
            },
            {
              sourceLabels: ['__name__'],
              regex: 'apiserver_admission_step_admission_latencies_seconds_.*',
              action: 'drop',
            },
            {
              sourceLabels: ['__name__', 'le'],
              regex: 'apiserver_request_duration_seconds_bucket;(0.15|0.25|0.3|0.35|0.4|0.45|0.6|0.7|0.8|0.9|1.25|1.5|1.75|2.5|3|3.5|4.5|6|7|8|9|15|25|30|50)',
              action: 'drop',
            },
          ],
        }],
      },
    },

    serviceMonitorCoreDNS: {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'ServiceMonitor',
      metadata: {
        name: 'coredns',
        namespace: p.namespace,
        labels: { 'app.kubernetes.io/name': 'coredns' },
      },
      spec: {
        jobLabel: 'app.kubernetes.io/name',
        selector: {
          matchLabels: { 'app.kubernetes.io/name': 'kube-dns' },
        },
        namespaceSelector: {
          matchNames: ['kube-system'],
        },
        endpoints: [{
          port: 'metrics',
          interval: '15s',
          bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
        }],
      },
    },
  },
}
