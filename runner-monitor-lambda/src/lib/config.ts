
export const autoScalingGroupName = () : string => {
    if (process.env.AUTOSCALING_GROUP_NAME) {
        return process.env.AUTOSCALING_GROUP_NAME
    }
    throw Error("Environment Variable AUTOSCALING_GROUP_NAME not found")
}

// the number of jobs that can run concurrently per runner
export const maximumConcurrentJobsPerRunner = () : number => {
    if (process.env.MAXIMUM_CONCURRENT_JOBS_PER_RUNNER) {
        const count = parseInt(process.env.MAXIMUM_CONCURRENT_JOBS_PER_RUNNER)
        if (count) {
            return count
        }
    }
    throw Error("Environment Variable MAXIMUM_CONCURRENT_JOBS_PER_RUNNER not found")
}

// the number of new jobs we want to be able to handle within triggering another scaling event
export const countOfNewJobsBeforeScaling = () : number => {
    if (process.env.COUNT_OF_NEW_JOBS_BEFORE_SCALING) {
        const count = parseInt(process.env.COUNT_OF_NEW_JOBS_BEFORE_SCALING)
        if (count) {
            return count
        }
    }
    throw Error("Environment Variable COUNT_OF_NEW_JOBS_BEFORE_SCALING not found")
}

export const runnerMetricNamespace = () : string => {
    if (process.env.RUNNER_METRIC_NAMESPACE) {
        return process.env.RUNNER_METRIC_NAMESPACE
    }
    throw Error("Environment Variable RUNNER_METRIC_NAMESPACE not found")
}

// per-instance running job count, published by each runner instance
export const runnerInstanceJobCountMetricName = () : string => {
    if (process.env.RUNNER_INSTANCE_JOB_COUNT_METRIC_NAME) {
        return process.env.RUNNER_INSTANCE_JOB_COUNT_METRIC_NAME
    }
    throw Error("Environment Variable RUNNER_INSTANCE_JOB_COUNT_METRIC_NAME not found")
}

export const runnerJobCountMetricName = () : string => {
    if (process.env.RUNNER_JOB_COUNT_METRIC_NAME) {
        return process.env.RUNNER_JOB_COUNT_METRIC_NAME
    }
    throw Error("Environment Variable RUNNER_JOB_COUNT_METRIC_NAME not found")
}

export const runnerTargetCapacityMetricName = () : string => {
    if (process.env.RUNNER_TARGET_CAPACITY_METRIC_NAME) {
        return process.env.RUNNER_TARGET_CAPACITY_METRIC_NAME
    }
    throw Error("Environment Variable RUNNER_TARGET_CAPACITY_METRIC_NAME not found")
}

export const runnerActualCapacityMetricName = () : string => {
    if (process.env.RUNNER_ACTUAL_CAPACITY_METRIC_NAME) {
        return process.env.RUNNER_ACTUAL_CAPACITY_METRIC_NAME
    }
    throw Error("Environment Variable RUNNER_ACTUAL_CAPACITY_METRIC_NAME not found")
}

export const runnerPendingJobCountMetricName = () : string => {
    if (process.env.RUNNER_PENDING_JOB_COUNT_METRIC_NAME) {
        return process.env.RUNNER_PENDING_JOB_COUNT_METRIC_NAME
    }
    throw Error("Environment Variable RUNNER_PENDING_JOB_COUNT_METRIC_NAME not found")
}

// IDs of the GitLab runners whose pending jobs count toward scaling; empty when not configured
export const gitlabRunnerIds = () : string[] => {
    return (process.env.GITLAB_RUNNER_IDS || "")
        .split(",")
        .map(id => id.trim())
        .filter(id => id.length > 0)
}

export const gitlabUrl = () : string => {
    if (process.env.GITLAB_URL) {
        return process.env.GITLAB_URL.replace(/\/+$/, "")
    }
    throw Error("Environment Variable GITLAB_URL not found")
}

// SSM parameter holding the GitLab API token used to count pending jobs
export const gitlabApiTokenParameterName = () : string => {
    if (process.env.GITLAB_API_TOKEN_PARAMETER) {
        return process.env.GITLAB_API_TOKEN_PARAMETER
    }
    throw Error("Environment Variable GITLAB_API_TOKEN_PARAMETER not found")
}