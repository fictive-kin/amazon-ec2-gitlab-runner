#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

usage() {
  cat <<EOF
Usage: $(basename "$0") <runner-asg-name> [<region>] [<aws-profile>]

Replaces every instance in the runner autoscaling group with an instance refresh, so new
instances pick up changes such as new runner tokens. Running jobs finish first: each
instance is unregistered and stopped gracefully by the termination lifecycle hook.

Arguments:
  runner-asg-name   Autoscaling group name (<stack-name>-asg)
  region            Optional AWS region of the stack, e.g. us-east-1. Without it,
                    AWS_REGION, AWS_DEFAULT_REGION or the profile's configured region
                    is used, and you're asked for one if none is set
  aws-profile       Optional AWS CLI profile. Without it, the AWS CLI's default
                    credentials are used. Given alone, an argument that looks like a
                    region (us-east-1) is the region and anything else the profile

Options:
  -h, --help, -?    Show this help and exit
EOF
}

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

for arg in "$@"; do
  case "${arg}" in
    -h|--help|-\?) usage; exit 0 ;;
  esac
done

if [[ "$#" -lt 1 || "$#" -gt 3 ]]
then
    echo "Incorrect number of arguments" >&2
    echo "Usage: $(basename "$0") <runner-asg-name> [<region>] [<aws-profile>]" >&2
    echo "Run '$(basename "$0") --help' for details." >&2
    exit 1
fi

AutoScalingGroupName=$1
split_region_and_profile "${@:2}"
resolve_region
echo "Cycle instances in autoscaling group: ${AutoScalingGroupName} (${region})"

profile_args=()
if [[ -n "${profile}" ]]; then
  profile_args=(--profile "${profile}")
  IGNORE=$(aws sts get-caller-identity --profile "${profile}")
else
  echo "No AWS profile was provided, so the AWS CLI's default credentials are used."
fi

aws autoscaling start-instance-refresh \
  --auto-scaling-group-name="${AutoScalingGroupName}" \
  --region="${region}" \
  ${profile_args[@]+"${profile_args[@]}"}

echo "Refresh initiated"

exit 0

