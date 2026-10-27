import * as asg from "@aws-sdk/client-auto-scaling";
import {ClusterMetrics, InstanceMetrics} from "./gatherMetrics";

// An instance that published a job count and then went quiet this long is treated as hung.
// A frozen instance can take hours to fail its EC2 status checks; this replaces it in minutes.
const unresponsiveAfterSeconds = 300

const isUnresponsive = (instance : InstanceMetrics) : boolean => {
    return instance.metricAgeSeconds != null && instance.metricAgeSeconds > unresponsiveAfterSeconds
}

// Marks at most one unresponsive instance unhealthy per run, so the autoscaling group replaces it.
// The termination lifecycle hook still stops the runner gracefully if the instance can be reached.
export const replaceUnresponsiveInstance = async (autoScalingGroupName : string, metrics : ClusterMetrics) => {
    // Instances still booting have not published yet (metricAgeSeconds is null) and are left alone
    const reporting = metrics.instances
        .filter(i => metrics.inServiceInstanceIds.includes(i.instanceId))
        .filter(i => i.metricAgeSeconds != null)
    const unresponsive = reporting.filter(isUnresponsive)

    if (unresponsive.length == 0) {
        return
    }

    // When several instances go quiet at once the cause is more likely CloudWatch or the network
    // than the instances themselves, so don't replace the whole group
    if (reporting.length > 1 && unresponsive.length == reporting.length) {
        console.log(`All ${reporting.length} instances stopped publishing job counts; not replacing any`)
        return
    }

    const instance = unresponsive
        .sort((a, b) => (b.metricAgeSeconds || 0) - (a.metricAgeSeconds || 0))[0]

    const client = new asg.AutoScalingClient({
        tls: true,
    })

    try {
        const command = new asg.SetInstanceHealthCommand({
            InstanceId: instance.instanceId,
            HealthStatus: "Unhealthy",
            ShouldRespectGracePeriod: false,
        })
        console.log(`Marking instance ${instance.instanceId} unhealthy: no job count for ${instance.metricAgeSeconds}s`)
        await client.send(command)
    } catch (ex) {
        // Don't fail the run; scaling has already been adjusted and the next run tries again
        console.log(`Could not mark instance ${instance.instanceId} unhealthy: ${ex}`)
    }
}
