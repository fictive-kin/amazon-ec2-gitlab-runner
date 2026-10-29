#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Live view of a deployed runner stack: autoscaling capacity, each instance's running job count
# from CloudWatch, and (with a GitLab token) the jobs the runner is running right now.

set -uo pipefail

export AWS_PAGER=""

# Loads KEY=VALUE lines, such as GITLAB_TOKEN, from .env next to this script. A variable already
# set in the environment wins. The file is read, not sourced, so it can't run commands.
load_env() {
    local file line key value
    file="$(dirname "$0")/.env"
    [[ -f "${file}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line%$'\r'}
        [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key=${BASH_REMATCH[2]}
        value=${BASH_REMATCH[3]}
        if [[ "${value}" =~ ^\"(.*)\"[[:space:]]*$ || "${value}" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
            value=${BASH_REMATCH[1]}
        else
            # Unquoted: drop a trailing " # comment" and trailing whitespace
            value=${value%%[[:space:]]#*}
            value=${value%"${value##*[![:space:]]}"}
        fi
        [[ -n "${!key+set}" ]] || export "${key}=${value}"
    done < "${file}"
}
load_env

is_region() {
    [[ "$1" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]
}

# Splits the optional <region> [<aws-profile>] arguments. A lone one that looks like a region
# (us-east-1) is the region; anything else is the profile.
split_region_and_profile() {
    region=""
    profile=""
    if [[ "$#" -eq 2 ]]; then
        is_region "$1" || { echo "Not an AWS region: $1" >&2; exit 1; }
        region=$1
        profile=$2
    elif [[ "$#" -eq 1 ]]; then
        if is_region "$1"; then region=$1; else profile=$1; fi
    fi
}

# Without a region argument: AWS_REGION, AWS_DEFAULT_REGION or the profile's configured region,
# as the AWS CLI would use, else asks for one
resolve_region() {
    [[ -n "${region}" ]] && return 0
    region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
    [[ -n "${region}" ]] || region=$(aws configure get region ${profile:+--profile "${profile}"} 2> /dev/null || true)
    until is_region "${region}"; do
        if [[ ! -t 0 ]]; then
            echo "No AWS region: pass one, or set AWS_REGION or AWS_DEFAULT_REGION" >&2
            exit 1
        fi
        read -r -p "AWS region (e.g. us-east-1): " region || exit 1
    done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <stack-name> [<region>] [<aws-profile>] [--interval <seconds>] [--once] [--runner-id <id>]

Refreshes a view of the runner stack until you press Ctrl-C:
  - desired, minimum and maximum capacity of the autoscaling group
  - the total job count, the jobs waiting in GitLab (with GitlabRunnerIds and a GitLab API
    token configured) and the target capacity published by the runner monitor Lambda
  - each instance: lifecycle state, health, IP, CPU, memory and swap use, memory pressure (PSI:
    % of the last 10s in which every task waited for memory; high means thrashing) and its
    latest job count. An instance whose count is more than 3 minutes old is shown as stale;
    the monitor replaces it after 5
  - with GITLAB_TOKEN set, the runner's running jobs: project, job, stage, how long it has
    run, which instance runs it, and its link

The CloudWatch counts lag by up to a minute; the GitLab list is current.

Arguments:
  stack-name            CloudFormation stack name
  region                Optional AWS region of the stack, e.g. us-east-1. Without it,
                        AWS_REGION, AWS_DEFAULT_REGION or the profile's configured region
                        is used, and you're asked for one if none is set
  aws-profile           Optional AWS CLI profile. Without it, the AWS CLI's default
                        credentials are used. Given alone, an argument that looks like a
                        region (us-east-1) is the region and anything else the profile

Options:
  --interval <seconds>  Time between refreshes (default 15)
  --once                Print the view once and exit
  --runner-id <id>      GitLab runner ID(s), comma separated. Without it, the IDs are read
                        once from an instance's config.toml through SSM
  -h, --help, -?        Show this help and exit

Environment (also read from .env next to this script; a variable already set wins):
  GITLAB_TOKEN          Optional GitLab access token that can read the runner's jobs
  GITLAB_RUNNER_ID      Same as --runner-id
EOF
}

interval=15
once=""
runner_ids=${GITLAB_RUNNER_ID:-}
positional=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help|-\?) usage; exit 0 ;;
        --interval)
            [[ "${2:-}" =~ ^[0-9]+$ && "$2" -gt 0 ]] || { echo "--interval needs a positive number" >&2; exit 1; }
            interval=$2
            shift 2
            ;;
        --once) once=yes; shift ;;
        --runner-id)
            [[ "${2:-}" =~ ^[0-9,]+$ ]] || { echo "--runner-id needs a number or comma separated numbers" >&2; exit 1; }
            runner_ids=$2
            shift 2
            ;;
        -*) echo "Unknown option: $1" >&2; echo "Run '$(basename "$0") --help' for usage." >&2; exit 1 ;;
        *) positional+=("$1"); shift ;;
    esac
done

if [[ "${#positional[@]}" -lt 1 || "${#positional[@]}" -gt 3 ]]
then
    echo "Incorrect number of arguments" >&2
    echo "Usage: $(basename "$0") <stack-name> [<region>] [<aws-profile>] [--interval <seconds>] [--once] [--runner-id <id>]" >&2
    echo "Run '$(basename "$0") --help' for details." >&2
    exit 1
fi

command -v jq > /dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

stack_name=${positional[0]}
split_region_and_profile "${positional[@]:1}"
resolve_region
profile_args=()
if [[ -n "${profile}" ]]; then
    profile_args=(--profile "${profile}")
fi

asg_name="${stack_name}-asg"
metric_namespace="${stack_name}-runner-metrics"
stale_after_seconds=180

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RESET=$(printf '\033[0m')
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

TEMP_DIR=$(mktemp -d)
chmod 700 "${TEMP_DIR}"
trap 'rm -rf "${TEMP_DIR}"' EXIT
trap 'exit 0' INT TERM

awsr() {
    aws ${profile_args[@]+"${profile_args[@]}"} --region "${region}" "$@"
}

# jq: ISO 8601 timestamp with fractional seconds and any UTC offset (AWS returns local offsets
# such as -04:00, GitLab returns Z) -> epoch seconds. Computed by hand because jq 1.6 on macOS
# is an hour off in fromdateiso8601 and mktime during daylight saving time.
JQ_EPOCH='def epoch:
    capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})?$")
    | (.mo | tonumber) as $m | (.d | tonumber) as $d
    | ((.y | tonumber) - (if $m <= 2 then 1 else 0 end)) as $y
    | (($y / 400) | floor) as $era | ($y - $era * 400) as $yoe
    | (((153 * ($m + (if $m > 2 then -3 else 9 end)) + 2) / 5 | floor) + $d - 1) as $doy
    | ($era * 146097 + $yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy - 719468) as $days
    | (if (.tz // "Z") == "Z" then 0
       else (.tz | ltrimstr("+") | ltrimstr("-") | sub(":"; "")) as $o
         | (if (.tz | startswith("-")) then -1 else 1 end) * (($o[0:2] | tonumber) * 3600 + ($o[2:4] | tonumber) * 60)
       end) as $offset
    | $days * 86400 + (.h | tonumber) * 3600 + (.mi | tonumber) * 60 + (.s | tonumber) - $offset;'

# pad <width> <text> [color]  -> text padded to width, then colored, so colors don't break alignment
pad() {
    local padded
    printf -v padded "%-$1s" "$2"
    echo -n "${3:-}${padded}${3:+${RESET}}"
}

#
# One-time setup: GitLab URL, token config and runner IDs
#

gitlab_url=""
if [[ -n "${GITLAB_TOKEN:-}" ]]; then
    gitlab_url=$(awsr cloudformation describe-stacks --stack-name "${stack_name}" \
        --query "Stacks[0].Parameters[?ParameterKey=='GitlabServerURL'].ParameterValue" --output text 2> /dev/null)
    [[ -z "${gitlab_url}" || "${gitlab_url}" == "None" ]] && gitlab_url="https://gitlab.com"
    gitlab_url=${gitlab_url%/}

    # Pass the token in a curl config file so it doesn't appear in the process list
    printf 'header = "PRIVATE-TOKEN: %s"\n' "${GITLAB_TOKEN}" > "${TEMP_DIR}/gitlab-auth"
    chmod 600 "${TEMP_DIR}/gitlab-auth"

    if [[ -z "${runner_ids}" ]]; then
        echo "Looking up the runner ID from an instance's config.toml (pass --runner-id to skip this)..."
        instance_id=$(awsr autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${asg_name}" \
            --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" --output text 2> /dev/null)
        if [[ -n "${instance_id}" && "${instance_id}" != "None" ]]; then
            command_id=$(awsr ssm send-command --instance-ids "${instance_id}" --document-name AWS-RunShellScript \
                --comment "watch-runner-jobs: read runner IDs" \
                --parameters '{"commands": ["grep -E \"^[[:space:]]*id[[:space:]]*=\" /etc/gitlab-runner/config.toml"]}' \
                --query Command.CommandId --output text 2> /dev/null)
            for _ in $(seq 1 15); do
                sleep 2
                output=$(awsr ssm get-command-invocation --command-id "${command_id}" --instance-id "${instance_id}" \
                    --query '[Status,StandardOutputContent]' --output text 2> /dev/null)
                case "${output}" in
                    Success*) runner_ids=$(echo "${output}" | grep -oE '[0-9]+' | sort -u | paste -sd, -); break ;;
                    Pending*|InProgress*|Delayed*|"") ;;
                    *) break ;;
                esac
            done
        fi
        if [[ -n "${runner_ids}" ]]; then
            echo "Runner ID: ${runner_ids}. Pass --runner-id ${runner_ids} next time to skip the lookup."
        else
            echo "${YELLOW}Could not read the runner ID through SSM; GitLab jobs won't be shown. Pass --runner-id.${RESET}"
        fi
    fi
