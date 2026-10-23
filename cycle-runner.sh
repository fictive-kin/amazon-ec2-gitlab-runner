#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

if [[ "$#" -lt 2 || "$#" -gt 3 ]]
then
    echo "Incorrect number of arguments"
    echo "Usage: $0 <runner-asg-name> <region> <optional-aws-profile>"
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

