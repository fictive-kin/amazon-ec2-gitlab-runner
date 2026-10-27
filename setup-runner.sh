#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Interactive end-to-end setup: checks prerequisites, gathers settings (inferring what it can
# from AWS and GitLab), builds the executor image, writes a properties file and runs
# deploy-runner.sh. Safe to re-run; an existing properties file for the stack is reused.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help|-?]

Interactive setup that takes a GitLab Runner stack from nothing to deployed:
  - checks local tools and AWS credentials
  - infers the GitLab project and stack name from the git remote (both can be changed)
  - creates the GitLab runner through the API, or prints the manual steps and asks for its token
  - builds and pushes the executor image for linux/amd64
  - lists VPCs and subnets, labelled public or private-nat, for you to pick from
  - creates the Lambda S3 bucket and the Auto Scaling service-linked role if missing
  - writes <stack-name>.properties and runs deploy-runner.sh

Every value is prompted for, with a default shown in [brackets]. Re-running for an existing
stack reuses its properties file and can keep the runner tokens already stored in SSM.

Optional, prompted for during the run:
  AWS profile               Leave empty to use the AWS CLI's default credentials
                            (environment variables, AWS_PROFILE or the default profile)
  GitLab access token       A fine-grained personal access token with Project: Read on the
                            project and Runner: Create; lets the script look up the project
                            and create the runner for you
  Registry deploy token     A project deploy token with the write_registry scope, to push
                            the executor image (fine-grained tokens can't push images)

Options:
  -h, --help, -?            Show this help and exit
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help|-\?) usage; exit 0 ;;
        *) echo "Unknown argument: ${arg}" >&2; echo "Run '$(basename "$0") --help' for usage." >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")"

export AWS_PAGER=""

# Lambda function names are "<stack>-asg-lifecycle-hook" and must fit in 64 characters
MAX_STACK_NAME_LENGTH=45

TEMP_DIR=$(mktemp -d)
chmod 700 "${TEMP_DIR}"
trap 'rm -rf "${TEMP_DIR}"' EXIT

#
# Output and prompt helpers
#

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); CYAN=$(printf '\033[36m'); RESET=$(printf '\033[0m')
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

step()  { echo; echo "${BOLD}${CYAN}==> $*${RESET}"; }
info()  { echo "    $*"; }
ok()    { echo "    ${GREEN}✓${RESET} $*"; }
warn()  { echo "    ${YELLOW}!${RESET} $*"; }
die()   { echo; echo "${RED}Error:${RESET} $*" >&2; exit 1; }

# ask VAR "Question" "default"
ask() {
    local answer
    if [ -n "${3:-}" ]; then
        read -r -p "    $2 [${3}]: " answer
        answer=${answer:-$3}
    else
        read -r -p "    $2: " answer
    fi
    printf -v "$1" '%s' "${answer}"
}

# ask_secret VAR "Question"  (input is not echoed)
ask_secret() {
    local answer
    read -r -s -p "    $2: " answer
    echo
    printf -v "$1" '%s' "${answer}"
}

# confirm "Question" y|n  -> exit status 0 for yes
confirm() {
    local answer hint="[y/N]"
    [ "$2" = "y" ] && hint="[Y/n]"
    read -r -p "    $1 ${hint}: " answer
    answer=$(echo "${answer:-$2}" | tr '[:upper:]' '[:lower:]')
    [ "${answer}" = "y" ] || [ "${answer}" = "yes" ]
}

# manual_step "Title" "line" "line" ...  -> prints instructions and waits for Enter
manual_step() {
    local title=$1
    shift
    echo
    echo "    ${BOLD}${YELLOW}MANUAL STEP: ${title}${RESET}"
    local n=1
    for line in "$@"; do
        echo "      ${n}. ${line}"
        n=$((n + 1))
    done
    echo
    read -r -p "    Press Enter when done... " _
}

# Without a profile, the AWS CLI's default credential chain applies (environment variables,
# AWS_PROFILE, the default profile, or an instance role). Passing --profile would skip the
# environment variables, so it is only added when a profile was chosen.
AWS_PROFILE_ARGS=()

aws_cli() {
    aws ${AWS_PROFILE_ARGS[@]+"${AWS_PROFILE_ARGS[@]}"} --region "${AWS_REGION_NAME}" "$@"
}

# " --profile <name>" or "", for printing commands the user can copy
profile_suffix() {
    [ -n "${AWS_PROFILE_NAME}" ] && echo " --profile ${AWS_PROFILE_NAME}"
    return 0
}

# The deploy-runner.sh command line for this stack
deploy_command() {
    if [ -n "${AWS_PROFILE_NAME}" ]; then
        echo "./deploy-runner.sh ${PROPERTIES_FILE} ${AWS_REGION_NAME} ${AWS_PROFILE_NAME} ${STACK_NAME}"
    else
        echo "./deploy-runner.sh ${PROPERTIES_FILE} ${AWS_REGION_NAME} ${STACK_NAME}"
    fi
}

