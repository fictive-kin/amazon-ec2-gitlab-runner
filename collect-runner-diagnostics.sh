#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Collects everything needed to investigate a runner that stops picking up jobs: the stack,
# autoscaling group, Lambda logs and metrics from AWS, plus logs, process state, docker state
# and a goroutine dump from each runner instance (gathered through SSM Run Command).
# Tokens are redacted before anything is written.

set -uo pipefail

export AWS_PAGER=""

usage() {
    cat <<EOF
Usage: $(basename "$0") <stack-name> <region> [<aws-profile>] [--hours <n>]

Collects logs and setup information for a deployed GitLab Runner stack into
diagnostics/<stack-name>-<timestamp>/ and a .tar.gz of that directory.

From AWS: stack status and events, autoscaling group, scaling activities, instance
refreshes, lifecycle hooks, launch template, instance status and console output, recent
SSM commands, Lambda and lifecycle document logs, and runner and instance metrics.

From each runner instance (needs the SSM agent online): gitlab-runner service status,
journal, redacted config.toml, 'gitlab-runner verify', the metrics endpoint, current jobs
and a goroutine dump, docker state, memory, disk, OOM kills and GitLab connectivity.

Runner, personal access and deploy tokens are redacted. Job container logs are not
collected because they may contain secrets.

Arguments:
  stack-name        CloudFormation stack name
  region            AWS region of the stack, e.g. us-east-1
  aws-profile       Optional AWS CLI profile. Without it, the AWS CLI's default
                    credentials are used

Options:
  --hours <n>       How many hours of logs and metrics to collect (default 24)
  -h, --help, -?    Show this help and exit

Environment:
  GITLAB_TOKEN      Optional GitLab access token that can read the runners. When set,
                    the runners' status and recent jobs are fetched from the GitLab API
EOF
}

hours=24
positional=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help|-\?) usage; exit 0 ;;
        --hours)
            [[ "${2:-}" =~ ^[0-9]+$ && "$2" -gt 0 ]] || { echo "--hours needs a positive number" >&2; exit 1; }
            hours=$2
            shift 2
            ;;
        -*) echo "Unknown option: $1" >&2; echo "Run '$(basename "$0") --help' for usage." >&2; exit 1 ;;
        *) positional+=("$1"); shift ;;
    esac
done

if [[ "${#positional[@]}" -lt 2 || "${#positional[@]}" -gt 3 ]]
then
    echo "Incorrect number of arguments" >&2
    echo "Usage: $(basename "$0") <stack-name> <region> [<aws-profile>] [--hours <n>]" >&2
    echo "Run '$(basename "$0") --help' for details." >&2
    exit 1
fi

stack_name=${positional[0]}
region=${positional[1]}
profile_args=()
if [[ -n "${positional[2]:-}" ]]; then
    profile_args=(--profile "${positional[2]}")
fi

cd "$(dirname "$0")" || exit 1

asg_name="${stack_name}-asg"
monitor_function="${stack_name}-runner-monitor"
lifecycle_function="${stack_name}-asg-lifecycle-hook"
metric_namespace="${stack_name}-runner-metrics"

now=$(date +%s)
start_epoch=$((now - hours * 3600))
start_ms=$((start_epoch * 1000))
# get-metric-statistics returns at most 1440 data points
period=$(( (hours * 3600 / 1440 + 59) / 60 * 60 ))
[[ "${period}" -lt 60 ]] && period=60

out_dir="diagnostics/${stack_name}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${out_dir}/aws" "${out_dir}/instances"
chmod 700 "${out_dir}"

awsr() {
    aws ${profile_args[@]+"${profile_args[@]}"} --region "${region}" "$@"
}

# capture <file> <aws args...>  -> writes output and errors to the file, never fails the script
capture() {
    local file="${out_dir}/$1"
    shift
    echo "    $1 $2 -> ${file#"${out_dir}"/}"
    {
        echo "# aws $*"
        awsr "$@" 2>&1
        echo "# exit $?"
    } > "${file}"
}

# Removes GitLab tokens (runner glrt-, personal access glpat-, deploy gldt-) and token fields
redact() {
    sed -E \
        -e 's/(glrt|glpat|gldt|glcbt|glptt|GR1348941)[A-Za-z0-9_.-]{8,}/\1-REDACTED/g' \
        -e 's/([Tt]oken[" ]*[=:][" ]*)[A-Za-z0-9_.-]{8,}/\1REDACTED/g'
}

