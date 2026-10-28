import * as asg from "@aws-sdk/client-auto-scaling";
import {ClusterMetrics} from "./gatherMetrics";

// SetInstanceProtection accepts at most 50 instances per call
const maximumInstancesPerCall = 50

// Protects instances that are running jobs from scale-in, so the autoscaling group removes idle
// instances first rather than the oldest. A busy instance that is picked still drains its jobs
// through the lifecycle hook, but it takes no new jobs while it does and an idle one keeps running.
// Instances without a current job count are left unprotected so they can still be removed.
// Protection doesn't stop health replacement, so an unresponsive instance is still replaced.
export const protectBusyInstances = async (autoScalingGroupName : string, metrics : ClusterMetrics) => {
    const isBusy = (instanceId : string) : boolean => {
        const instance = metrics.instances.find(i => i.instanceId == instanceId)
        return instance != null && instance.error == null && instance.jobCount > 0
    }

    const toProtect = metrics.inServiceInstanceIds
        .filter(id => isBusy(id) && !metrics.protectedInstanceIds.includes(id))
    const toUnprotect = metrics.inServiceInstanceIds
        .filter(id => !isBusy(id) && metrics.protectedInstanceIds.includes(id))

    await setProtection(autoScalingGroupName, toProtect, true)
    await setProtection(autoScalingGroupName, toUnprotect, false)
}

const setProtection = async (autoScalingGroupName : string, instanceIds : string[], protect : boolean) => {
    if (instanceIds.length == 0) {
        return
    }

    const client = new asg.AutoScalingClient({
        tls: true,
    })

    for (let start = 0; start < instanceIds.length; start += maximumInstancesPerCall) {
        const batch = instanceIds.slice(start, start + maximumInstancesPerCall)
        try {
            const command = new asg.SetInstanceProtectionCommand({
                AutoScalingGroupName: autoScalingGroupName,
                InstanceIds: batch,
                ProtectedFromScaleIn: protect,
            })
            console.log(`${protect ? "Protecting" : "Unprotecting"} instances from scale-in: ${batch.join(", ")}`)
            await client.send(command)
        } catch (ex) {
            // Don't fail the run; scaling still works without protection and the next run tries again
            console.log(`Could not change scale-in protection for ${batch.join(", ")}: ${ex}`)
        }
    }
}