fi

#
# Refresh
#

# metric_queries <instance-id>...  -> MetricDataQueries JSON for the cluster and each instance.
# Instance query IDs are a metric letter and the instance's index: j0 (jobs), c0 (CPU), m0 (memory),
# s0 (swap), p0 (memory pressure).
metric_queries() {
    jq -n --arg ns "${metric_namespace}" --arg stack "${stack_name}" --arg asg "${asg_name}" \
        --argjson ids "$(printf '%s\n' "$@" | jq -R . | jq -s 'map(select(. != ""))')" '
        def query($id; $name; $dims): {Id: $id, MetricStat: {Metric: {Namespace: $ns, MetricName: $name, Dimensions: $dims}, Period: 60, Stat: "Maximum"}};
        [query("jobs"; "\($stack)-job-count"; []),
         query("pending"; "\($stack)-pending-job-count"; []),
         query("target"; "\($stack)-target-capacity"; [])]
        + ($ids | to_entries | map(
            [{Name: "AutoScalingGroupName", Value: $asg}, {Name: "InstanceId", Value: .value}] as $dims
            | .key as $i
            | {j: "job-count", c: "cpu", m: "memory", s: "swap", p: "memory-pressure"} | to_entries
            | map(query("\(.key)\($i)"; "\($stack)-instance-\(.value)"; $dims))) | add // [])'
}

# percent_cell <value> <warn> <alert>  -> value as a whole percent, yellow from warn and red from alert
percent_cell() {
    [[ -z "$1" ]] && { pad 6 "-"; return; }
    local whole=${1%.*} color=""
    [[ "${whole}" -ge "$2" ]] && color=${YELLOW}
    [[ "${whole}" -ge "$3" ]] && color=${RED}
    pad 6 "${whole}%" "${color}"
}

render() {
    local now asg instances instance_ids metrics jobs_file
    now=$(date +%s)

    asg=$(awsr autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${asg_name}" \
        --query 'AutoScalingGroups[0]' --output json 2> "${TEMP_DIR}/error") \
        || { echo "${RED}Could not describe ${asg_name}:${RESET} $(cat "${TEMP_DIR}/error")"; return; }
    [[ "${asg}" == "null" ]] && { echo "${RED}Autoscaling group ${asg_name} not found${RESET}"; return; }
    instance_ids=$(echo "${asg}" | jq -r '.Instances[].InstanceId')

    instances='{"Reservations": []}'
    if [[ -n "${instance_ids}" ]]; then
        # shellcheck disable=SC2086
        instances=$(awsr ec2 describe-instances --instance-ids ${instance_ids} --output json 2> /dev/null || echo '{"Reservations": []}')
    fi

    metric_queries ${instance_ids} > "${TEMP_DIR}/queries.json"
    metrics=$(awsr cloudwatch get-metric-data --metric-data-queries "file://${TEMP_DIR}/queries.json" \
        --start-time $((now - 600)) --end-time "${now}" --scan-by TimestampDescending --output json 2> /dev/null \
        || echo '{"MetricDataResults": []}')

    # latest <query-id>  -> "<value> <epoch>" or empty
    latest() {
        echo "${metrics}" | jq -r --arg id "$1" "${JQ_EPOCH}"' .MetricDataResults[] | select(.Id == $id)
            | select((.Values | length) > 0)
            | "\(.Values[0]) \(.Timestamps[0] | epoch)"' 2> /dev/null
    }

    local total pending target
    total=$(latest jobs | cut -d' ' -f1)
    # Only published when the monitor could count them; "-" means no token or runner IDs, or a GitLab API error
    pending=$(latest pending | cut -d' ' -f1)
    target=$(latest target | cut -d' ' -f1)

    echo "${BOLD}${stack_name}${RESET}  ${DIM}$(date '+%H:%M:%S')${RESET}"
    echo "Capacity  desired $(echo "${asg}" | jq -r .DesiredCapacity)  min $(echo "${asg}" | jq -r .MinSize)  max $(echo "${asg}" | jq -r .MaxSize)  target ${target:--}    Running jobs (CloudWatch) ${BOLD}${total:--}${RESET}  Waiting ${BOLD}${pending:--}${RESET}"
    echo

    echo "${BOLD}$(pad 21 INSTANCE) $(pad 20 STATE) $(pad 10 HEALTH) $(pad 16 IP) $(pad 8 UP) $(pad 6 CPU) $(pad 6 MEM) $(pad 6 SWAP) $(pad 6 PSI) JOBS${RESET}"
    if [[ -z "${instance_ids}" ]]; then
        echo "${DIM}(no instances)${RESET}"
    fi
    local index=0 id state health ip launch up value stamp age state_color health_color jobs_cell resources
    for id in ${instance_ids}; do
        state=$(echo "${asg}" | jq -r --arg id "${id}" '.Instances[] | select(.InstanceId == $id) | .LifecycleState')
        health=$(echo "${asg}" | jq -r --arg id "${id}" '.Instances[] | select(.InstanceId == $id) | .HealthStatus')
        ip=$(echo "${instances}" | jq -r --arg id "${id}" '.Reservations[].Instances[] | select(.InstanceId == $id) | .PublicIpAddress // .PrivateIpAddress // "-"')
        launch=$(echo "${instances}" | jq -r --arg id "${id}" "${JQ_EPOCH}"' .Reservations[].Instances[] | select(.InstanceId == $id) | .LaunchTime | epoch' 2> /dev/null)
        up="-"
        [[ -n "${launch}" ]] && up=$(format_duration $((now - launch)))

        read -r value stamp <<< "$(latest "j${index}")"
        if [[ -z "${value:-}" ]]; then
            jobs_cell="${DIM}no data${RESET}"
        else
            age=$((now - ${stamp%.*}))
            jobs_cell="${value%.0}"
            if [[ "${age}" -gt "${stale_after_seconds}" ]]; then
                jobs_cell="${YELLOW}stale $(format_duration "${age}")${RESET}"
            fi
        fi
        state_color=""; health_color=""
        [[ "${state}" == "InService" ]] && state_color=${GREEN}
        [[ "${health}" != "Healthy" ]] && health_color=${RED}
        resources="$(percent_cell "$(latest "c${index}" | cut -d' ' -f1)" 90 101) $(percent_cell "$(latest "m${index}" | cut -d' ' -f1)" 85 95)"
        resources+=" $(percent_cell "$(latest "s${index}" | cut -d' ' -f1)" 25 50) $(percent_cell "$(latest "p${index}" | cut -d' ' -f1)" 10 30)"
        echo "$(pad 21 "${id}") $(pad 20 "${state}" "${state_color}") $(pad 10 "${health}" "${health_color}") $(pad 16 "${ip}") $(pad 8 "${up}") ${resources} ${jobs_cell}"
        index=$((index + 1))
    done

    [[ -z "${GITLAB_TOKEN:-}" ]] && { echo; echo "${DIM}Set GITLAB_TOKEN to list the running jobs from GitLab.${RESET}"; return; }
    [[ -z "${runner_ids}" ]] && return

    echo
    jobs_file="${TEMP_DIR}/jobs.json"
    echo '[]' > "${jobs_file}"
    local runner_id status fetched=""
    for runner_id in ${runner_ids//,/ }; do
        status=$(curl -sS --max-time 20 -K "${TEMP_DIR}/gitlab-auth" -o "${TEMP_DIR}/runner-jobs.json" -w '%{http_code}' \
            "${gitlab_url}/api/v4/runners/${runner_id}/jobs?status=running&per_page=100" 2> "${TEMP_DIR}/error")
        if [[ "${status}" != "200" ]]; then
            echo "${RED}GitLab returned ${status:-no response} for runner ${runner_id}:${RESET} $(jq -r '.message // .error // empty | tostring' "${TEMP_DIR}/runner-jobs.json" 2> /dev/null || cat "${TEMP_DIR}/error")"
            continue
        fi
        jq -s 'add' "${jobs_file}" "${TEMP_DIR}/runner-jobs.json" > "${jobs_file}.tmp" && mv "${jobs_file}.tmp" "${jobs_file}"
        fetched=yes
    done
    [[ -z "${fetched}" ]] && return

    # Map the runner manager's IP address, as GitLab sees it, back to an instance
    local ip_map
    ip_map=$(echo "${instances}" | jq -c '[.Reservations[].Instances[] | {key: (.PublicIpAddress // .PrivateIpAddress // ""), value: .InstanceId}, {key: (.PrivateIpAddress // ""), value: .InstanceId}] | map(select(.key != "")) | from_entries')

    echo "${BOLD}Running jobs (GitLab): $(jq length "${jobs_file}")${RESET}"
    jq -r --argjson now "${now}" --argjson ips "${ip_map}" "${JQ_EPOCH}"'
        def elapsed($s): if $s == null then "-" else
            ($now - ($s | epoch) | floor) as $d
            | if $d >= 3600 then "\($d / 3600 | floor)h\($d % 3600 / 60 | floor)m" elif $d >= 60 then "\($d / 60 | floor)m\($d % 60)s" else "\($d)s" end end;
        sort_by(.started_at) | .[]
        | [(.project.path_with_namespace // .project.name // "-"),
           "\(.name) (\(.stage))",
           (.ref // .pipeline.ref // "-"),
           elapsed(.started_at),
           ($ips[.runner_manager.ip_address // ""] // .runner_manager.ip_address // "-"),
           .web_url] | @tsv' "${jobs_file}" \
        | awk -F'\t' 'BEGIN { printf "%-34s %-34s %-18s %-8s %-21s %s\n", "PROJECT", "JOB (STAGE)", "REF", "RUNNING", "INSTANCE", "URL" }
            { printf "%-34.34s %-34.34s %-18.18s %-8s %-21s %s\n", $1, $2, $3, $4, $5, $6 }'
}

format_duration() {
    local s=$1
    if [[ "${s}" -ge 86400 ]]; then echo "$((s / 86400))d$((s % 86400 / 3600))h"
    elif [[ "${s}" -ge 3600 ]]; then echo "$((s / 3600))h$((s % 3600 / 60))m"
    elif [[ "${s}" -ge 60 ]]; then echo "$((s / 60))m$((s % 60))s"
    else echo "${s}s"
    fi
}

if [[ -n "${once}" ]]; then
    render
    exit 0
fi

while true; do
    # Render off screen first so the view doesn't flicker while the AWS calls run
    output=$(render)
    [ -t 1 ] && printf '\033[H\033[2J'
    echo "${output}"
    echo
    echo "${DIM}Refreshing every ${interval}s. Ctrl-C to stop.${RESET}"
    sleep "${interval}"
done