#
# AWS side
#

echo "==> Collecting diagnostics for stack ${stack_name} in ${region} (last ${hours} hours)"
echo "    Output: ${out_dir}"

echo "==> Account and stack"
capture aws/caller-identity.json sts get-caller-identity
capture aws/stack.json cloudformation describe-stacks --stack-name "${stack_name}"
capture aws/stack-resources.json cloudformation describe-stack-resources --stack-name "${stack_name}"
capture aws/stack-events.json cloudformation describe-stack-events --stack-name "${stack_name}" --max-items 200

if [[ -f "${stack_name}.properties" ]]; then
    redact < "${stack_name}.properties" | sed -E 's/^(RunnersToken=).*/\1REDACTED/' > "${out_dir}/properties.txt"
fi

physical_id() {
    awsr cloudformation describe-stack-resource --stack-name "${stack_name}" --logical-resource-id "$1" \
        --query StackResourceDetail.PhysicalResourceId --output text 2> /dev/null
}
document_log_group=$(physical_id DocumentLogGroup)
document_name=$(physical_id Document)
monitor_rule=$(physical_id ExecuteRunnerMonitor)
lifecycle_rule=$(physical_id Rule)
launch_template=$(physical_id RunnerLaunchTemplate)

echo "==> Autoscaling group"
capture aws/asg.json autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${asg_name}"
capture aws/asg-activities.json autoscaling describe-scaling-activities --auto-scaling-group-name "${asg_name}" --max-items 100
capture aws/asg-instance-refreshes.json autoscaling describe-instance-refreshes --auto-scaling-group-name "${asg_name}"
capture aws/asg-lifecycle-hooks.json autoscaling describe-lifecycle-hooks --auto-scaling-group-name "${asg_name}"
if [[ -n "${launch_template}" && "${launch_template}" != "None" ]]; then
    capture aws/launch-template.json ec2 describe-launch-template-versions --launch-template-id "${launch_template}" --versions '$Latest'
fi
capture aws/ssm-runner-tokens-metadata.json ssm describe-parameters --parameter-filters "Key=Name,Values=/${stack_name}/runner-tokens"

