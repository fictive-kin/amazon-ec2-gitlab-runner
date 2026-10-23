import * as asg from "@aws-sdk/client-auto-scaling";

export interface AutoScalingGroupInfo {
    autoScalingGroupName: string
    maxSize: number
    minSize: number
    currentCapacity: number
    instanceIds: string[]
}

export const getAutoscalingGroupInfo = async (autoScalingGroupName : string): Promise<AutoScalingGroupInfo> => {
    const client = new asg.AutoScalingClient({
        tls: true,
    })

    const command = new asg.DescribeAutoScalingGroupsCommand({
        AutoScalingGroupNames: [
            autoScalingGroupName,
        ]
    })

    const response = await client.send(command)
    if (response.AutoScalingGroups == null || response.AutoScalingGroups.length == 0) {
        throw new Error("autoScalingGroup not found")
    }
    const group = response.AutoScalingGroups[0]
    if (group.Instances == null) {
        throw new Error("autoScalingGroup.Instances not found")
    }
    if (group.MinSize == null) {
        throw new Error("autoScalingGroup.MinSize not found")
    }
    if (group.MaxSize == null) {
        throw new Error("autoScalingGroup.MaxSize not found")
    }
    if (group.DesiredCapacity == null) {
        throw new Error("autoScalingGroup.DesiredCapacity not found")
    }

    const activeInstances = group.Instances.filter(i => {
        switch (i.LifecycleState) {
            case asg.LifecycleState.IN_SERVICE:
            case asg.LifecycleState.PENDING:
                return true
            default:
                return false
        }
    })

    const activeInstanceIds = activeInstances.map((i) => i.InstanceId || "").filter(i => i != "")

    return {
        autoScalingGroupName: autoScalingGroupName,
        instanceIds: activeInstanceIds,
        maxSize: group.MaxSize,
        minSize: group.MinSize,
        currentCapacity: group.DesiredCapacity,
    }
}
