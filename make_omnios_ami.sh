#!/bin/bash
AWS_AMI_NAME="OmniOS r151042"
AWS_AMI_DESC="OmniOS illumos distribution"
AWS_AMI_VMDK="$HOME/Downloads/omnios-r151042.cloud.vmdk"
VMDK="$(basename "$AWS_AMI_VMDK")"
>&2 echo Setting up…
if [ -z "$AWS_BUCKET" ]; then
    AWS_BUCKET="${AWS_BUCKET:=ami-images-illumos-omnios`date +%s`.kittens.ph}"
    >&2 printf '!! AWS_BUCKET not set. If you are sure you want to create %s press RETURN else ^C.' "$AWS_BUCKET"
    read __JUNK
    set -x
    aws s3 mb "s3://$AWS_BUCKET"
    aws s3 cp "$AWS_AMI_VMDK" "s3://$AWS_BUCKET"
    set +x
fi
rm -rf /tmp/aws_bs || true
mkdir -p /tmp/aws_bs
>&2 echo Writing temporary files…
cat > /tmp/aws_bs/role.json << EOF
{
   "Version": "2012-10-17",
   "Statement": [
      {
         "Effect": "Allow",
         "Principal": { "Service": "vmie.amazonaws.com" },
         "Action": "sts:AssumeRole",
         "Condition": {
            "StringEquals":{
               "sts:Externalid": "vmimport"
            }
         }
      }
   ]
}
EOF
cat > /tmp/aws_bs/role_policy.json << EOF
{
   "Version":"2012-10-17",
   "Statement":[
      {
         "Effect": "Allow",
         "Action": [
            "s3:GetBucketLocation",
            "s3:GetObject",
            "s3:ListBucket" 
         ],
         "Resource": [
            "arn:aws:s3:::$AWS_BUCKET",
            "arn:aws:s3:::$AWS_BUCKET/*"
         ]
      },
      {
         "Effect": "Allow",
         "Action": [
            "s3:GetBucketLocation",
            "s3:GetObject",
            "s3:ListBucket",
            "s3:PutObject",
            "s3:GetBucketAcl"
         ],
         "Resource": [
            "arn:aws:s3:::$AWS_BUCKET",
            "arn:aws:s3:::$AWS_BUCKET/*"
         ]
      },
      {
         "Effect": "Allow",
         "Action": [
            "ec2:ModifySnapshotAttribute",
            "ec2:CopySnapshot",
            "ec2:RegisterImage",
            "ec2:Describe*"
         ],
         "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ],
        "Resource": "*"
      },
      {
          "Effect": "Allow",
          "Action": [
            "license-manager:GetLicenseConfiguration",
            "license-manager:UpdateLicenseSpecificationsForResource",
            "license-manager:ListLicenseSpecificationsForResource"
          ],
          "Resource": "*"
      }
   ]
}
EOF
set -x
aws --profile root iam create-role --role-name vmimport --assume-role-policy-document file:///tmp/role.json
aws iam put-role-policy --role-name vmimport --policy-name vmimport --policy-document file:///tmp/role-policy.json
aws s3 ls "s3://$AWS_BUCKET"
set +x
cat > /tmp/aws_bs/mkbucket.json << EOF
{
    "Description": "$AWS_BUCKET ${VMDK%%.vmdk}",
    "Format" : "vmdk",
    "UserBucket": {
        "S3Bucket": "$AWS_BUCKET",
        "S3Key": "$VMDK"
    }
}
EOF
if [ -z "$AWS_NO_IMPORT_SNAPSHOT" ]; then
    >&2 echo Importing disk container…
    aws ec2 import-snapshot --disk-container file:///tmp/aws_bs/mkbucket.json
fi
should_break=0
while true; do
    ASYNC_AWS_JOB_JSON="$(aws ec2 describe-import-snapshot-tasks)"
    [[ "$(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Status' <<< "$ASYNC_AWS_JOB_JSON")" =~ "completed" ]] && \
        >&2 echo Imported snapshot! && should_break=1 || \
        >&2 echo "$ASYNC_AWS_JOB_JSON"
    [ $should_break -eq 1 ] && break
    >&2 echo Sleeping 5s…
    sleep 5
done
AWS_SNAPSHOT_ID="$(jq '.ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' -r <<< "$ASYNC_AWS_JOB_JSON")"
cat > /tmp/aws_bs/register.json << EOF
{
    "Architecture": "x86_64",
    "Description": "$AWS_AMI_DESC",
    "EnaSupport": true,
    "Name": "$AWS_AMI_NAME",
    "RootDeviceName": "/dev/xvda",
    "BlockDeviceMappings": [
        {
            "DeviceName": "/dev/xvda",
            "Ebs": {
                "SnapshotId": "$AWS_SNAPSHOT_ID"
            }
        }
    ],
    "VirtualizationType": "hvm",
    "BootMode": "uefi"
}
EOF
>&2 echo Checking if image registered…
set -x
AWS_AMI_ID=$(aws ec2 describe-images --owners self | jq -r '.Images[] | select(.BlockDeviceMappings[0].Ebs.SnapshotId == "'"$AWS_SNAPSHOT_ID"'") | .ImageId')
if [ ! $? -o -z "$AWS_AMI_ID" ]; then
    while true; do
        AWS_AMI_ID="$(aws ec2 register-image --cli-input-json file:///tmp/aws_bs/register.json | jq -r .ImageId)"
        if [ ! $? ]; then
            continue
        else
            set +x
            break
        fi
    done
fi
set +x
>&2 echo Done. AWS_AMI_ID="$AWS_AMI_ID"
if [ -z "$DEBUG" ]; then
    rm -r /tmp/aws_bs
fi
export AWS_AMI_ID