instance_ids=$(awsr autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${asg_name}" \
    --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text 2> /dev/null | tr '\t' ' ')
[[ "${instance_ids}" == "None" ]] && instance_ids=""

# Instances launched or terminated during the window, so metrics cover the ones that were replaced
start_iso=$(date -u -r "${start_epoch}" +%Y-%m-%dT%H:%M:%S 2> /dev/null || date -u -d "@${start_epoch}" +%Y-%m-%dT%H:%M:%S)
past_instance_ids=$(awsr autoscaling describe-scaling-activities --auto-scaling-group-name "${asg_name}" --max-items 100 \
    --query 'Activities[].[StartTime,Description]' --output text 2> /dev/null \
    | awk -v start="${start_iso}" 'substr($1, 1, 19) >= start' | grep -oE 'i-[0-9a-f]+' | sort -u)
all_instance_ids=$(echo ${instance_ids} ${past_instance_ids} | tr ' ' '\n' | sort -u | tr '\n' ' ')

echo "==> Instances: ${instance_ids:-none} (in the window: ${all_instance_ids:-none})"
if [[ -n "${instance_ids}" ]]; then
    # shellcheck disable=SC2086
    capture aws/instances.json ec2 describe-instances --instance-ids ${instance_ids}
    # shellcheck disable=SC2086
    capture aws/instance-status.json ec2 describe-instance-status --include-all-instances --instance-ids ${instance_ids}
    capture aws/ssm-instance-information.json ssm describe-instance-information \
        --filters "Key=tag:aws:autoscaling:groupName,Values=${asg_name}"
fi
capture aws/ssm-recent-commands.json ssm list-commands --max-items 50
if [[ -n "${document_name}" && "${document_name}" != "None" ]]; then
    # Graceful shutdown runs on terminating instances, with the first 2500 characters of each one's output
    capture aws/lifecycle-command-invocations.json ssm list-command-invocations --details \
        --filters "key=DocumentName,value=${document_name}" "key=InvokedAfter,value=${start_iso}Z" \
        --query 'CommandInvocations[].{CommandId:CommandId,InstanceId:InstanceId,RequestedDateTime:RequestedDateTime,Status:Status,StatusDetails:StatusDetails,Plugins:CommandPlugins[].{Status:Status,ResponseCode:ResponseCode,ResponseStartDateTime:ResponseStartDateTime,ResponseFinishDateTime:ResponseFinishDateTime,Output:Output}}'
fi

for instance_id in ${instance_ids}; do
    mkdir -p "${out_dir}/instances/${instance_id}"
    echo "    console output and screenshot for ${instance_id}"
    awsr ec2 get-console-output --instance-id "${instance_id}" --query Output --output text \
        > "${out_dir}/instances/${instance_id}/console-output.txt" 2>&1
    awsr ec2 get-console-screenshot --instance-id "${instance_id}" --query ImageData --output text 2> /dev/null \
        | base64 -d > "${out_dir}/instances/${instance_id}/console-screenshot.jpg" 2> /dev/null \
        || rm -f "${out_dir}/instances/${instance_id}/console-screenshot.jpg"
done

echo "==> EventBridge rules and Lambda functions"
for rule in ${monitor_rule} ${lifecycle_rule}; do
    [[ "${rule}" == "None" ]] && continue
    capture "aws/rule-${rule}.json" events describe-rule --name "${rule}"
done
capture aws/lambda-runner-monitor.json lambda get-function-configuration --function-name "${monitor_function}"
capture aws/lambda-lifecycle-hook.json lambda get-function-configuration --function-name "${lifecycle_function}"

echo "==> Logs"
# fetch_logs <file> <log-group> [extra filter-log-events args...]
fetch_logs() {
    local file=$1 group=$2
    shift 2
    capture "${file}" logs filter-log-events --log-group-name "${group}" --start-time "${start_ms}" \
        --query 'events[].[timestamp,logStreamName,message]' --output text "$@"
}
mkdir -p "${out_dir}/logs"
fetch_logs logs/runner-monitor-lambda.txt "/aws/lambda/${monitor_function}"
fetch_logs logs/lifecycle-hook-lambda.txt "/aws/lambda/${lifecycle_function}"
if [[ -n "${document_log_group}" && "${document_log_group}" != "None" ]]; then
    # Output of the graceful shutdown document run on terminating instances
    fetch_logs logs/lifecycle-document.txt "${document_log_group}"
fi

echo "==> Metrics (period ${period}s)"
mkdir -p "${out_dir}/metrics"
# metric <file> <namespace> <metric> <statistics> [dimensions...]
metric() {
    local file=$1 namespace=$2 name=$3 stats=$4
    shift 4
    local dimension_args=()
    [[ "$#" -gt 0 ]] && dimension_args=(--dimensions "$@")
    capture "metrics/${file}" cloudwatch get-metric-statistics --namespace "${namespace}" --metric-name "${name}" \
        --start-time "${start_epoch}" --end-time "${now}" --period "${period}" --statistics ${stats} \
        ${dimension_args[@]+"${dimension_args[@]}"} \
        --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Minimum,Maximum,Sum,SampleCount]' --output text
}
metric job-count.txt "${metric_namespace}" "${stack_name}-job-count" "Average Maximum"
metric target-capacity.txt "${metric_namespace}" "${stack_name}-target-capacity" "Average Maximum"
metric actual-capacity.txt "${metric_namespace}" "${stack_name}-actual-capacity" "Average Maximum"
metric lambda-runner-monitor-errors.txt AWS/Lambda Errors "Sum" "Name=FunctionName,Value=${monitor_function}"
capture metrics/available-runner-metrics.json cloudwatch list-metrics --namespace "${metric_namespace}"
for instance_id in ${all_instance_ids}; do
    metric "${instance_id}-job-count.txt" "${metric_namespace}" "${stack_name}-instance-job-count" "Average Maximum" \
        "Name=AutoScalingGroupName,Value=${asg_name}" "Name=InstanceId,Value=${instance_id}"
    metric "${instance_id}-cpu.txt" AWS/EC2 CPUUtilization "Average Maximum" "Name=InstanceId,Value=${instance_id}"
    metric "${instance_id}-cpu-credit-balance.txt" AWS/EC2 CPUCreditBalance "Average Minimum" "Name=InstanceId,Value=${instance_id}"
    metric "${instance_id}-cpu-surplus-credits-charged.txt" AWS/EC2 CPUSurplusCreditsCharged "Sum" "Name=InstanceId,Value=${instance_id}"
    metric "${instance_id}-status-check-failed.txt" AWS/EC2 StatusCheckFailed "Maximum" "Name=InstanceId,Value=${instance_id}"
    metric "${instance_id}-ebs-io-balance.txt" AWS/EC2 EBSIOBalance% "Average Minimum" "Name=InstanceId,Value=${instance_id}"
    metric "${instance_id}-network-out.txt" AWS/EC2 NetworkOut "Sum" "Name=InstanceId,Value=${instance_id}"
