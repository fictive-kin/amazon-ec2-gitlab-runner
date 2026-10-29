import * as ssm from "@aws-sdk/client-ssm";
import * as config from "./config";

// A slow GitLab API gives up after this long, so it doesn't hold up scaling
const requestTimeoutMilliseconds = 10_000

// Pending jobs read per project: more than MaxSize instances could take at once
const pendingJobsPageSize = 100

interface Runner {
    id: number
    paused: boolean
    run_untagged: boolean
    tag_list: string[]
    // present for project runners
    projects?: { id: number, path_with_namespace: string }[]
}

interface Job {
    id: number
    tag_list: string[]
}

// Counts the jobs waiting in GitLab for the stack's runners, so a burst of jobs scales out at once
// instead of one instance at a time as each fills up. Returns null when they can't be counted (no
// runner IDs or API token configured, or the GitLab API failed); scaling then goes by the running
// jobs alone.
export const countPendingJobs = async () : Promise<number | null> => {
    const runnerIds = config.gitlabRunnerIds()
    if (runnerIds.length == 0) {
        console.log(`No GitLab runner IDs configured; not counting pending jobs`)
        return null
    }

    try {
        const token = await getApiToken()
        if (!token) {
            console.log(`No GitLab API token stored in ${config.gitlabApiTokenParameterName()}; not counting pending jobs`)
            return null
        }

        // A job some runners share is counted once
        const pendingJobIds = new Set<number>()
        for (const runnerId of runnerIds) {
            const runner = await gitlabGet<Runner>(token, `/runners/${runnerId}`)
            if (runner.paused) {
                console.log(`Runner ${runnerId} is paused; not counting its pending jobs`)
                continue
            }
            if (!runner.projects || runner.projects.length == 0) {
                console.log(`Runner ${runnerId} is not a project runner; not counting its pending jobs`)
                continue
            }
            for (const project of runner.projects) {
                const jobs = await gitlabGet<Job[]>(token, `/projects/${project.id}/jobs?scope[]=pending&per_page=${pendingJobsPageSize}`)
                const runnable = jobs.filter(job => runnerCanTake(runner, job))
                console.log(`Pending jobs in ${project.path_with_namespace} for runner ${runnerId}: ${runnable.length} of ${jobs.length}`)
                runnable.forEach(job => pendingJobIds.add(job.id))
            }
        }

        console.log(`Pending job count: ${pendingJobIds.size}`)
        return pendingJobIds.size
    } catch (ex) {
        console.log(`Could not count pending jobs, so scaling goes by running jobs only: ${ex}`)
        return null
    }
}

// GitLab gives a job to a runner that has all of the job's tags, and a job without tags only to a
// runner that runs untagged jobs
const runnerCanTake = (runner : Runner, job : Job) : boolean => {
    if (job.tag_list.length == 0) {
        return runner.run_untagged
    }
    return job.tag_list.every(tag => runner.tag_list.includes(tag))
}

// SecureString written by deploy-runner.sh; null when none is stored
const getApiToken = async () : Promise<string | null> => {
    const client = new ssm.SSMClient({
        tls: true,
    })
    try {
        const response = await client.send(new ssm.GetParameterCommand({
            Name: config.gitlabApiTokenParameterName(),
            WithDecryption: true,
        }))
        return response.Parameter?.Value || null
    } catch (ex) {
        if (ex instanceof ssm.ParameterNotFound) {
            return null
        }
        throw ex
    }
}

const gitlabGet = async <T>(token : string, path : string) : Promise<T> => {
    const response = await fetch(`${config.gitlabUrl()}/api/v4${path}`, {
        headers: {"PRIVATE-TOKEN": token},
        signal: AbortSignal.timeout(requestTimeoutMilliseconds),
    })
    if (!response.ok) {
        const body = await response.text()
        throw new Error(`GET ${path} returned HTTP ${response.status}: ${body.slice(0, 300)}`)
    }
    return await response.json() as T
}