# gitlab_api METHOD PATH [curl args...]  -> response body on stdout
# The access token is passed in a header file so it doesn't appear in the process list.
gitlab_api() {
    local method=$1 path=$2
    shift 2
    local args=(-sS -f -X "${method}")
    if [ -n "${GITLAB_TOKEN}" ]; then
        args+=(-H "@${TEMP_DIR}/gitlab-auth-header")
    fi
    curl "${args[@]}" "$@" "${GITLAB_URL}/api/v4${path}"
}

#
# Steps
#

check_prerequisites() {
    step "Checking local tools"
    local missing=()
    for tool in aws docker node npm zip curl jq git; do
        command -v "${tool}" > /dev/null 2>&1 || missing+=("${tool}")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required tools: ${missing[*]}. Install them and re-run this script."
    fi
    aws --version 2>&1 | grep -q "aws-cli/2" \
        || die "AWS CLI v2 is required (found: $(aws --version 2>&1)). See https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    docker buildx version > /dev/null 2>&1 \
        || die "Docker buildx is required to build the x86 executor image."
    docker info > /dev/null 2>&1 \
        || die "Docker is installed but not running. Start Docker and re-run this script."
    ok "aws, docker (buildx), node, npm, zip, curl, jq and git are available"
}

configure_aws() {
    step "AWS account"
    info "Leave the profile empty to use AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY from the environment,"
    info "AWS_PROFILE, or the default profile."
    ask AWS_PROFILE_NAME "AWS CLI profile (optional)" ""
    if [ -n "${AWS_PROFILE_NAME}" ]; then
        AWS_PROFILE_ARGS=(--profile "${AWS_PROFILE_NAME}")
    fi
    local default_region
    default_region=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region ${AWS_PROFILE_ARGS[@]+"${AWS_PROFILE_ARGS[@]}"} 2> /dev/null || true)}}
    ask AWS_REGION_NAME "AWS region" "${default_region:-us-east-1}"

    if ! AWS_ACCOUNT_ID=$(aws_cli sts get-caller-identity --query Account --output text 2> /dev/null); then
        if [ -n "${AWS_PROFILE_NAME}" ]; then
            manual_step "Sign in to AWS" \
                "In another terminal, configure credentials for profile '${AWS_PROFILE_NAME}': 'aws configure --profile ${AWS_PROFILE_NAME}' (access key) or 'aws configure sso --profile ${AWS_PROFILE_NAME}' (SSO)" \
                "If the profile already uses SSO, run 'aws sso login --profile ${AWS_PROFILE_NAME}'"
        else
            manual_step "Sign in to AWS" \
                "No credentials were found in the environment or the default profile." \
                "In another terminal, run 'aws configure' to save an access key to the default profile (or 'aws configure sso' for SSO)." \
                "Environment variables set in another terminal don't reach this script; to use them, press Ctrl+C, export them here, and re-run."
        fi
        AWS_ACCOUNT_ID=$(aws_cli sts get-caller-identity --query Account --output text) \
            || die "Still unable to authenticate with AWS."
    fi
    local identity
    identity=$(aws_cli sts get-caller-identity --query Arn --output text 2> /dev/null || true)
    ok "Using account ${AWS_ACCOUNT_ID} in ${AWS_REGION_NAME} as ${identity}"
}

# Sets REMOTE_HOST and REMOTE_PATH from the git origin remote, if it looks like a GitLab project
infer_from_git_remote() {
    REMOTE_HOST=""
    REMOTE_PATH=""
    local remote
    remote=$(git remote get-url origin 2> /dev/null || true)
    [ -z "${remote}" ] && return 0
    # git@host:group/project.git | ssh://git@host[:port]/group/project.git | https://[user@]host/group/project.git
    REMOTE_HOST=$(echo "${remote}" | sed -E 's#^(ssh://|https?://)?([^@/]+@)?([^:/]+).*#\3#')
    REMOTE_PATH=$(echo "${remote}" | sed -E 's#^(ssh://|https?://)?([^@/]+@)?[^:/]+(:[0-9]+)?[:/]##; s#\.git$##')
    case "${REMOTE_HOST}" in
        *github.com|*bitbucket.org) REMOTE_HOST=""; REMOTE_PATH="" ;;
    esac
}

