#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Disable the AWS CLI v2 pager so commands don't block waiting for input
export AWS_PAGER=""

# Loads KEY=VALUE lines, such as GitlabApiToken, from .env next to this script. A variable already
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

usage()
{
    cat <<EOF
Usage: $(basename "$0") <properties-file-path> [<region>] [<aws-profile>] <stack-name>

Deploys or updates the GitLab Runner CloudFormation stack described by a properties file.
Stores the runner tokens (RunnersToken) and the optional GitLab API token for the runner
monitor (GitlabApiToken) as SSM SecureStrings, uploads both Lambda functions to
LambdaS3Bucket, then creates or updates the stack and waits for it to finish. Either token
can also be passed in the environment or in .env next to this script, which win over the
properties file. Without GitlabApiToken, a GITLAB_TOKEN from the environment or .env is
stored for the monitor only after you confirm it.

Arguments:
  properties-file-path  Settings for the stack; see sample-runner.properties
  region                Optional AWS region to deploy to, e.g. us-east-1. Without it,
                        AWS_REGION, AWS_DEFAULT_REGION or the profile's configured region
                        is used, and you're asked for one if none is set
  aws-profile           Optional AWS CLI profile. Without it, the AWS CLI's default
                        credentials are used (environment variables, AWS_PROFILE,
                        the default profile or an instance role). Given alone, an
                        argument that looks like a region (us-east-1) is the region and
                        anything else the profile
  stack-name            CloudFormation stack name

Options:
  -h, --help, -?        Show this help and exit
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help|-\?) usage; exit 0 ;;
    esac
done

if [[ "$#" -lt 2 || "$#" -gt 4 ]]
then
    echo "Incorrect number of arguments" >&2
    echo "Usage: $(basename "$0") <properties-file-path> [<region>] [<aws-profile>] <stack-name>" >&2
    echo "Run '$(basename "$0") --help' for details." >&2
    exit 1
fi

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

errorExit()
{
    echo $1
    exit 1
}

callCloudFormation()
{
    aws cloudformation $1 \
        --stack-name ${stack_name} \
        --template-body file://gitlab-runner.yaml \
        --capabilities CAPABILITY_NAMED_IAM \
        ${profile_arg} \
        --region ${region} \
        --parameters \
            ParameterKey=VpcID,ParameterValue=${VpcID} \
            ParameterKey=SubnetIds,ParameterValue=\"${SubnetIds}\" \
            ParameterKey=ImageId,ParameterValue=\"${ImageId}\" \
            ParameterKey=InstanceType,ParameterValue=${InstanceType} \
            ParameterKey=InstanceName,ParameterValue=${InstanceName} \
            ParameterKey=VolumeSize,ParameterValue=${VolumeSize} \
            ParameterKey=VolumeType,ParameterValue=${VolumeType} \
            ParameterKey=MaxSize,ParameterValue=${MaxSize} \
            ParameterKey=MinSize,ParameterValue=${MinSize} \
            ParameterKey=DesiredCapacity,ParameterValue=${DesiredCapacity} \
            ParameterKey=MaxBatchSize,ParameterValue=${MaxBatchSize} \
            ParameterKey=MinInstancesInService,ParameterValue=${MinInstancesInService} \
            ParameterKey=MaxInstanceLifetime,ParameterValue=${MaxInstanceLifetime} \
            ParameterKey=GitlabServerURL,ParameterValue=${GitlabServerURL} \
            ParameterKey=DockerImagePath,ParameterValue=${DockerImagePath} \
            ParameterKey=LambdaS3Bucket,ParameterValue=${LambdaS3Bucket} \
            ParameterKey=TimeStamp,ParameterValue=$2 \
            ParameterKey=Concurrent,ParameterValue=${Concurrent} \
            ParameterKey=CheckInterval,ParameterValue=${CheckInterval} \
            ParameterKey=CostCenter,ParameterValue=${CostCenter} \
            ParameterKey=AppId,ParameterValue=${AppId} \
            ParameterKey=GitlabRunnerVersion,ParameterValue=${GitlabRunnerVersion:-latest} \
            ParameterKey=AssociatePublicIpAddress,ParameterValue=${AssociatePublicIpAddress:-false} \
            ParameterKey=SwapSize,ParameterValue=${SwapSize:-4} \
            ParameterKey=JobMemoryLimit,ParameterValue=${JobMemoryLimit:-1536m} \
            ParameterKey=ServiceMemoryLimit,ParameterValue=${ServiceMemoryLimit:-512m} \
            ParameterKey=JobShmSize,ParameterValue=${JobShmSize:-0} \
            ParameterKey=CountOfNewJobsBeforeScaling,ParameterValue=${CountOfNewJobsBeforeScaling:-2} \
            ParameterKey=GitlabRunnerIds,ParameterValue=\"${GitlabRunnerIds:-}\" \
            ParameterKey=DockerPullPolicy,ParameterValue=\"${DockerPullPolicy:-if-not-present,always}\" \
            ParameterKey=CacheExpirationDays,ParameterValue=${CacheExpirationDays:-14}
}

