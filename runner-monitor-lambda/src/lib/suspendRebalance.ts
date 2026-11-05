import * as asg from "@aws-sdk/client-auto-scaling";
import {ClusterMetrics} from "./gatherMetrics";

// Keeps AZRebalance suspended on the group. Scale-in removes idle instances wherever they are
// (see protectBusyInstances), which leaves the zones uneven; AZRebalance then launches a fresh
// instance and terminates another to even them out. Each of those activities restarts the
// scale-in cooldown, so idle instances were kept for 20+ minutes after a burst, and the extra
// launches start with empty image caches. Runners don't need to be spread evenly across zones.
// CloudFormation can't set suspended processes on the group, so the monitor enforces it each run.
export const suspendAzRebalance = async (autoScalingGroupName : string, metrics : ClusterMetrics) => {
    if (metrics.suspendedProcesses.includes("AZRebalance")) {
        return
    }

    const client = new asg.AutoScalingClient({
        tls: true,
    })

    try {
        console.log(`Suspending AZRebalance on ${autoScalingGroupName}`)
        await client.send(new asg.SuspendProcessesCommand({
            AutoScalingGroupName: autoScalingGroupName,
            ScalingProcesses: ["AZRebalance"],
        }))
    } catch (ex) {
        // Don't fail the run; scaling still works and the next run tries again
        console.log(`Could not suspend AZRebalance: ${ex}`)
    }
}