done

#
# Instance side, through SSM Run Command
#

# Runs as root on each instance. Output goes to CloudWatch Logs because Run Command keeps only
# the first 24000 characters of a command's output.
read -r -d '' instance_script <<'INSTANCE_SCRIPT'
HOURS=__HOURS__
section() { echo; echo "===== $1 ====="; }
run() {
    section "$1"
    timeout "${2:-60}" bash -c "$1" 2>&1
    echo "[exit $?]"
}
collect() {
    run 'date -u; uptime; uname -a; head -3 /etc/os-release'
    # cfn-init gives the instance a new machine ID after journald has started, so journald keeps
    # writing under the old ID and plain journalctl (current machine only) finds no files
    if ls /var/log/journal/*/*.journal > /dev/null 2>&1; then
        JOURNAL="journalctl --no-pager --file='/var/log/journal/*/*.journal'"
    else
        JOURNAL="journalctl --no-pager -m"
    fi
    run 'cat /etc/machine-id; ls -la /var/log/journal /run/log/journal'
    run "${JOURNAL} --list-boots | tail -20"
    run 'for f in /proc/pressure/*; do echo "$f"; cat "$f"; done'
    run 'free -m; swapon --show; sysctl vm.swappiness'
    run 'df -h; df -i'
    run 'ps aux --sort=-%mem | head -25'
    run 'ps aux --sort=-%cpu | head -15'
    run 'ps -eo pid,ppid,stat,etime,wchan:32,cmd | awk "NR==1 || \$3 ~ /^[DZ]/"'
    run 'systemctl status gitlab-runner docker containerd amazon-ssm-agent cfn-hup publish-runner-metrics.timer --no-pager -l'
    run 'systemctl list-units --failed --no-pager'
    run 'systemctl cat gitlab-runner --no-pager'
    run 'gitlab-runner --version'
    run 'sed -E "s/^([[:space:]]*token[[:space:]]*=).*/\1 \"REDACTED\"/" /etc/gitlab-runner/config.toml'
    run 'ls -la /etc/gitlab-runner'
    run 'gitlab-runner list'
    run 'gitlab-runner verify' 90
    RUNNER_PID=$(systemctl show -p MainPID --value gitlab-runner)
    run "echo pid=${RUNNER_PID}; ps -o pid,stat,etime,rss,vsz,nlwp,cmd -p ${RUNNER_PID}; ls /proc/${RUNNER_PID}/fd | wc -l; cat /proc/${RUNNER_PID}/limits"
    run 'curl -sS --max-time 20 http://127.0.0.1:9252/metrics | grep -v "^#" | grep -E "^(gitlab_runner_|process_|go_goroutines)"'
    run 'curl -sS --max-time 20 http://127.0.0.1:9252/debug/jobs/list'
    run 'curl -sS --max-time 30 "http://127.0.0.1:9252/debug/pprof/goroutine?debug=2"'
    GITLAB_URL=$(grep -m1 -E "^[[:space:]]*url[[:space:]]*=" /etc/gitlab-runner/config.toml | sed -E "s/.*=[[:space:]]*\"(.*)\".*/\1/")
    run "for u in ${GITLAB_URL:-https://gitlab.com}/api/v4/version https://registry.gitlab.com/v2/; do curl -sS -o /dev/null --max-time 20 -w \"\$u http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n\" \"\$u\"; done"
    run 'cat /etc/resolv.conf; ip -brief addr; ip route'
    run 'timedatectl; chronyc tracking'
    run 'ss -s; ss -tnp | grep -E "gitlab-runner|dockerd" | head -50'
    run 'docker version' 30
    run 'docker info' 30
    run 'docker ps -a --no-trunc --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.CreatedAt}}\t{{.Names}}"' 30
    run 'for c in $(docker ps -aq --filter name=runner- | head -40); do docker inspect --format "{{.Name}} status={{.State.Status}} running={{.State.Running}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} error={{.State.Error}}" "$c"; done' 60
    run 'docker stats --no-stream' 45
    run 'docker system df' 60
    run 'docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}"' 30
    run 'docker volume ls -q | wc -l; docker network ls' 30
    run 'dmesg -T | grep -iE "oom|killed process|out of memory|hung_task|blocked for more than|segfault|i/o error|xfs|ext4" | tail -200'
    run "${JOURNAL} -k --since -${HOURS}h | tail -n 1000"
    run "${JOURNAL} -u publish-runner-metrics.service --since -${HOURS}h | grep -v -E 'Starting|Finished|Deactivated|Consumed' | tail -n 200"
    run "${JOURNAL} -u docker --since -${HOURS}h | tail -n 3000"
    run "${JOURNAL} -p warning --since -${HOURS}h | grep -v -E 'gitlab-runner|dockerd' | tail -n 1000"
    run 'tail -n 200 /var/log/cfn-init.log; tail -n 300 /var/log/cfn-init-cmd.log'
    run "${JOURNAL} -u gitlab-runner --since -${HOURS}h -o short-iso | tail -n 30000" 120
}
collect 2>&1 | sed -E \
    -e 's/(glrt|glpat|gldt|glcbt|glptt|GR1348941)[A-Za-z0-9_.-]{8,}/\1-REDACTED/g' \
    -e 's/([Tt]oken[" ]*[=:][" ]*)[A-Za-z0-9_.-]{8,}/\1REDACTED/g'