configure_gitlab() {
    step "GitLab project"
    infer_from_git_remote
    local default_url="https://gitlab.com"
    [ -n "${REMOTE_HOST}" ] && default_url="https://${REMOTE_HOST}"
    ask GITLAB_URL "GitLab server URL" "${default_url}"
    GITLAB_URL=${GITLAB_URL%/}
    ask GITLAB_PROJECT_PATH "Project path that will use the runner (e.g. my-group/my-project)" "${REMOTE_PATH}"
    [ -n "${GITLAB_PROJECT_PATH}" ] || die "A GitLab project path is required."
    GITLAB_PROJECT_PATH=${GITLAB_PROJECT_PATH#/}
    GITLAB_PROJECT_PATH=${GITLAB_PROJECT_PATH%/}

    echo
    info "Optional: a GitLab personal access token lets this script look up the project and create"
    info "the runner for you. It is only used during this run. Use a ${BOLD}fine-grained${RESET} token:"
    info "  1. Open ${GITLAB_URL}/-/user_settings/personal_access_tokens"
    info "     (or select your avatar > Edit profile > Access > Personal access tokens)"
    info "  2. Open the 'Generate token' dropdown, choose 'Fine-grained token' and set a short expiry date"
    info "  3. Under 'Group and project access', add ${GITLAB_PROJECT_PATH} with the permission ${BOLD}Project: Read${RESET}"
    info "  4. On the 'User' tab, add the permission ${BOLD}Runner: Create${RESET}"
    info "  ${DIM}On GitLab versions without fine-grained tokens, use a legacy token with the scopes${RESET}"
    info "  ${DIM}create_runner and read_api instead.${RESET}"
    ask_secret GITLAB_TOKEN "Personal access token (leave empty to do those steps manually)"
    if [ -n "${GITLAB_TOKEN}" ]; then
        printf 'PRIVATE-TOKEN: %s\n' "${GITLAB_TOKEN}" > "${TEMP_DIR}/gitlab-auth-header"
        # Show what was read without revealing it: the type prefix (e.g. glpat-) is not secret
        local prefix=""
        [[ "${GITLAB_TOKEN}" == *-* ]] && prefix="${GITLAB_TOKEN%%-*}-"
        info "Read a ${#GITLAB_TOKEN}-character token${prefix:+ starting with ${prefix}}"
    fi

    GITLAB_PROJECT_ID=""
    GITLAB_PROJECT_WEB_URL="${GITLAB_URL}/${GITLAB_PROJECT_PATH}"
    GITLAB_REGISTRY_PREFIX=""
    local encoded status message
    local args=(-sS -o "${TEMP_DIR}/project.json" -w '%{http_code}')
    [ -n "${GITLAB_TOKEN}" ] && args+=(-H "@${TEMP_DIR}/gitlab-auth-header")
    encoded=$(jq -rn --arg p "${GITLAB_PROJECT_PATH}" '$p|@uri')
    status=$(curl "${args[@]}" "${GITLAB_URL}/api/v4/projects/${encoded}" 2> /dev/null || true)
    message=$(jq -r '.message // .error_description // .error // empty | tostring' "${TEMP_DIR}/project.json" 2> /dev/null || true)
    case "${status}" in
        200)
            GITLAB_PROJECT_ID=$(jq -r '.id' "${TEMP_DIR}/project.json")
            GITLAB_PROJECT_PATH=$(jq -r '.path_with_namespace' "${TEMP_DIR}/project.json")
            GITLAB_PROJECT_WEB_URL=$(jq -r '.web_url' "${TEMP_DIR}/project.json")
            GITLAB_REGISTRY_PREFIX=$(jq -r '.container_registry_image_prefix // empty' "${TEMP_DIR}/project.json")
            ok "Found project ${GITLAB_PROJECT_PATH} (id ${GITLAB_PROJECT_ID})" ;;
        401)
            warn "${GITLAB_URL} rejected the access token (typo, expired, revoked, or a token for another GitLab server)."
            warn "Continuing without it; the steps it would have done will show manual instructions."
            GITLAB_TOKEN=""
            rm -f "${TEMP_DIR}/gitlab-auth-header" ;;
        403)
            warn "GitLab accepted the token but denied access to ${GITLAB_PROJECT_PATH}:"
            warn "  ${message:-403 Forbidden}"
            warn "Edit the token so it has Project: Read on this project (under 'Group and project access')."
            warn "Continuing with the path as entered." ;;
        *)
            if [ -n "${GITLAB_TOKEN}" ]; then
                warn "Could not look up ${GITLAB_PROJECT_PATH} (HTTP ${status:-error}${message:+: ${message}})."
                warn "Check the path, and that the token has Project: Read on it. Continuing with the path as entered."
            else
                warn "Could not look up ${GITLAB_PROJECT_PATH} (a private project needs a token, or the path has a typo)."
                warn "Continuing with the path as entered."
            fi ;;
    esac
    if [ -z "${GITLAB_REGISTRY_PREFIX}" ] && [ "${GITLAB_URL}" = "https://gitlab.com" ]; then
        GITLAB_REGISTRY_PREFIX="registry.gitlab.com/$(echo "${GITLAB_PROJECT_PATH}" | tr '[:upper:]' '[:lower:]')"
    fi
}

