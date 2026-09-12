#!/bin/bash
# Thin CLI recipes; no credentials in image configuration or run payloads.
set -euo pipefail
AWS_CLI=${AWS_CLI:-aws}
export AWS_REGION=${AWS_REGION:-ap-southeast-2}
export AWS_PAGER=''
case "${1:-}" in
    upload)
        "$AWS_CLI" s3 cp "${2:?artifact.zip}" "${3:?s3://bucket/key.zip}" ;;
    create)
        "$AWS_CLI" lambda-microvms create-microvm-image \
            --name "${2:?image-name}" --code-artifact "uri=${3:?s3://bucket/key.zip}" \
            --build-role-arn "${4:?build-role-arn}" \
            --base-image-arn "arn:aws:lambda:$AWS_REGION:aws:microvm-image:al2023-1" \
            --cpu-configurations '[{"architecture":"ARM_64"}]' \
            --resources '[{"minimumMemoryInMiB":1024}]' \
            --hooks '{"port":9000,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":60}}' ;;
    status)
        "$AWS_CLI" lambda-microvms get-microvm-image --image-identifier "${2:?image-arn}"
        "$AWS_CLI" lambda-microvms get-microvm-image-version \
            --image-identifier "$2" --image-version "${3:?version}" ;;
    update)
        "$AWS_CLI" lambda-microvms update-microvm-image \
            --image-identifier "${2:?image-arn}" --code-artifact "uri=${3:?s3://bucket/key.zip}" \
            --base-image-arn "arn:aws:lambda:$AWS_REGION:aws:microvm-image:al2023-1" \
            --build-role-arn "${4:?build-role-arn}" \
            --cpu-configurations '[{"architecture":"ARM_64"}]' \
            --resources '[{"minimumMemoryInMiB":1024}]' \
            --hooks '{"port":9000,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":60}}' ;;
    run)
        "$AWS_CLI" lambda-microvms run-microvm \
            --image-identifier "${2:?image-arn}" --image-version "${3:?version}" \
            --execution-role-arn "${4:?execution-role-arn}" \
            --ingress-network-connectors "arn:aws:lambda:$AWS_REGION:aws:network-connector:aws-network-connector:SHELL_INGRESS" \
            --egress-network-connectors "arn:aws:lambda:$AWS_REGION:aws:network-connector:aws-network-connector:INTERNET_EGRESS" \
            --maximum-duration-in-seconds 3600 ;;
    terminate)
        "$AWS_CLI" lambda-microvms terminate-microvm --microvm-identifier "${2:?microvm-id}" ;;
    *) echo 'Usage: aws.sh upload|create|update|status|run|terminate [arguments]' >&2; exit 2 ;;
esac
