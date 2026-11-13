#!/usr/bin/env bash
# Read-only scaling report for usms-enrolment-svc. Changes nothing.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true

CLUSTER="${USMS_ECS_CLUSTER:-usms-ecs-cluster}"
SERVICE="${USMS_ENROLMENT_SERVICE:-usms-enrolment-svc}"
SVC_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"

hr() { printf '\n== %s ==\n' "$1"; }

echo "USMS scaling report  $(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
echo "resource: $RID"

hr "Service"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:length(deployments || `[]`),LBs:length(loadBalancers || `[]`)}' \
  --output table

hr "Scalable target"
aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].{Min:MinCapacity,Max:MaxCapacity,Dimension:ScalableDimension}' --output table

hr "Suspension (any True is a warning)"
SUSP=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].SuspendedState' --output json)
echo "$SUSP"
if echo "$SUSP" | grep -qi true; then echo "WARNING: some scaling is SUSPENDED"; else echo "ok: nothing suspended"; fi

hr "Policies"
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query 'ScalingPolicies[].{Name:PolicyName,Type:PolicyType,Alarms:length(Alarms || `[]`)}' --output table

hr "Alarms (managed + custom)"
aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${RID}" \
  --query 'MetricAlarms[].[MetricName,ComparisonOperator,Threshold,StateValue]' --output text
aws cloudwatch describe-alarms --alarm-name-prefix usms-enrolment-queue \
  --query 'MetricAlarms[].[AlarmName,ComparisonOperator,Threshold,StateValue]' --output text

hr "Scheduled actions"
aws application-autoscaling describe-scheduled-actions --service-namespace ecs --resource-id "$RID" \
  --query 'ScheduledActions[].[ScheduledActionName,Schedule,Timezone,ScalableTargetAction.MinCapacity,ScalableTargetAction.MaxCapacity]' \
  --output text 2>/dev/null || echo "(not available on this build)"

hr "Last 5 scaling activities"
aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$RID" \
  --max-items 5 --query 'ScalingActivities[].[StartTime,StatusCode,Cause]' --output text 2>/dev/null \
  || echo "(not available on this build)"
