#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

usage() {
  cat <<EOF
Usage: $(basename "$0") <runner-asg-name> <region> [<aws-profile>]

Replaces every instance in the runner autoscaling group with an instance refresh, so new
instances pick up changes such as new runner tokens. Running jobs finish first: each
instance is unregistered and stopped gracefully by the termination lifecycle hook.

Arguments:
  runner-asg-name   Autoscaling group name (<stack-name>-asg)
  region            AWS region of the stack, e.g. us-east-1
  aws-profile       Optional AWS CLI profile. Without it, the AWS CLI's default
                    credentials are used

Options:
  -h, --help, -?    Show this help and exit
EOF
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help|-\?) usage; exit 0 ;;
  esac
done

if [[ "$#" -lt 2 || "$#" -gt 3 ]]
then
    echo "Incorrect number of arguments" >&2
    echo "Usage: $(basename "$0") <runner-asg-name> <region> [<aws-profile>]" >&2
    echo "Run '$(basename "$0") --help' for details." >&2
    exit 1
fi

AutoScalingGroupName=$1
echo "Cycle instances in autoscaling group: "$AutoScalingGroupName

region=$2

profile_args=()
if [[ -n "${3:-}" ]]; then
  profile_args=(--profile "$3")
  IGNORE=$(aws sts get-caller-identity --profile "$3")
else
  echo "No AWS profile was provided, so the AWS CLI's default credentials are used."
fi

aws autoscaling start-instance-refresh \
  --auto-scaling-group-name="${AutoScalingGroupName}" \
  --region="${region}" \
  ${profile_args[@]+"${profile_args[@]}"}

echo "Refresh initiated"

exit 0

