resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/eks/${var.project_name}/app"
  retention_in_days = 7
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-pol"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Edge SQL CPU"
          region = var.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.edge_sql.id]
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title   = "Recent app log lines"
          region  = var.region
          query   = "SOURCE '${aws_cloudwatch_log_group.app.name}' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view    = "table"
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "edge_sql_cpu" {
  alarm_name          = "${var.project_name}-edge-sql-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Edge SQL Server CPU sustained above 80%"
  dimensions          = { InstanceId = aws_instance.edge_sql.id }
  treat_missing_data  = "notBreaching"
}
