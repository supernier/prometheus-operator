local kubeRbacProxyContainer = import '../kube-rbac-proxy/container.libsonnet';

{
  _config+:: {
    namespace: 'default',

    versions+:: {
      blackboxExporter: 'v0.18.0',
      configmapReloader: 'v0.4.0',
    },

    imageRepos+:: {
      blackboxExporter: 'quay.io/prometheus/blackbox-exporter',
      configmapReloader: 'jimmidyson/configmap-reload',
    },

    resources+:: {
      'blackbox-exporter': {
        requests: { cpu: '10m', memory: '20Mi' },
        limits: { cpu: '20m', memory: '40Mi' },
      },
    },

    blackboxExporter: {
      port: 9115,
      internalPort: 19115,
      replicas: 1,
      matchLabels: {
        'app.kubernetes.io/name': 'blackbox-exporter',
      },
      assignLabels: self.matchLabels {
        'app.kubernetes.io/version': $._config.versions.blackboxExporter,
      },
      modules: {
        http_2xx: {
          prober: 'http',
          http: {
            preferred_ip_protocol: 'ip4',
          },
        },
        http_post_2xx: {
          prober: 'http',
          http: {
            method: 'POST',
            preferred_ip_protocol: 'ip4',
          },
        },
        tcp_connect: {
          prober: 'tcp',
          tcp: {
            preferred_ip_protocol: 'ip4',
          },
        },
        pop3s_banner: {
          prober: 'tcp',
          tcp: {
            query_response: [
              { expect: '^+OK' },
            ],
            tls: true,
            tls_config: {
              insecure_skip_verify: false,
            },
            preferred_ip_protocol: 'ip4',
          },
        },
        ssh_banner: {
          prober: 'tcp',
          tcp: {
            query_response: [
              { expect: '^SSH-2.0-' },
            ],
            preferred_ip_protocol: 'ip4',
          },
        },
        irc_banner: {
          prober: 'tcp',
          tcp: {
            query_response: [
              { send: 'NICK prober' },
              { send: 'USER prober prober prober :prober' },
              { expect: 'PING :([^ ]+)', send: 'PONG ${1}' },
              { expect: '^:[^ ]+ 001' },
            ],
            preferred_ip_protocol: 'ip4',
          },
        },
      },
      privileged:
        local icmpModules = [self.modules[m] for m in std.objectFields(self.modules) if self.modules[m].prober == 'icmp'];
        std.length(icmpModules) > 0,
    },
  },

  blackboxExporter+::
    local bb = $._config.blackboxExporter;
    {
      configuration: {
        apiVersion: 'v1',
        kind: 'ConfigMap',
        metadata: {
          name: 'blackbox-exporter-configuration',
          namespace: $._config.namespace,
        },
        data: {
          'config.yml': std.manifestYamlDoc({ modules: bb.modules }),
        },
      },

      serviceAccount: {
        apiVersion: 'v1',
        kind: 'ServiceAccount',
        metadata: {
          name: 'blackbox-exporter',
          namespace: $._config.namespace,
        },
      },

      clusterRole: {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: 'ClusterRole',
        metadata: {
          name: 'blackbox-exporter',
        },
        rules: [
          {
            apiGroups: ['authentication.k8s.io'],
            resources: ['tokenreviews'],
            verbs: ['create'],
          },
          {
            apiGroups: ['authorization.k8s.io'],
            resources: ['subjectaccessreviews'],
            verbs: ['create'],
          },
        ],
      },

      clusterRoleBinding: {
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: 'ClusterRoleBinding',
        metadata: {
          name: 'blackbox-exporter',
        },
        roleRef: {
          apiGroup: 'rbac.authorization.k8s.io',
          kind: 'ClusterRole',
          name: 'blackbox-exporter',
        },
        subjects: [{
          kind: 'ServiceAccount',
          name: 'blackbox-exporter',
          namespace: $._config.namespace,
        }],
      },

      deployment: {
        apiVersion: 'apps/v1',
        kind: 'Deployment',
        metadata: {
          name: 'blackbox-exporter',
          namespace: $._config.namespace,
          labels: bb.assignLabels,
        },
        spec: {
          replicas: bb.replicas,
          selector: { matchLabels: bb.matchLabels },
          template: {
            metadata: { labels: bb.assignLabels },
            spec: {
              containers: [
                {
                  name: 'blackbox-exporter',
                  image: $._config.imageRepos.blackboxExporter + ':' + $._config.versions.blackboxExporter,
                  args: [
                    '--config.file=/etc/blackbox_exporter/config.yml',
                    '--web.listen-address=:%d' % bb.internalPort,
                  ],
                  ports: [{
                    name: 'http',
                    containerPort: bb.internalPort,
                  }],
                  resources: {
                    requests: $._config.resources['blackbox-exporter'].requests,
                    limits: $._config.resources['blackbox-exporter'].limits,
                  },
                  securityContext: if bb.privileged then {
                    runAsNonRoot: false,
                    capabilities: { drop: ['ALL'], add: ['NET_RAW'] },
                  } else {
                    runAsNonRoot: true,
                    runAsUser: 65534,
                  },
                  volumeMounts: [{
                    mountPath: '/etc/blackbox_exporter/',
                    name: 'config',
                    readOnly: true,
                  }],
                },
                {
                  name: 'module-configmap-reloader',
                  image: $._config.imageRepos.configmapReloader + ':' + $._config.versions.configmapReloader,
                  args: [
                    '--webhook-url=http://localhost:%d/-/reload' % bb.internalPort,
                    '--volume-dir=/etc/blackbox_exporter/',
                  ],
                  resources: {
                    requests: $._config.resources['blackbox-exporter'].requests,
                    limits: $._config.resources['blackbox-exporter'].limits,
                  },
                  securityContext: { runAsNonRoot: true, runAsUser: 65534 },
                  terminationMessagePath: '/dev/termination-log',
                  terminationMessagePolicy: 'FallbackToLogsOnError',
                  volumeMounts: [{
                    mountPath: '/etc/blackbox_exporter/',
                    name: 'config',
                    readOnly: true,
                  }],
                },
              ],
              nodeSelector: { 'kubernetes.io/os': 'linux' },
              serviceAccountName: 'blackbox-exporter',
              volumes: [{
                name: 'config',
                configMap: { name: 'blackbox-exporter-configuration' },
              }],
            },
          },
        },
      },

      service: {
        apiVersion: 'v1',
        kind: 'Service',
        metadata: {
          name: 'blackbox-exporter',
          namespace: $._config.namespace,
          labels: bb.assignLabels,
        },
        spec: {
          ports: [{
            name: 'https',
            port: bb.port,
            targetPort: 'https',
          }, {
            name: 'probe',
            port: bb.internalPort,
            targetPort: 'http',
          }],
          selector: bb.matchLabels,
        },
      },

      serviceMonitor:
        {
          apiVersion: 'monitoring.coreos.com/v1',
          kind: 'ServiceMonitor',
          metadata: {
            name: 'blackbox-exporter',
            namespace: $._config.namespace,
            labels: bb.assignLabels,
          },
          spec: {
            endpoints: [{
              bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
              interval: '30s',
              path: '/metrics',
              port: 'https',
              scheme: 'https',
              tlsConfig: {
                insecureSkipVerify: true,
              },
            }],
            selector: {
              matchLabels: bb.matchLabels,
            },
          },
        },
    } +
    (kubeRbacProxyContainer {
       config+:: {
         kubeRbacProxy: {
           image: $._config.imageRepos.kubeRbacProxy + ':' + $._config.versions.kubeRbacProxy,
           name: 'kube-rbac-proxy',
           securePortName: 'https',
           securePort: bb.port,
           secureListenAddress: ':%d' % self.securePort,
           upstream: 'http://127.0.0.1:%d/' % bb.internalPort,
           tlsCipherSuites: $._config.tlsCipherSuites,
         },
       },
     }).deploymentMixin,
}
