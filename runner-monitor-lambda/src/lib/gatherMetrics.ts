// assumptions: < 100 ec2 instances to support the gitlab runners

import * as cw from "@aws-sdk/client-cloudwatch";
import * as config from "./config";
import {sumReducer} from "./utils";
import {getAutoscalingGroupInfo} from "./asgInfo";

// Instances publish every 30 seconds; allow a few missed publishes before treating one as unhealthy
const maximumMetricAgeSeconds = 180

interface InstanceMetrics {
    instanceId: string
    jobCount: number
    error : string | null
}

export interface ClusterMetrics {
    minInstances: number
    maxInstances: number
    currentInstances: number
    activeInstances: number
    currentJobCount: number
    instances : InstanceMetrics[],
}

export const gatherClusterMetrics = async (autoScalingGroupName : string) : Promise<ClusterMetrics> => {
    const asgInfo = await getAutoscalingGroupInfo(autoScalingGroupName)
    if (asgInfo.instanceIds.length == 0) {
        console.log("no instances available in the autoScalingGroup")
        return {
            currentJobCount: 0,
            currentInstances: asgInfo.currentCapacity,
            activeInstances: 0,
            minInstances: asgInfo.minSize,
            maxInstances: asgInfo.maxSize,
            instances: [],
        }
    }

    console.log(`Instances in autoscaling group: ${asgInfo.instanceIds.length}`)
    const metrics = await getInstanceMetrics(autoScalingGroupName, asgInfo.instanceIds)

    console.log(`All metrics retrieved`)

    const totalBuildCount = metrics
        .map((metric) => metric.jobCount)
        .reduce(sumReducer, 0)

    console.log(`Total build count: ${totalBuildCount}`)

    const activeInstanceCount = metrics
        .filter(metric => instanceHasErrors(metric) == false)
        .length

    console.log(`Active Instance Count: ${activeInstanceCount}`)

    return {
        currentJobCount: totalBuildCount,
        currentInstances: asgInfo.currentCapacity,
        activeInstances: activeInstanceCount,
        minInstances: asgInfo.minSize,
        maxInstances: asgInfo.maxSize,
        instances: metrics,
    }
}

// Each runner instance publishes its own running job count to CloudWatch (see the
// publish-runner-metrics timer in gitlab-runner.yaml). An instance with no recent datapoint
// is still booting or unhealthy, and is treated the same as a failed metrics scrape.
const getInstanceMetrics = async (autoScalingGroupName: string, instanceIds: string[]): Promise<InstanceMetrics[]> => {
    const client = new cw.CloudWatchClient({
        tls: true,
    })

    const now = new Date()
    const command = new cw.GetMetricDataCommand({
        StartTime: new Date(now.getTime() - 5 * 60 * 1000),
        EndTime: now,
        ScanBy: cw.ScanBy.TIMESTAMP_DESCENDING,
        MetricDataQueries: instanceIds.map((instanceId, index): cw.MetricDataQuery => {
            return {
                Id: `instance${index}`,
                MetricStat: {
                    Metric: {
                        Namespace: config.runnerMetricNamespace(),
                        MetricName: config.runnerInstanceJobCountMetricName(),
                        Dimensions: [
                            {Name: "AutoScalingGroupName", Value: autoScalingGroupName},
                            {Name: "InstanceId", Value: instanceId},
                        ],
                    },
                    Period: 60,
                    Stat: "Maximum",
                },
            }
        }),
    })

    const response = await client.send(command)
    const results = response.MetricDataResults || []

    return instanceIds.map((instanceId, index): InstanceMetrics => {
        const result = results.find(r => r.Id == `instance${index}`)
        const latestTimestamp = result?.Timestamps?.[0]
        const latestValue = result?.Values?.[0]

        if (latestTimestamp == null || latestValue == null) {
            console.log(`No job count metric found for instance ${instanceId}`)
            return {instanceId, jobCount: 0, error: "no job count metric found"}
        }

        const ageSeconds = (now.getTime() - latestTimestamp.getTime()) / 1000
        if (ageSeconds > maximumMetricAgeSeconds) {
            console.log(`Job count metric for instance ${instanceId} is stale (${ageSeconds}s old)`)
            return {instanceId, jobCount: 0, error: "job count metric is stale"}
        }

        console.log(`For instance: ${instanceId} Build Count is ${latestValue}`)
        return {instanceId, jobCount: latestValue, error: null}
    })
}

export const instanceHasErrors = (instance : InstanceMetrics) : boolean => {
    return (instance.error) ? true : false
}