verifyStackSuccess()
{
    status=$(aws cloudformation describe-stacks \
                                    --stack-name ${stack_name}  \
                                    --query "Stacks[0].StackStatus" \
                                    ${profile_arg} \
                                    --region ${region} \
                                    --output text) \
                                    || errorExit "Error getting stack status" 2> /dev/null

    if [ "${status}" == "$1" ]; then
        echo "Stack $2 was successful"
    else
        errorExit "Stack $2 failed (status ${status}). See CloudFormation console for error details"
    fi
}

# Runner tokens are stored as a SecureString, which CloudFormation cannot create, so they
# are written here rather than passed to the stack. Leave RunnersToken empty in the
# properties file to keep the tokens already stored for the stack.
storeRunnerTokens()
{
    parameter_name="/${stack_name}/runner-tokens"

    if [ -z "${RunnersToken}" ]; then
        aws ssm get-parameter --name ${parameter_name} ${profile_arg} --region ${region} > /dev/null 2>&1 \
            || errorExit "RunnersToken is empty and no tokens are stored in ${parameter_name}"
        echo "Using runner tokens already stored in ${parameter_name}"
        return
    fi

    if ! [[ "${RunnersToken}" =~ ^[A-Za-z0-9_.,-]+$ ]]; then
        errorExit "RunnersToken must be a comma separated list of runner authentication tokens"
    fi

    # Pass the tokens in a file so they don't appear in the process list
    input_file=$(mktemp)
    chmod 600 ${input_file}
    printf '{"Name": "%s", "Type": "SecureString", "Overwrite": true, "Value": "%s"}' "${parameter_name}" "${RunnersToken}" > ${input_file}
    aws ssm put-parameter --cli-input-json file://${input_file} ${profile_arg} --region ${region} > /dev/null
    status=$?
    rm -f ${input_file}
    if [ ${status} -ne 0 ]; then
        errorExit "Storing runner tokens in ${parameter_name} did not complete successfully."
    fi
    echo "Stored runner tokens in ${parameter_name}"
}

# GITLAB_TOKEN is often a broader token kept for the other scripts, so it is only stored for the
# monitor, which uses it unattended every minute, after asking. Sets GitlabApiToken when confirmed;
# says nothing when it is the token already stored.
confirmGitlabTokenForMonitor()
{
    local stored answer
    stored=$(aws ssm get-parameter --name ${parameter_name} --with-decryption --query Parameter.Value --output text \
        ${profile_arg} --region ${region} 2> /dev/null)
    [ "${stored}" == "${GITLAB_TOKEN}" ] && return

    if [ ! -t 0 ]; then
        echo "GITLAB_TOKEN is set but not stored for the runner monitor: set GitlabApiToken to store it"
        return
    fi
    if [ -n "${stored}" ]; then
        read -r -p "Replace the runner monitor's GitLab API token in ${parameter_name} with GITLAB_TOKEN (${GITLAB_TOKEN:0:7}...)? [y/N]: " answer
    else
        read -r -p "Store GITLAB_TOKEN (${GITLAB_TOKEN:0:7}...) in ${parameter_name} for the runner monitor to count waiting jobs? [y/N]: " answer
    fi
    case "${answer}" in
        [Yy]|[Yy][Ee][Ss]) GitlabApiToken=${GITLAB_TOKEN} ;;
    esac
}

# Optional token the runner monitor uses to count jobs waiting in GitLab (GitlabApiToken). Empty
# keeps the one already stored, if any; without one the monitor scales on running jobs only.
storeGitlabApiToken()
{
    parameter_name="/${stack_name}/gitlab-api-token"

    if [ -z "${GitlabApiToken}" ] && [ -n "${GITLAB_TOKEN}" ]; then
        confirmGitlabTokenForMonitor
    fi

    if [ -z "${GitlabApiToken}" ]; then
        if aws ssm get-parameter --name ${parameter_name} ${profile_arg} --region ${region} > /dev/null 2>&1; then
            echo "Using the GitLab API token already stored in ${parameter_name}"
        elif [ -n "${GitlabRunnerIds}" ]; then
            echo "No GitLab API token in ${parameter_name}: set GitlabApiToken to scale on pending jobs"
        fi
        return
    fi

    if ! [[ "${GitlabApiToken}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        errorExit "GitlabApiToken must be a single GitLab access token"
    fi

    # Pass the token in a file so it doesn't appear in the process list
    input_file=$(mktemp)
    chmod 600 ${input_file}
    printf '{"Name": "%s", "Type": "SecureString", "Overwrite": true, "Value": "%s"}' "${parameter_name}" "${GitlabApiToken}" > ${input_file}
    aws ssm put-parameter --cli-input-json file://${input_file} ${profile_arg} --region ${region} > /dev/null
    status=$?
    rm -f ${input_file}
    if [ ${status} -ne 0 ]; then
        errorExit "Storing the GitLab API token in ${parameter_name} did not complete successfully."
    fi
    echo "Stored the GitLab API token in ${parameter_name}"
}

uploadLifecycleHookToS3()
{
  file_name="${stack_name}-lifecycle-hook-${time_stamp}.zip"
  case "$OSTYPE" in
  solaris*) echo "SOLARIS" ;;
  darwin*)  echo "OSX" & zip ${file_name} gitlab-runner-lifecycle-hook.py;;
  linux*)   echo "LINUX" & zip ${file_name} gitlab-runner-lifecycle-hook.py;;
  bsd*)     echo "BSD" ;;
  msys|cygwin*)    echo "WINDOWS" & set MSYS_NO_PATHCONV=1 & jar -cvf ${file_name} gitlab-runner-lifecycle-hook.py;;
  *)        echo "unknown: $OSTYPE" ;;
  esac
  
  aws s3 cp ${profile_arg} ${file_name} s3://${LambdaS3Bucket}/${stack_name}/${file_name}
  if [ $? -ne 0 ]; then
      errorExit "Uploading lifecycle-hook lambda function code to S3 did not complete successfully."
  fi
  rm -f ${file_name}
}

