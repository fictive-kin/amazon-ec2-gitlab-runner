import * as asg from "@aws-sdk/client-auto-scaling";
import * as ec2 from "@aws-sdk/client-ec2";
import {ClusterMetrics, InstanceMetrics} from "./gatherMetrics";

// A warm instance whose root volume is this full is replaced once it is idle. Pulled images and
// job volumes build up on it, since it isn't replaced for its age.
export const maximumDiskUsedPercent = 85

// Why a warm instance should be replaced rather than kept, or null when it is fine. An instance
// that stops publishing, or fails its EC2 status checks, has no current metrics and is replaced
// by replaceUnresponsiveInstance or the group's health check instead.
const problemWith = (metrics : ClusterMetrics, instance : InstanceMetrics) : string | null => {
    if (metrics.outdatedInstanceIds.includes(instance.instanceId)) {
        return "launched from an out of date launch template"
    }
    if (instance.diskUsedPercent != null && instance.diskUsedPercent >= maximumDiskUsedPercent) {
        return `root volume is ${instance.diskUsedPercent}% full`
    }
    return null
}

export interface WarmInstances {
    // the oldest healthy instances, MinSize of them, kept through scale-in with their pulled images
    warmInstanceIds: string[]
    // an idle instance that would be warm but has a problem, and its problem
    toReplace: {instanceId: string, reason: string} | null
}

// Picks the instances to keep warm: the oldest MinSize in-service instances that are healthy,
// publishing their metrics, and without a problem. They stay protected from scale-in while idle,
// so a scale-in after a burst removes the newer instances instead of the one with a warm cache.
// An instance with a problem loses its place to the next oldest, and is replaced once idle.
export const selectWarmInstances = async (metrics : ClusterMetrics) : Promise<WarmInstances> => {
    const candidates = metrics.instances.filter(i =>
        metrics.inServiceInstanceIds.includes(i.instanceId)
        && !metrics.unhealthyInstanceIds.includes(i.instanceId)
        && i.error == null)
    const count = metrics.minInstances
    if (candidates.length == 0 || count <= 0) {
        return {warmInstanceIds: [], toReplace: null}
    }

    const launchTimes = await getLaunchTimes(candidates.map(i => i.instanceId))
    if (launchTimes == null) {
        // Without launch times there's no telling which protected instance is the warm one, so
        // keep them all protected for this run rather than give up the warm one to a scale-in
        const warmInstanceIds = candidates
            .filter(i => metrics.protectedInstanceIds.includes(i.instanceId))
            .map(i => i.instanceId)
        return {warmInstanceIds, toReplace: null}
    }

    const oldestFirst = [...candidates].sort((a, b) =>
        (launchTimes.get(a.instanceId) ?? Infinity) - (launchTimes.get(b.instanceId) ?? Infinity))

    const warmInstanceIds = oldestFirst
        .filter(i => problemWith(metrics, i) == null)
        .slice(0, count)
        .map(i => i.instanceId)

    // Only an instance that would otherwise be warm is replaced. A newer one with a problem is
    // removed by the next scale-in, which prefers an out of date launch template.
    let toReplace : WarmInstances["toReplace"] = null
    for (const instance of oldestFirst.slice(0, count)) {
        const reason = problemWith(metrics, instance)
        if (reason != null && instance.jobCount == 0) {
            toReplace = {instanceId: instance.instanceId, reason}
            break
        }
    }

    console.log(`Warm instances: ${warmInstanceIds.join(", ") || "none"}`)
    return {warmInstanceIds, toReplace}
}

const getLaunchTimes = async (instanceIds : string[]) : Promise<Map<string, number> | null> => {
    const client = new ec2.EC2Client({
        tls: true,
    })

    try {
        const launchTimes = new Map<string, number>()
        const response = await client.send(new ec2.DescribeInstancesCommand({InstanceIds: instanceIds}))
        for (const reservation of response.Reservations ?? []) {
            for (const instance of reservation.Instances ?? []) {
                if (instance.InstanceId != null && instance.LaunchTime != null) {
                    launchTimes.set(instance.InstanceId, instance.LaunchTime.getTime())
                }
            }
        }
        return launchTimes
    } catch (ex) {
        console.log(`Could not read instance launch times: ${ex}`)
        return null
    }
}

// Replaces an idle warm instance that has a problem by marking it unhealthy. The group launches a
// replacement, and the termination lifecycle hook unregisters the runner and lets any job it picked
// up in the meantime finish. One at a time: nothing is replaced while an instance is still launching,
// or while a deploy's rolling update has replacement suspended.
export const replaceProblemWarmInstance = async (metrics : ClusterMetrics, warm : WarmInstances) => {
    if (warm.toReplace == null) {
        return
    }
    if (metrics.suspendedProcesses.includes("ReplaceUnhealthy")) {
        console.log(`Not replacing ${warm.toReplace.instanceId} (${warm.toReplace.reason}): replacement is suspended`)
        return
    }
    const launching = metrics.instances.filter(i => !metrics.inServiceInstanceIds.includes(i.instanceId))
    if (launching.length > 0 || metrics.unhealthyInstanceIds.length > 0) {
        console.log(`Not replacing ${warm.toReplace.instanceId} (${warm.toReplace.reason}) while another instance is launching or being replaced`)
        return
    }

    const client = new asg.AutoScalingClient({
        tls: true,
    })

    try {
        console.log(`Replacing warm instance ${warm.toReplace.instanceId}: ${warm.toReplace.reason}`)
        await client.send(new asg.SetInstanceHealthCommand({
            InstanceId: warm.toReplace.instanceId,
            HealthStatus: "Unhealthy",
            ShouldRespectGracePeriod: false,
        }))
    } catch (ex) {
        // Don't fail the run; the next run tries again
        console.log(`Could not mark instance ${warm.toReplace.instanceId} unhealthy: ${ex}`)
    }
}
