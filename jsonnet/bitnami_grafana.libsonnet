local grafana = import 'grafonnet-lib/grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local singlestat = grafana.singlestat;
local prometheus = grafana.prometheus;

{
  dash:: {
    new(title, refresh="5m", tags=[]):: self + grafana.dashboard.new(
        title,
        tags=tags,
        refresh=refresh,
        time_from='now-3h',
        )
        .addTemplate(
          // 1st template is $datasource, so that every dashboard has it select-able
          grafana.template.datasource( 'datasource', 'prometheus', 'Prometheus')
        )
  },
  default_type(p):: (
      if std.objectHas(p, "type") then p.type else "graph"
  ),
  default_span(p):: (
      if std.objectHas(p, "span") then p.span else 12
  ),
  default_format(p):: (
      if std.objectHas(p, "format") then p.format else "none"
  ),
  graph:: {
    new(p):: self + graphPanel.new(
      p.title,
      datasource='$datasource',
      legend_values=true,
      legend_max=true,
      legend_current=true,
      legend_avg=true,
      legend_alignAsTable=true,
      legend_rightSide=true,
      legend_sort='max',
      legend_sortDesc=true,
      span=$.default_span(p),
    ) {
      thresholds: [$.threshold_gt(p.threshold)]
    },
  },

  singlestat:: {
    new(p):: self + singlestat.new(
      p.title,
      datasource='$datasource',
      span=$.default_span(p),
      format=$.default_format(p),
      valueName='current',
    ) {
      thresholds: p.threshold,
    }
  },

  panel:: {
    new(p):: (
      {
        graph: $.graph.new,
        singlestat: $.singlestat.new,
      }[$.default_type(p)](p)
    ),
  },

  prom(expr, legend):: self + prometheus.target(
    expr, datasource='$datasource', legendFormat=legend
  ),
  threshold_gt(value):: {
    colorMode: 'critical',
    fill: true,
    line: true,
    op: 'gt',
    value: value,
  },
}