uploadRunnerMonitorToS3() {
  # Note: The nodejs lambda runtime ships its own aws-sdk v3, but we bundle ours
  #  so the deployed function uses the versions pinned in package.json
    
  file_name="${stack_name}-runner-monitor-${time_stamp}.zip"

  cd runner-monitor-lambda
  npm install
  npm run build
  cd bin

  case "$OSTYPE" in
  solaris*) echo "SOLARIS" ;;
  darwin*)  echo "OSX" & zip -r ../../${file_name} *;;
  linux*)   echo "LINUX" & zip -r ../../${file_name} *;;
  bsd*)     echo "BSD" ;;
  msys|cygwin*)    echo "WINDOWS" & set MSYS_NO_PATHCONV=1 & jar -cvf ../../${file_name} *;;
  *)        echo "unknown: $OSTYPE" ;;
  esac

  cd ../..

  aws s3 cp ${profile_arg} ${file_name} s3://${LambdaS3Bucket}/${stack_name}/${file_name}
  if [ $? -ne 0 ]; then
      errorExit "Uploading lifecycle-hook lambda function code to S3 did not complete successfully."
  fi
  rm -f ${file_name}
}

deployStack()
{
    echo -n "Checking if stack already exists..."
    aws cloudformation describe-stacks --stack-name ${stack_name} ${profile_arg} --region ${region} --no-paginate --query="Stacks[].{Name: StackName}"

    if [ $? -ne 0 ]; then
        echo "Stack does not exist, creating it..."
        callCloudFormation "create-stack" ${time_stamp}

        if [ $? -ne 0 ]; then
            errorExit "Stack creation failed"
        fi

        echo -n "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete --stack-name ${stack_name} ${profile_arg} --region ${region} 2> /dev/null
        if [ $? -ne 0 ]; then
            echo
            echo -n "Stack creation completed with failure..."
        fi

        verifyStackSuccess "CREATE_COMPLETE" "create"
    else
        echo "Stack already exists. Attempting to update it..."
        callCloudFormation "update-stack" ${time_stamp} 2> temp.txt

        status=$?
        Temp=`cat temp.txt`
        rm -f temp.txt

        if [ ${status} -ne 0 ]; then
            if echo ${Temp} | grep "No updates are to be performed" > /dev/null ; then
                echo "No updates are needed"
                exit 0
            else
                errorExit "Stack update failed: ${Temp}"
            fi
        fi

        echo "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name ${stack_name} ${profile_arg} --region ${region} 2> /dev/null
        if [ $? -ne 0 ]; then
            echo "Stack update completed with failure..."
        fi

        verifyStackSuccess "UPDATE_COMPLETE" "update"
    fi
}

# Read properties for the stack. Tokens passed in the environment (as setup-runner.sh does) win over
# the properties file's, which are often left empty.
env_runners_token=${RunnersToken:-}
env_gitlab_api_token=${GitlabApiToken:-}
source $1 || errorExit "Unable to load properties"
RunnersToken=${env_runners_token:-${RunnersToken:-}}
GitlabApiToken=${env_gitlab_api_token:-${GitlabApiToken:-}}

stack_name=${!#}
split_region_and_profile "${@:2:$# - 2}"
resolve_region
if [[ -n "${profile}" ]]; then
    profile_arg="--profile ${profile}"
    echo "Deploying Gitlab runner in region: ${region}, using AWS profile: ${profile}"
else
    profile_arg=""
    echo "Deploying Gitlab runner in region: ${region}, using the default AWS credentials"
fi
echo "CloudFormation stack name: "$stack_name

#Suffix for the lambda zip
time_stamp=`date "+%Y%m%d%H%M%S"` 

storeRunnerTokens
storeGitlabApiToken
uploadLifecycleHookToS3
uploadRunnerMonitorToS3
deployStack