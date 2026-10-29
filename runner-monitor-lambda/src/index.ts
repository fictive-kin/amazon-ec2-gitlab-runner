/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this
 * software and associated documentation files (the "Software"), to deal in the Software
 * without restriction, including without limitation the rights to use, copy, modify,
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

import * as config from './lib/config'
import * as lambda from "aws-lambda";
import {ClusterMetrics, gatherClusterMetrics} from "./lib/gatherMetrics";
import {publishMetrics} from "./lib/publishMetrics";
import {adjustScaling} from "./lib/adjustScaling";
import {replaceUnresponsiveInstance} from "./lib/replaceUnresponsive";
import {protectBusyInstances} from "./lib/protectBusyInstances";
import {countPendingJobs} from "./lib/pendingJobs";

export const handler = async (event : lambda.ScheduledEvent, context : lambda.Context | null) : Promise<void> => {
    const autoScalingGroupName = config.autoScalingGroupName()

    console.log(`Retrieving cluster metrics`)
    const metrics = await gatherClusterMetrics(autoScalingGroupName)

    console.log(`Counting pending jobs`)
    const pendingJobCount = await countPendingJobs()

    console.log(`Determining desired capacity`)
    const desiredCapacity = determineDesiredCapacity(metrics, pendingJobCount ?? 0)
    console.log(`Desired Capacity: ${desiredCapacity}`)

    console.log(`Publishing metrics`)
    await publishMetrics(metrics, pendingJobCount, desiredCapacity)

    // Before scaling, so a scale-in removes idle instances
    console.log(`Updating scale-in protection`)
    await protectBusyInstances(autoScalingGroupName, metrics)

    console.log(`Adjusting autoscaling`)
    await adjustScaling(autoScalingGroupName, metrics, desiredCapacity)

    console.log(`Checking for unresponsive instances`)
    await replaceUnresponsiveInstance(autoScalingGroupName, metrics)

    console.log(`Done`)
}

const determineDesiredCapacity = (metrics : ClusterMetrics, pendingJobCount : number) : number => {
    // the number of jobs that can run concurrently per runner
    const concurrentJobsPerRunner = config.maximumConcurrentJobsPerRunner()
    // the number of new jobs we want to be able to handle within triggering another scaling event
    const newJobCountBeforeScaling = config.countOfNewJobsBeforeScaling();

    // pretend like we're going to add more jobs, and figure out the number of instances we need to handle that.
    // Jobs waiting in GitLab count as running, so a burst gets all its instances in one scale-out
    let desiredCapacity = (metrics.currentJobCount + pendingJobCount + newJobCountBeforeScaling) / concurrentJobsPerRunner
    desiredCapacity = Math.ceil(desiredCapacity)
    // Make sure we dont go below our min
    desiredCapacity = Math.max(desiredCapacity, metrics.minInstances)
    // Make sure we dont go above our max
    desiredCapacity = Math.min(desiredCapacity, metrics.maxInstances)
    return desiredCapacity
}