INSTANCE_SCRIPT
instance_script=${instance_script//__HOURS__/${hours}}

online_ids=""
if [[ -n "${instance_ids}" ]]; then
    for instance_id in ${instance_ids}; do
        ping=$(awsr ssm describe-instance-information --filters "Key=InstanceIds,Values=${instance_id}" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2> /dev/null)
        if [[ "${ping}" == "Online" ]]; then
            online_ids="${online_ids} ${instance_id}"
        else
            echo "SSM agent ping status: ${ping:-unknown}. On-instance diagnostics could not be collected." \
                > "${out_dir}/instances/${instance_id}/ssm-unavailable.txt"
            echo "    ! ${instance_id} is not reachable through SSM (${ping:-unknown}); see its console output"
        fi
    done
fi

if [[ -n "${online_ids}" ]]; then
    echo "==> Running diagnostics on instances:${online_ids}"
    encoded=$(printf '%s\n' "${instance_script}" | base64 | tr -d '\n')
    ids_json=$(echo ${online_ids} | sed -E 's/([^ ]+)/"\1"/g; s/ /,/g')
    # A log group of its own, so diagnostics runs don't mix with the graceful shutdown output
    diagnostics_log_group="/${stack_name}/diagnostics"
    awsr logs create-log-group --log-group-name "${diagnostics_log_group}" > /dev/null 2>&1
    awsr logs put-retention-policy --log-group-name "${diagnostics_log_group}" --retention-in-days 7 > /dev/null 2>&1
    output_config=", \"CloudWatchOutputConfig\": {\"CloudWatchOutputEnabled\": true, \"CloudWatchLogGroupName\": \"${diagnostics_log_group}\"}"
    input_file=$(mktemp)
    printf '{"DocumentName": "AWS-RunShellScript", "Comment": "collect-runner-diagnostics", "InstanceIds": [%s], "TimeoutSeconds": 600, "Parameters": {"commands": ["echo %s | base64 -d | bash"], "executionTimeout": ["900"]}%s}' \
        "${ids_json}" "${encoded}" "${output_config}" > "${input_file}"
    command_id=$(awsr ssm send-command --cli-input-json "file://${input_file}" --query Command.CommandId --output text 2> "${out_dir}/instances/send-command-error.txt")
    rm -f "${input_file}"

    if [[ -z "${command_id}" || "${command_id}" == "None" ]]; then
        echo "    ! send-command failed; see instances/send-command-error.txt"
    else
        rm -f "${out_dir}/instances/send-command-error.txt"
        echo "    Command ${command_id}; waiting for it to finish (up to 15 minutes)..."
        for _ in $(seq 1 180); do
            pending=$(awsr ssm list-command-invocations --command-id "${command_id}" \
                --query 'length(CommandInvocations[?Status==`Pending` || Status==`InProgress` || Status==`Delayed`])' --output text 2> /dev/null)
            [[ "${pending}" == "0" ]] && break
            sleep 5
        done

        for instance_id in ${online_ids}; do
            dir="${out_dir}/instances/${instance_id}"
            capture "instances/${instance_id}/command-invocation.json" ssm get-command-invocation \
                --command-id "${command_id}" --instance-id "${instance_id}" \
                --query '{Status:Status,StatusDetails:StatusDetails,ResponseCode:ResponseCode,StandardErrorContent:StandardErrorContent}'
            stream="${command_id}/${instance_id}/aws-runShellScript/stdout"
            fetched=""
            # CloudWatch delivery can lag a little behind command completion
            for _ in $(seq 1 12); do
                exists=$(awsr logs describe-log-streams --log-group-name "${diagnostics_log_group}" \
                    --log-stream-name-prefix "${stream}" --query 'length(logStreams)' --output text 2> /dev/null)
                [[ "${exists}" == "1" ]] && break
                sleep 5
            done
            sleep 5
            awsr logs filter-log-events --log-group-name "${diagnostics_log_group}" --log-stream-names "${stream}" \
                --query 'events[].[message]' --output text > "${dir}/diagnostics.txt" 2>&1 \
                && [[ -s "${dir}/diagnostics.txt" ]] && fetched=yes
            if [[ -z "${fetched}" ]]; then
                echo "    ! full output for ${instance_id} was not in CloudWatch Logs; saving the truncated Run Command output"
                awsr ssm get-command-invocation --command-id "${command_id}" --instance-id "${instance_id}" \
                    --query StandardOutputContent --output text > "${dir}/diagnostics-truncated.txt" 2>&1
            fi
        done
    fi
fi

#
# GitLab side (optional)
#

if [[ -n "${GITLAB_TOKEN:-}" ]]; then
    echo "==> GitLab runners"
    gitlab_url=$(awsr cloudformation describe-stacks --stack-name "${stack_name}" \
        --query "Stacks[0].Parameters[?ParameterKey=='GitlabServerURL'].ParameterValue" --output text 2> /dev/null)
    gitlab_url=${gitlab_url:-https://gitlab.com}
    runner_ids=$(cat "${out_dir}"/instances/*/diagnostics*.txt 2> /dev/null \
        | grep -E '^[[:space:]]*id[[:space:]]*=[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -u)
    mkdir -p "${out_dir}/gitlab"
    for runner_id in ${runner_ids}; do
        for endpoint in "runners/${runner_id}" "runners/${runner_id}/managers" "runners/${runner_id}/jobs?per_page=30&order_by=id&sort=desc"; do
            file="${out_dir}/gitlab/$(echo "${endpoint}" | sed -E 's/\?.*//; s#/#-#g').json"
            echo "    ${endpoint}"
            curl -sS --max-time 30 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -w '\n# http %{http_code}\n' \
                "${gitlab_url}/api/v4/${endpoint}" > "${file}" 2>&1
        done
    done
    [[ -z "${runner_ids}" ]] && echo "    ! no runner ids found in the instances' config.toml"
fi

#
# Wrap up
#

# Second pass in case a token reached a file through a path that wasn't filtered
find "${out_dir}" -type f \( -name '*.txt' -o -name '*.json' \) | while read -r file; do
    redact < "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
done

cat > "${out_dir}/README.txt" <<EOF
GitLab Runner diagnostics
Stack:      ${stack_name}
Region:     ${region}
Collected:  $(date -u +%Y-%m-%dT%H:%M:%SZ)
Window:     last ${hours} hours
Instances:  ${instance_ids:-none}
SSM online: ${online_ids:- none}

aws/        stack, autoscaling group, instances, Lambda and SSM state
logs/       runner monitor Lambda, lifecycle hook Lambda and graceful shutdown document
metrics/    runner job counts, capacity, and per-instance CPU, credits and status checks
instances/  per instance: diagnostics.txt (collected on the instance), console output
gitlab/     runner status and jobs from the GitLab API (only when GITLAB_TOKEN was set)
EOF

archive="${out_dir}.tar.gz"
tar -czf "${archive}" -C "$(dirname "${out_dir}")" "$(basename "${out_dir}")"

echo
echo "Done. Diagnostics are in:"
echo "    $(pwd)/${out_dir}"
echo "    $(pwd)/${archive}"
echo "Tokens were redacted, but look through the files before sharing them outside your team."
