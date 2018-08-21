local runbook_url = 'https://engineering-handbook.nami.run/sre/runbooks/kubeapi';
{
  prometheus: {
    alerts_common: {
      labels: {
        notify_to: 'slack',
        slack_channel: '#sre-alerts',
        severity: 'critical',
      },
      'for': '5m',
    },
  },
  grafana: {
    templates_custom: {
      availability_span: {
        values: '10m,1h,1d,7d,30d,90d',
        default: '7d',
        hide: '',
      },
      api_percentile: {
        values: '50, 90, 99',
        default: $.metrics.kube_api.api_percentile,
        hide: '',
      },
      verb_excl: {
        values: $.metrics.kube_api.verb_excl,
        default: $.metrics.kube_api.verb_excl,
        hide: 'variable',
      },
    },
  },
  metrics: {
    kube_api: {
      local metric = self,
      verb_excl: '(CONNECT|WATCH|PROXY)',
      api_percentile: '90',
      error_ratio_threshold: 0.01,
      latency_threshold: 200,
      name: 'Kube API',
      graphs: {
        availability_1: {
          title: 'SLO: Availaibility over $availability_span',
          type: 'singlestat',
          format: 'percentunit',
          span: 2,
          legend: '{{ job }}',
          formula: |||
            sum_over_time(kubernetes::job:slo_kube_api_ok[$availability_span]) / sum_over_time(kubernetes::job:slo_kube_api_sample[$availability_span])
          |||,
          threshold: '0.99',
        },
        availability_2: {
          title: 'SLO: Availaibility over 10m',
          span: 10,
          legend: '{{ job }}',
          formula: |||
            sum_over_time(kubernetes::job:slo_kube_api_ok[10m]) / sum_over_time(kubernetes::job:slo_kube_api_sample[10m])
          |||,
          threshold: '0.99',
        },
        error_ratio: {
          title: 'API Error ratio 500s/total (except $verb_excl)',
          formula: |||
            sum by (verb, code)(
              rate(apiserver_request_count{verb!~"$verb_excl", code=~"5.."}[5m])
            ) / ignoring(code) group_left
            sum by (verb)(
              rate(apiserver_request_count[5m])
            )
          |||,
          legend: '{{ verb }} - {{ code }}',
          threshold: metric.error_ratio_threshold,
        },
        latency: {
          title: 'API $api_percentile-th latency[ms] by verb (except $verb_excl)',
          formula: |||
            histogram_quantile (
              0.$api_percentile,
              sum by (le, verb)(
                rate(apiserver_request_latencies_bucket{verb!~"$verb_excl"}[5m])
              )
            ) / 1e3 > 0
          |||,
          legend: '{{ verb }}',
          threshold: metric.latency_threshold,
        },
      },
      alerts: {
        error_ratio: $.prometheus.alerts_common {
          local alert = self,
          name: 'KubeAPIErrorRatioHigh',
          expr: |||
            sum by (instance)(
              rate(apiserver_request_count{verb!~"%s", code=~"5.."}[5m])
            ) /
            sum by (instance)(
              rate(apiserver_request_count[5m])
            ) > %s
          ||| % [metric.verb_excl, metric.error_ratio_threshold],
          annotations: {
            summary: 'Kube API 500s ratio is High',
            description: |||
              Issue: Kube API Error ratio on {{ $labels.instance }} is above %s: {{ $value }}
              Playbook: %s#%s
            ||| % [metric.error_ratio_threshold, runbook_url, alert.name],
          },
        },
        latency: $.prometheus.alerts_common {
          local alert = self,
          name: 'KubeAPILatencyHigh',
          expr: |||
            histogram_quantile (
              0.%s,
              sum by (le, instance)(
                rate(apiserver_request_latencies_bucket{verb!~"%s"}[5m])
              )
            ) / 1e3 > %s
          ||| % [metric.api_percentile, metric.verb_excl, metric.latency_threshold],
          annotations: {
            summary: 'Kube API Latency is High',
            description: |||
              Issue: Kube API Latency on {{ $labels.instance }} is above %s ms: {{ $value }}
              Playbook: %s#%s
            ||| % [metric.latency_threshold, runbook_url, alert.name],
          },
        },
        blackbox: $.prometheus.alerts_common {
          local alert = self,
          name: 'KubeAPIUnHealthy',
          expr: |||
            probe_success{provider="kubernetes"} == 0
          |||,
          annotations: {
            summary: 'Kube API is unhealthy',
            description: |||
              Issue: Kube API is not responding 200s from blackbox.monitoring
              Playbook: %s#%s
            ||| % [runbook_url, alert.name],
          },
        },
      },
      rules: {
        common:: { labels+: { job: 'kubernetes_api_slo' } },
        error_ratio_job_instance: self.common {
          record: 'kubernetes::job_instance:apiserver_request_errors:ratio_rate5m',
          expr: |||
            sum by (job, instance)(
              rate(apiserver_request_count{verb!~"%s", code=~"5.."}[5m])
            ) /
            sum by (job, instance)(
              rate(apiserver_request_count[5m])
            )
          ||| % [metric.verb_excl],
        },
        error_ratio_job: self.common {
          record: 'kubernetes::job:apiserver_request_errors:ratio_rate5m',
          expr: |||
            sum by (job)(
              kubernetes::job_instance:apiserver_request_errors:ratio_rate5m
            )
          |||,
        },
        latency_job_instance: self.common {
          record: 'kubernetes::job_instance:apiserver_latency:pctl%srate5m' % metric.api_percentile,
          expr: |||
            histogram_quantile (
              0.%s,
              sum by (le, job, instance)(
                rate(apiserver_request_latencies_bucket{verb!~"%s"}[5m])
              )
            ) / 1e3
          ||| % [metric.api_percentile, metric.verb_excl],
        },
        latency_job: self.common {
          record: 'kubernetes::job:apiserver_latency:pctl%srate5m' % metric.api_percentile,
          expr: |||
            histogram_quantile (
              0.%s,
              sum by (le, job)(
                rate(apiserver_request_latencies_bucket{verb!~"%s"}[5m])
              )
            ) / 1e3
          ||| % [metric.api_percentile, metric.verb_excl],
        },
        probe_success: self.common {
          record: 'kubernetes::job:probe_success',
          expr: |||
            sum by()(probe_success{provider="kubernetes", component="apiserver"})
          |||,
        },

        // SLOs: error ratio and latency below thresholds
        // The purpose of below metrics is to allow answering the question:
        //   How has this SLO done in the past XXX days ?
        //
        // As prometheus-2.3.x can't do e.g.:
        //   sum_over_time(kubernetes::job:slo_kube_api_ok[30d]) /
        //   sum_over_time(kubernetes::job:slo_kube_api_ok[30d] > -Inf)
        // b/c _over_time(<formula>) is not valid, but only plain _over_time(<metric>[time]),
        // so we create `slo_kube_api_sample` as a way to provide all-1's, to be able to:
        //   sum_over_time(kubernetes::job:slo_kube_api_ok[30d]) /
        //   sum_over_time(kubernetes::job:slo_kube_api_sample[30d])

        // metric to capture "SLO Ok"
        slo_ok: self.common {
          record: 'kubernetes::job:slo_kube_api_ok',
          expr: |||
            kubernetes::job:apiserver_request_errors:ratio_rate5m < bool %s * kubernetes::job:apiserver_latency:pctl%srate5m < bool %s
          ||| % [metric.error_ratio_threshold, metric.api_percentile, metric.latency_threshold],
        },
        // metric always evaluating to 1 (with same labels as above)
        slo_sample: self.common {
          record: 'kubernetes::job:slo_kube_api_sample',
          expr: |||
            kubernetes::job:apiserver_request_errors:ratio_rate5m < bool Inf * kubernetes::job:apiserver_latency:pctl%srate5m < bool Inf
          ||| % [metric.api_percentile],
        },
      },
    },
    kube_control_mgr: {
      local metric = self,
      work_duration_limit: 100,
      name: 'Kube Control Manager',
      graphs: {
        work_duration: {
          title: 'Kube Control Manager work duration',
          formula: |||
            sum by (instance)(
              APIServiceRegistrationController_work_duration{quantile="0.9"}
            )
          |||,
          legend: '{{ instance }}',
          threshold: metric.work_duration_limit,
        },
      },
      alerts: {
        work_duration: $.prometheus.alerts_common {
          local alert = self,
          name: 'KubeControllerWorkDurationHigh',
          expr: |||
            sum by (instance)(
              APIServiceRegistrationController_work_duration{quantile="0.9"}
            ) > %s
          ||| % [metric.work_duration_limit],
          annotations: {
            summary: 'Kube Control Manager workqueue processing is slow',
            description: |||
              Issue: Kube Control Manager on {{ $labels.instance }} work duration is above %s: {{ $value }}
              Playbook: %s#%s
            ||| % [metric.work_duration_limit, runbook_url, alert.name],
          },
        },
      },
      rules: {},
    },
    kube_etcd: {
      local metric = self,
      etcd_latency_threshold: 1000,
      name: 'Kube Etcd',
      graphs: {
        latency: {
          title: 'etcd 90th latency[ms] by (operation, instance)',
          formula: |||
            max by (operation, instance)(
              etcd_request_latencies_summary{job="kubernetes_apiservers",quantile="0.9"}
            )/ 1e3
          |||,
          legend: '{{ instance }} - {{ operation }}',
          threshold: metric.etcd_latency_threshold,
        },
      },
      alerts: {
        latency: $.prometheus.alerts_common {
          local alert = self,
          name: 'KubeEtcdLatencyHigh',
          expr: |||
            max by (instance)(
              etcd_request_latencies_summary{job="kubernetes_apiservers",quantile="0.9"}
            )/ 1e3 > %s
          ||| % [metric.etcd_latency_threshold],
          annotations: {
            summary: 'Etcd Latency is High',
            description: |||
              Issue: Kube Etcd latency on {{ $labels.instance }} above %s ms: {{ $value }}
              Playbook: %s#%s
            ||| % [metric.etcd_latency_threshold, runbook_url, alert.name],
          },
        },
      },
      rules: {},
    },
  },
}