default_stack_name() {
    local slug
    slug=$(echo "${GITLAB_PROJECT_PATH}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    slug="gitlab-runner-${slug}"
    slug=${slug:0:${MAX_STACK_NAME_LENGTH}}
    echo "${slug%-}"
}

configure_stack_name() {
    step "CloudFormation stack"
    while true; do
        ask STACK_NAME "Stack name" "$(default_stack_name)"
        if ! [[ "${STACK_NAME}" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]]; then
            warn "Use letters, numbers and hyphens, starting with a letter."
        elif [ ${#STACK_NAME} -gt ${MAX_STACK_NAME_LENGTH} ]; then
            warn "Use at most ${MAX_STACK_NAME_LENGTH} characters (resource names are derived from it)."
        else
            break
        fi
    done

    PROPERTIES_FILE="${STACK_NAME}.properties"
    STACK_EXISTS=false
    if aws_cli cloudformation describe-stacks --stack-name "${STACK_NAME}" > /dev/null 2>&1; then
        STACK_EXISTS=true
        info "Stack ${STACK_NAME} already exists in ${AWS_REGION_NAME}; it will be updated."
    fi
    TOKENS_STORED=false
    if aws_cli ssm get-parameter --name "/${STACK_NAME}/runner-tokens" > /dev/null 2>&1; then
        TOKENS_STORED=true
    fi
}

create_runner_with_api() {
    local tags run_untagged=true response
    ask tags "Runner tags, comma separated (leave empty for none)" ""
    if [ -n "${tags}" ]; then
        confirm "Also run jobs that have no tags?" n || run_untagged=false
    fi
    response=$(gitlab_api POST "/user/runners" \
        --data-urlencode "runner_type=project_type" \
        --data-urlencode "project_id=${GITLAB_PROJECT_ID}" \
        --data-urlencode "description=${STACK_NAME} (EC2 autoscaling, ${AWS_REGION_NAME})" \
        --data-urlencode "tag_list=${tags}" \
        --data-urlencode "run_untagged=${run_untagged}") \
        || return 1
    RUNNER_TOKENS=$(echo "${response}" | jq -r '.token')
    ok "Created runner $(echo "${response}" | jq -r '.id') for ${GITLAB_PROJECT_PATH}"
}

configure_runner_tokens() {
    step "GitLab runner"
    RUNNER_TOKENS=""

    if [ "${TOKENS_STORED}" = true ]; then
        info "Runner tokens are already stored for this stack in SSM (/${STACK_NAME}/runner-tokens)."
        confirm "Keep the stored tokens?" y && return 0
    fi

    if [ -n "${GITLAB_TOKEN}" ] && [ -n "${GITLAB_PROJECT_ID}" ] && confirm "Create a new project runner in GitLab now?" y; then
        if create_runner_with_api; then
            return 0
        fi
        warn "Creating the runner through the API failed. The token needs the Runner: Create permission"
        warn "(create_runner scope on a legacy token), and you need the Maintainer role on the project."
        warn "Falling back to the manual steps."
    fi

    manual_step "Create the runner in GitLab and copy its token" \
        "Open ${GITLAB_PROJECT_WEB_URL}/-/settings/ci_cd#js-runners-settings" \
        "Expand 'Runners' and click 'New project runner'  (for a group runner: the group's Build > Runners > 'New group runner')" \
        "Platform: Linux. Add tags, or tick 'Run untagged jobs'. Optionally tick 'Protected' or 'Lock to current projects'." \
        "Click 'Create runner'" \
        "Copy the runner authentication token (starts with 'glrt-'). It is only shown once. Ignore the 'gitlab-runner register' command; this setup registers the runner for you."

    while true; do
        ask_secret RUNNER_TOKENS "Runner authentication token(s), comma separated"
        if [ -z "${RUNNER_TOKENS}" ]; then
            warn "At least one token is required."
        elif ! [[ "${RUNNER_TOKENS}" =~ ^[A-Za-z0-9_.,-]+$ ]]; then
            warn "Tokens can only contain letters, numbers, '_', '.', '-', separated by commas."
        else
            break
        fi
    done
    case ",${RUNNER_TOKENS}" in
        *,glrt-*) ;;
        *) warn "These don't look like runner authentication tokens (glrt-...). Legacy registration tokens are no longer supported." ;;
    esac
}

# check_registry_push USER TOKEN
# docker login only checks that credentials are valid, not what they can do. This makes the same
# token request docker makes before a push and reports whether push was granted.
# Returns 0 if push is granted, 1 if it is not (explained), 2 if it couldn't be checked.
check_registry_push() {
    local repository status granted
    repository=${DOCKER_IMAGE_PATH#*/}
    repository=${repository%:*}
    # Credentials go in a curl config file so they don't appear in the process list
    printf 'user = "%s:%s"\n' "$1" "$2" > "${TEMP_DIR}/registry-auth"
    status=$(curl -sS -K "${TEMP_DIR}/registry-auth" -o "${TEMP_DIR}/registry-token.json" -w '%{http_code}' -G \
        --data-urlencode "service=container_registry" \
        --data-urlencode "scope=repository:${repository}:push,pull" \
        "${GITLAB_URL}/jwt/auth" 2> /dev/null || true)
    rm -f "${TEMP_DIR}/registry-auth"

    if [ "${status}" = "401" ]; then
        warn "GitLab rejected the deploy token username or token."
        return 1
    fi
    if [ "${status}" != "200" ]; then
        warn "Couldn't check push access to ${repository} (HTTP ${status:-error}); trying the push anyway."
        return 2
    fi

    # The registry token is a JWT; its payload lists the actions granted on the repository
    granted=$(jq -r --arg repo "${repository}" '.token // empty | split(".")[1]
        | gsub("-"; "+") | gsub("_"; "/") | (. + ("=" * ((4 - length % 4) % 4))) | @base64d | fromjson
        | [.access[]? | select(.name == $repo) | .actions[]] | join(",")' "${TEMP_DIR}/registry-token.json" 2> /dev/null || true)
    case ",${granted}," in
        *,push,*)
            ok "The deploy token can push to ${repository}"
            return 0 ;;
    esac
    warn "The deploy token can't push to ${repository} (granted: ${granted:-nothing}). Check that:"
    warn "  - it has the write_registry scope (read_registry alone can't push)"
    warn "  - it was created in the project that owns the image, or in a group that contains it"
    warn "  - the project's container registry is enabled (Settings > General > Visibility, project"
    warn "    features, permissions > Container registry)"
    return 1
}

# image_repository <image>  -> the image without its tag (a registry port is not a tag)
image_repository() {
    local last=${1##*/}
    if [[ "${last}" == *:* ]]; then
        echo "${1%:*}"
    else
        echo "$1"
    fi
}

# Tag for a build of the working tree: the git commit, plus a timestamp when there are
# uncommitted changes, so every different build gets a different tag
image_version_tag() {
    local tag
    tag=$(git rev-parse --short=12 HEAD 2> /dev/null) || tag="build"
    if [ -n "$(git status --porcelain 2> /dev/null)" ]; then
        tag="${tag}-dirty-$(date -u +%Y%m%d%H%M%S)"
    fi
    echo "${tag}"
}

configure_executor_image() {
    step "Executor image (the Docker image CI jobs run in)"
    local default_image=""
    [ -n "${GITLAB_REGISTRY_PREFIX}" ] && default_image="${GITLAB_REGISTRY_PREFIX}/gitlab-runner"
    [ -n "${DOCKER_IMAGE_PATH}" ] && default_image=$(image_repository "${DOCKER_IMAGE_PATH}")
    info "Runners reuse an image already on the instance when its tag matches (pull policy"
    info "if-not-present), so each build is pushed with its own tag, the git commit, as well as :latest."
    ask DOCKER_IMAGE_PATH "Image path (without a tag to build, or with the tag of an existing image)" "${default_image}"
    [ -n "${DOCKER_IMAGE_PATH}" ] || die "An executor image path is required."

    if ! confirm "Build the Dockerfile in this directory and push it to $(image_repository "${DOCKER_IMAGE_PATH}") now?" y; then
        if [ "$(image_repository "${DOCKER_IMAGE_PATH}")" = "${DOCKER_IMAGE_PATH}" ]; then
            DOCKER_IMAGE_PATH="${DOCKER_IMAGE_PATH}:latest"
            warn "No tag given, so ${DOCKER_IMAGE_PATH} is used. Instances that already have it won't pick"
            warn "up a new push to :latest until they are replaced; push a new tag to roll out a change."
        fi
        info "Skipping the build; ${DOCKER_IMAGE_PATH} must already exist and be built for linux/amd64."
        return 0
    fi

    # Fine-grained personal access tokens can't push images, so the push uses a project deploy token
    # (or whatever credentials docker already has for the registry)
    local registry=${DOCKER_IMAGE_PATH%%/*}
    info "Pushing needs registry credentials. Fine-grained access tokens can't push images; use a"
    info "project deploy token with the write_registry scope, or credentials docker already has."
    if confirm "Log in to ${registry} with a deploy token?" y; then
        local open_step="In GitLab, open the project that owns ${DOCKER_IMAGE_PATH%%:*}, then Settings > Repository > Deploy tokens"
        if [ -n "${GITLAB_REGISTRY_PREFIX}" ] && [[ "${DOCKER_IMAGE_PATH}" == "${GITLAB_REGISTRY_PREFIX}"/* ]]; then
            open_step="Open ${GITLAB_PROJECT_WEB_URL}/-/settings/repository#js-deploy-tokens  (Settings > Repository > Deploy tokens)"
        fi
        manual_step "Create a deploy token that can push images" \
            "${open_step}" \
            "Click 'Add token'. Give it a name and an expiry date, and select the scope 'write_registry'" \
            "Click 'Create deploy token' and copy the username and the token (the token is only shown once)"
        local deploy_user deploy_token
        while true; do
            ask deploy_user "Deploy token username" ""
            ask_secret deploy_token "Deploy token"
            check_registry_push "${deploy_user}" "${deploy_token}" && break
            [ $? -eq 2 ] && break
            confirm "Enter a different deploy token?" y || die "No deploy token that can push to ${DOCKER_IMAGE_PATH%%:*}."
        done
        printf '%s' "${deploy_token}" | docker login "${registry}" --username "${deploy_user}" --password-stdin > /dev/null \
            || die "docker login to ${registry} failed. Check the deploy token username and token."
        ok "Logged in to ${registry} as ${deploy_user}"
    else
        info "Logging in to ${registry} (skip with Ctrl+D if you are already logged in)..."
        docker login "${registry}" || warn "docker login did not succeed; the push below will fail if you are not logged in."
    fi

    local repository
    repository=$(image_repository "${DOCKER_IMAGE_PATH}")
    DOCKER_IMAGE_PATH="${repository}:$(image_version_tag)"

    # The runners are x86 (t3a); build for amd64 even on Apple Silicon
    if ! docker buildx build --platform linux/amd64 -t "${DOCKER_IMAGE_PATH}" -t "${repository}:latest" --push .; then
        warn "If the error above says 'insufficient_scope' or 'push access denied', the docker credentials"
        warn "for ${registry} can't push to ${DOCKER_IMAGE_PATH%%:*}. Re-run and log in with a deploy"
        warn "token from that project that has the write_registry scope, and check the project's container"
        warn "registry is enabled (Settings > General > Visibility, project features, permissions)."
        die "Building or pushing ${DOCKER_IMAGE_PATH} failed."
    fi
    ok "Pushed ${DOCKER_IMAGE_PATH} (also tagged :latest)"
}

# Points an existing properties file at the image just built; deploying it replaces the instances
update_properties_image() {
    local updated="${TEMP_DIR}/properties"
    grep -v '^DockerImagePath=' "${PROPERTIES_FILE}" > "${updated}"
    echo "DockerImagePath=\"${DOCKER_IMAGE_PATH}\"" >> "${updated}"
    cat "${updated}" > "${PROPERTIES_FILE}"
    ok "Set DockerImagePath in ${PROPERTIES_FILE} to ${DOCKER_IMAGE_PATH}"
}

configure_network() {
    step "Network"
    info "VPCs in ${AWS_REGION_NAME}:"
    local vpcs default_vpc
    vpcs=$(aws_cli ec2 describe-vpcs --output json)
    echo "${vpcs}" | jq -r '.Vpcs[] | [.VpcId, .CidrBlock, (if .IsDefault then "(default)" else "-" end),
        ((.Tags // []) | map(select(.Key == "Name")) | first | .Value // "-")] | @tsv' \
        | while IFS=$'\t' read -r id cidr is_default name; do
            printf '      %-23s %-18s %-10s %s\n' "${id}" "${cidr}" "${is_default}" "${name}"
        done
    default_vpc=$(echo "${vpcs}" | jq -r 'if (.Vpcs | length) == 1 then .Vpcs[0].VpcId else (.Vpcs[] | select(.IsDefault) | .VpcId) // empty end')
    ask VPC_ID "VPC ID" "${default_vpc}"

    local subnets route_tables subnet_table
    subnets=$(aws_cli ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --output json) \
        || die "Could not list subnets for ${VPC_ID}."
    route_tables=$(aws_cli ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" --output json)
    # Classify each subnet by its default route: internet gateway (public), NAT gateway, or other
    subnet_table=$(echo "${route_tables}" | jq -r --argjson subnets "${subnets}" '
        .RouteTables as $tables
        | ($tables | map(select(any(.Associations[]?; .Main == true))) | first) as $main
        | $subnets.Subnets | sort_by(.AvailabilityZone)[]
        | . as $s
        | (($tables | map(select(any(.Associations[]?; .SubnetId == $s.SubnetId))) | first) // $main) as $table
        | (($table.Routes // []) | map(select(.DestinationCidrBlock == "0.0.0.0/0" and .State != "blackhole")) | first) as $route
        | (if $route == null then "no-internet"
           elif (($route.GatewayId // "") | startswith("igw-")) then "public"
           elif $route.NatGatewayId != null then "private-nat"
           else "private-other" end) as $type
        | [$s.SubnetId, $s.AvailabilityZone, $s.CidrBlock, $type,
           (($s.Tags // []) | map(select(.Key == "Name")) | first | .Value // "-")] | @tsv')
    [ -n "${subnet_table}" ] || die "No subnets found in ${VPC_ID}."

    echo
    info "Subnets in ${VPC_ID}:"
    echo "${subnet_table}" | while IFS=$'\t' read -r id az cidr type name; do
        printf '      %-26s %-12s %-18s %-14s %s\n' "${id}" "${az}" "${cidr}" "${type}" "${name}"
    done
    echo
    info "${DIM}public: route to an internet gateway (runners get public IPs, no NAT needed)${RESET}"
    info "${DIM}private-nat: route through a NAT gateway${RESET}"

    local default_subnets
    default_subnets=$(echo "${subnet_table}" | awk -F'\t' '$4 == "public" { print $1 }' | paste -sd, -)
    [ -z "${default_subnets}" ] && default_subnets=$(echo "${subnet_table}" | awk -F'\t' '$4 == "private-nat" { print $1 }' | paste -sd, -)

    while true; do
        ask SUBNET_IDS "Subnet IDs for the runners, comma separated (two or more AZs recommended)" "${default_subnets}"
        SUBNET_IDS=$(echo "${SUBNET_IDS}" | tr -d ' ')
        local types
        types=$(echo "${SUBNET_IDS}" | tr ',' '\n' | while read -r id; do
            echo "${subnet_table}" | awk -F'\t' -v id="${id}" '$1 == id { print $4; found = 1 } END { if (!found) print "unknown" }'
        done | sort -u)
        if echo "${types}" | grep -q "unknown"; then
            warn "One or more subnet IDs are not in ${VPC_ID}."
        elif echo "${types}" | grep -q "no-internet"; then
            warn "Runners need outbound internet access; pick subnets with a public or NAT route."
        elif [ "$(echo "${types}" | wc -l | tr -d ' ')" -gt 1 ]; then
            warn "Pick subnets of the same type (all public or all private)."
        else
            break
        fi
    done

    case "${types}" in
        public)
            ASSOCIATE_PUBLIC_IP=true
            ok "Public subnets: runners will get public IPs (no inbound access is allowed)" ;;
        private-nat)
            ASSOCIATE_PUBLIC_IP=false
            ok "Private subnets with a NAT gateway" ;;
        *)
            ASSOCIATE_PUBLIC_IP=false
            warn "These subnets reach the internet through something other than a NAT or internet gateway."
            confirm "Continue, assuming they have outbound internet access?" n || die "Aborted." ;;
    esac
}

configure_sizing() {
    step "Runner sizing"
    ask INSTANCE_TYPE "Instance type" "t3a.medium"
    ask CONCURRENT "Concurrent jobs per instance" "2"
    ask MIN_SIZE "Minimum instances" "1"
    ask MAX_SIZE "Maximum instances" "4"
    ask VOLUME_SIZE "Disk size per instance (GiB)" "100"
    ask RUNNER_VERSION "GitLab Runner version (e.g. 18.5.0, or latest)" "latest"
    ask COST_CENTER "Cost center tag" "none"
    ask APP_ID "Application ID tag" "${STACK_NAME}"
    [ "${MAX_SIZE}" -ge "${MIN_SIZE}" ] 2> /dev/null || die "Maximum instances must be a number at least the minimum."
}

ensure_lambda_bucket() {
    step "S3 bucket for Lambda code"
    ask LAMBDA_BUCKET "Bucket name (created if it doesn't exist)" "gitlab-runner-lambdas-${AWS_ACCOUNT_ID}-${AWS_REGION_NAME}"
    if aws_cli s3api head-bucket --bucket "${LAMBDA_BUCKET}" > /dev/null 2>&1; then
        ok "Using existing bucket ${LAMBDA_BUCKET}"
        return 0
    fi
    if [ "${AWS_REGION_NAME}" = "us-east-1" ]; then
        aws_cli s3api create-bucket --bucket "${LAMBDA_BUCKET}" > /dev/null
    else
        aws_cli s3api create-bucket --bucket "${LAMBDA_BUCKET}" \
            --create-bucket-configuration "LocationConstraint=${AWS_REGION_NAME}" > /dev/null
    fi || die "Could not create bucket ${LAMBDA_BUCKET} (bucket names are global; try another name)."
    ok "Created bucket ${LAMBDA_BUCKET}"
}

ensure_autoscaling_service_role() {
    if aws_cli iam get-role --role-name AWSServiceRoleForAutoScaling > /dev/null 2>&1; then
        return 0
    fi
    step "Creating the EC2 Auto Scaling service-linked role"
    aws_cli iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com > /dev/null \
        || die "Could not create the AWSServiceRoleForAutoScaling service-linked role."
    ok "Created AWSServiceRoleForAutoScaling"
}

write_properties() {
    # Runner tokens are deliberately not written here; they go straight to SSM
    umask 077
    cat > "${PROPERTIES_FILE}" <<EOF
# Generated by setup-runner.sh for ${GITLAB_PROJECT_PATH}. Re-deploy with:
#   $(deploy_command)
VpcID=${VPC_ID}
SubnetIds=${SUBNET_IDS}
AssociatePublicIpAddress=${ASSOCIATE_PUBLIC_IP}
ImageId=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
InstanceType=${INSTANCE_TYPE}
InstanceName=${STACK_NAME}
VolumeSize=${VOLUME_SIZE}
VolumeType=gp3
MaxSize=${MAX_SIZE}
MinSize=${MIN_SIZE}
DesiredCapacity=${MIN_SIZE}
MaxBatchSize=1
MinInstancesInService=$([ "${MIN_SIZE}" -gt 0 ] && [ "${MAX_SIZE}" -gt 1 ] && echo 1 || echo 0)
MaxInstanceLifetime=604800
GitlabServerURL="${GITLAB_URL}"
DockerImagePath="${DOCKER_IMAGE_PATH}"
GitlabRunnerVersion=${RUNNER_VERSION}
LambdaS3Bucket=${LAMBDA_BUCKET}
Concurrent=${CONCURRENT}
CheckInterval=3
SwapSize=4
JobMemoryLimit=1536m
ServiceMemoryLimit=512m
DockerPullPolicy=if-not-present,always
CostCenter=${COST_CENTER}
AppId=${APP_ID}
EOF
    umask 022
    ok "Wrote ${PROPERTIES_FILE}"
}

load_existing_properties() {
    # shellcheck disable=SC1090
    source "./${PROPERTIES_FILE}"
    DOCKER_IMAGE_PATH=${DockerImagePath}
}

deploy() {
    step "Deploying ${STACK_NAME} to ${AWS_REGION_NAME}"
    info "This usually takes 5-15 minutes."
    local args=("${PROPERTIES_FILE}" "${AWS_REGION_NAME}")
    [ -n "${AWS_PROFILE_NAME}" ] && args+=("${AWS_PROFILE_NAME}")
    args+=("${STACK_NAME}")
    RunnersToken="${RUNNER_TOKENS}" ./deploy-runner.sh "${args[@]}" \
        || die "Deployment failed. Check the stack's Events tab in the CloudFormation console for the first failure."
}

print_next_steps() {
    step "Done"
    ok "Stack ${STACK_NAME} is deployed. Auto Scaling group: ${STACK_NAME}-asg"
    echo
    echo "    ${BOLD}Next steps${RESET}"
    echo "      1. Check the runner shows as online (green) at:"
    echo "         ${GITLAB_PROJECT_WEB_URL}/-/settings/ci_cd#js-runners-settings"
    echo "         If it doesn't appear within a few minutes, connect to an instance with Session Manager"
    echo "         (EC2 console > Connect) and check /var/log/cfn-init.log and 'journalctl -u gitlab-runner'."
    echo "      2. Run a pipeline. If the runner has tags, add matching 'tags:' to your jobs."
    echo "      3. If other projects will use this runner and ${DOCKER_IMAGE_PATH%%:*} is private, add them to"
    echo "         the image project's Settings > CI/CD > Job token permissions allowlist."
    echo
    echo "    ${BOLD}Later${RESET}"
    echo "      Re-deploy after changing ${PROPERTIES_FILE}:"
    echo "        $(deploy_command)"
    echo "      Change runner tokens: re-run ./setup-runner.sh, then replace the instances:"
    echo "        ./cycle-runner.sh ${STACK_NAME}-asg ${AWS_REGION_NAME} ${AWS_PROFILE_NAME}" | sed 's/ *$//'
    echo "      Remove everything:"
    echo "        aws cloudformation delete-stack --stack-name ${STACK_NAME} --region ${AWS_REGION_NAME}$(profile_suffix)"
    echo "        aws ssm delete-parameter --name /${STACK_NAME}/runner-tokens --region ${AWS_REGION_NAME}$(profile_suffix)"
    echo "        aws s3 rm s3://${LAMBDA_BUCKET}/${STACK_NAME}/ --recursive$(profile_suffix)"
    echo "      and delete the runner in GitLab."
}

main() {
    echo "${BOLD}GitLab Runner on Amazon EC2: setup${RESET}"
    echo "This walks through everything needed to deploy a runner stack. Defaults are shown in [brackets]."

    check_prerequisites
    configure_aws
    configure_gitlab
    configure_stack_name

    local reuse=false
    if [ -f "${PROPERTIES_FILE}" ]; then
        info "Found ${PROPERTIES_FILE} from a previous run."
        confirm "Reuse its settings (VPC, subnets, sizing, bucket, image)?" y && reuse=true
    fi

    configure_runner_tokens

    if [ "${reuse}" = true ]; then
        load_existing_properties
        LAMBDA_BUCKET=${LambdaS3Bucket}
        if confirm "Rebuild and push the executor image (currently ${DOCKER_IMAGE_PATH})?" n; then
            configure_executor_image
            update_properties_image
        fi
    else
        configure_executor_image
        configure_network
        configure_sizing
        ensure_lambda_bucket
        ensure_autoscaling_service_role
        write_properties
    fi

    step "Summary"
    info "Stack:        ${STACK_NAME} (${AWS_REGION_NAME}, account ${AWS_ACCOUNT_ID})$([ "${STACK_EXISTS}" = true ] && echo ", update")"
    info "Project:      ${GITLAB_PROJECT_PATH}"
    info "Image:        ${DOCKER_IMAGE_PATH}"
    info "Settings:     ${PROPERTIES_FILE}"
    info "Tokens:       $([ -n "${RUNNER_TOKENS}" ] && echo "new, stored as SecureString /${STACK_NAME}/runner-tokens" || echo "keep stored")"
    confirm "Deploy now?" y || { info "Not deployed. Re-run this script, or run deploy-runner.sh with ${PROPERTIES_FILE}."; exit 0; }

    deploy
    print_next_steps
}

main "$@"
