import * as config from './config'
import {ClusterMetrics} from "./gatherMetrics";
import * as cw from "@aws-sdk/client-cloudwatch";

export const publishMetrics = async (metrics : ClusterMetrics, pendingJobCount : number | null, desiredCapacity : number) => {
    const now = new Date()
    const standardUnitCount = "Count"

    const jobCountMetric : cw.MetricDatum = {
        Value: metrics.currentJobCount,
        MetricName: config.runnerJobCountMetricName(),
        Timestamp: now,
        Unit: standardUnitCount,
    }

    const targetCapacityMetric : cw.MetricDatum = {
        Value: desiredCapacity,
        MetricName: config.runnerTargetCapacityMetricName(),
        Timestamp: now,
        Unit: standardUnitCount,
    }

    const actualCapacityMetric : cw.MetricDatum = {
        Value: metrics.currentInstances,
        MetricName: config.runnerActualCapacityMetricName(),
        Timestamp: now,
        Unit: standardUnitCount,
    }

    const metricData = [
        jobCountMetric,
        targetCapacityMetric,
        actualCapacityMetric,
    ]

    // Left out when pending jobs couldn't be counted, so the gap shows rather than a false 0
    if (pendingJobCount != null) {
        metricData.push({
            Value: pendingJobCount,
            MetricName: config.runnerPendingJobCountMetricName(),
            Timestamp: now,
            Unit: standardUnitCount,
        })
    }

    const client = new cw.CloudWatchClient({
        tls: true,
    })

    const command = new cw.PutMetricDataCommand({
        MetricData: metricData,
        Namespace: config.runnerMetricNamespace(),
    })

    await client.send(command)
}