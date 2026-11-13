# Lab 06 – Implementing Auto Scaling for an ECS-Based Application

## 1. Aim / Objective

The objective of this practical is to make the USMS enrolment service (`usms-enrolment-svc`) scale automatically with Application Auto Scaling, using only the AWS CLI. Specifically, to:

- Register the ECS service as a scalable target with a floor of 2 tasks and a ceiling of 10, and read the service-linked role that changes `desiredCount` on our behalf.
- Create two target tracking policies (CPU utilisation and `ALBRequestCountPerTarget`), a step scaling policy driven by a custom CloudWatch alarm, and two scheduled actions.
- Fire the alarm and prove that something other than the operator changed `desiredCount`, then suspend and resume scaling.
- Prove the scaling configuration survives a restart and record every name and ARN in `configs/lab-06.env`.

## 2. Introduction

**Application Auto Scaling** is the AWS service that automatically adjusts the capacity of scalable resources other than EC2 instances, such as ECS services, DynamoDB tables, Aurora replicas and Lambda concurrency. For an ECS service, it controls exactly one value: the service's `desiredCount`. ECS then starts or stops tasks to match that number, and the load balancer from Lab 05 registers and health-checks the new tasks.

Scaling is configured as a **scalable target** (which resource may scale, and between which bounds), plus **scaling policies** that decide the number, plus **scheduled actions** that change the bounds at set times. Every reactive decision comes from a **CloudWatch alarm**. Auto scaling matters in cloud computing because it matches capacity to demand: the service grows during a spike to protect response times and shrinks afterwards to save cost, without anyone changing a number by hand.

### Key Features

- Scalable targets with minimum and maximum capacity
- Target tracking scaling (keep a metric at a set value, like a thermostat)
- Step scaling (piecewise responses driven by your own alarm)
- Scheduled scaling (cron, rate and one-off `at()` schedules, with time zones)
- Independent suspension of scale-in, scale-out and scheduled scaling
- Scale-out and scale-in cooldowns
- A service-linked role, so no custom IAM role is needed
- An activity history recording who changed capacity and why

## 3. Use Case

Enrolment at the College of Science and Technology produces very uneven load on the **University Student Management System (USMS)**. Traffic is low overnight, rises every weekday morning, and spikes sharply when enrolment opens or exam results are published.

| Load pattern                          | Scaling mechanism used                                            |
| ------------------------------------- | ----------------------------------------------------------------- |
| Gradual daytime growth in requests    | Target tracking on `ALBRequestCountPerTarget` (1000/min per task) |
| CPU-heavy requests (reports, uploads) | Target tracking on average CPU (50%)                              |
| Enrolment work queue backing up       | Step scaling: +1 task at depth 100, +3 tasks at depth 200         |
| Predictable weekday morning rush      | Scheduled action: floor raised to 4 at 07:45 Asia/Thimphu         |
| Quiet evenings                        | Scheduled action: floor lowered back to 2 at 20:00                |
| Deployments, incidents, load tests    | Suspend scaling without deleting any policy                       |

The floor of 2 keeps one task in each Availability Zone, and the ceiling of 10 protects the account from a runaway policy.

Other common uses include scaling web APIs on request rate, scaling queue workers on backlog, and pre-warming capacity for known events such as sales or ticket releases.

## 4. System Architecture / Design

```
                              Internet
                                  |
                                  v
  usms-vpc 10.0.0.0/16
  +----------------------------------------------------------------+
  |  public subnets a / b     usms-enrolment-alb                   |
  |                           listener HTTP:80 -> usms-enrolment-tg|
  |                                  |                             |
  |                  tcp/80 from usms-alb-sg only                  |
  |                                  v                             |
  |  private subnet a (AZ a)          private subnet b (AZ b)      |
  |   [ task ] [ task ]                [ task ] [ task ]   <- 2..10|
  |                                  ^                             |
  |  ECS: usms-ecs-cluster / usms-enrolment-svc                    |
  |       desiredCount  <--------------------------------+         |
  +------------------------------------------------------|---------+
                                                         | writes ONE integer
  Application Auto Scaling                               |
  +------------------------------------------------------|---------+
  | scalable target  service/usms-ecs-cluster/usms-enrolment-svc   |
  |                  ecs:service:DesiredCount   min 2  max 10      |
  |                                                                |
  | usms-enrolment-cpu-target-tracking        CPU -> 50%           |
  |   (2 managed alarms, created for us)                           |
  | usms-enrolment-requests-target-tracking   requests -> 1000     |
  |   (2 managed alarms, created for us)                           |
  | usms-enrolment-queue-step-out             StepScaling          |
  |   <- alarm usms-enrolment-queue-high                           |
  |      USMS/Enrolment EnrolmentQueueDepth >= 100                 |
  | usms-enrolment-morning-scale-out   weekdays 07:45   min 4      |
  | usms-enrolment-evening-scale-in    weekdays 20:00   min 2      |
  | suspended state: scale-in / scale-out / scheduled switches     |
  +----------------------------------------------------------------+
  Identity: AWSServiceRoleForApplicationAutoScaling_ECSService
            (service-linked role that calls ecs:UpdateService)
```

**Data flow:** metric published → CloudWatch alarm changes state → alarm invokes a scaling policy → policy writes `desiredCount` (clamped to 2–10) → ECS starts tasks in the private subnets → the service registers them in the target group → after the 60-second grace period they receive traffic.

> **Insert architecture diagram screenshot here (optional)**

## 5. Implementation Procedure

The practical began by starting Floci and loading the six environment files from Labs 01–05, then confirming with the verification scripts that the earlier labs were intact and that the service was at its baseline of 2 tasks. A probe of Application Auto Scaling and CloudWatch showed which operations the Floci build supports. The service-linked role `AWSServiceRoleForApplicationAutoScaling_ECSService` was created and read back.

The scalable target was registered using a resource ID derived from the service's ARN (`service/usms-ecs-cluster/usms-enrolment-svc`), with dimension `ecs:service:DesiredCount`, minimum 2 and maximum 10. Re-registering it with a ceiling of 12 and then back to 10 showed that a re-registration changes only the parameters passed. A CPU target tracking policy (target 50%, scale-out cooldown 60 s, scale-in cooldown 300 s) was created and its two managed CloudWatch alarms were inspected. A second target tracking policy on `ALBRequestCountPerTarget` (target 1000 requests per task per minute) was created using a `ResourceLabel` built from the Lab 05 load balancer and target group ARNs.

A custom metric, `USMS/Enrolment EnrolmentQueueDepth`, was published, and a step scaling policy (+1 task for a breach of 0–100, +3 tasks for a breach of 100 or more) was created together with the alarm `usms-enrolment-queue-high` that invokes it. Two scheduled actions were defined to raise the floor to 4 on weekday mornings and lower it to 2 in the evenings, in the `Asia/Thimphu` time zone.

The alarm was then driven into the `ALARM` state, first by publishing a queue depth of 260 and then with `set-alarm-state`, and the result was read back with `describe-services` and `describe-scaling-activities`. Where the emulator did not change `desiredCount`, the six-block control-plane proof was recorded instead. Scale-in was suspended and resumed, the configuration was compared before and after a Floci restart, the full metric-to-task path was traced, the ARNs were written to `configs/lab-06.env`, and the work was committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Screenshot 1 – Environment loaded (Step 1)**

![alt text](assets/1.png)

**Screenshot 2 – Earlier labs verified and service at baseline (Step 2)**

![alt text](assets/2.png)


**Screenshot 3 – Floci support probe (Step 3)**

![alt text](assets/3.png)


**Screenshot 4 – Service-linked role (Step 4)**

![alt text](assets/4.png)

**Screenshot 5 – Scalable target registered (Step 5)**
![alt text](assets/5.png)
![alt text](assets/6.png)

**Screenshot 6 – Re-registration: bounds 2/12 then 2/10, exactly one target (Step 6)**

![alt text](assets/7.png)
![alt text](assets/8.png)

**Exercise**

Work out, without running anything, what would happen if you re-registered this target with --min-capacity 5 while the service is running two tasks. Then do it, observe, and put it back to 2.

![alt text](assets/9.png)

(a) Which object made that change: the scalable target, a scaling policy, or ECS?
The scalable target made the change. Registering a floor above the current count makes Application Auto Scaling raise desiredCount to the floor. No policy is involved, and ECS only carries the new number out.

(b) You are on call. A colleague raises MinCapacity to 5 to ride out an incident and goes to bed without telling anyone. What is the cost of that, and which single API call would have told you it had happened?
The cost is three extra tasks running all night (and every night until someone notices). The service also can never scale in below 5, so the waste persists. The call that would have shown it is aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" --query 'ScalableTargets[0].MinCapacity', which a monitor could compare with the expected value of 2.

**Screenshot 7 – CPU target tracking policy and its managed alarms (Steps 7–8)**

![alt text](assets/10.png)
![alt text](assets/11.png)


### A2. Step 8 – how long at 100% CPU before a third task serves traffic?
 
| Term                                   | Where it comes from                         | Value                       |
| -------------------------------------- | ------------------------------------------- | --------------------------- |
| High alarm `Period × EvaluationPeriods` | Managed alarm from Step 8                   | 60 s × 3 = **180 s**        |
| Policy invocation                      | Application Auto Scaling                    | ≈ **0 s**                   |
| Task start-up (Fargate)                | Lab 04 Exercise 5 (`outputs/lab-04-scale-latency.txt`) | **S**  |
| Health-check grace period              | Lab 05 Step 10                              | **60 s**                    |
 
**Total ≈ 180 + 0 + S + 60 seconds.** With an example start-up of S = 60 s, that is 300 s, or about **5 minutes** running at 100% CPU on two tasks.
 
Two of the four terms (start-up and grace period) come from earlier labs, and the alarm term is chosen by AWS rather than by this lab.
 
I would change the **grace period** first, reducing it to the measured cold-start time plus a small margin, because it is the only term fully under my control. The cost is that a task that starts slowly could be marked unhealthy and replaced repeatedly in a loop.
 

**Screenshot 8 – ResourceLabel and request-count policy (Step 9)**

![alt text](assets/12.png)

**Screenshot 9 – Custom metric, step policy and alarm (Step 10)**
![alt text](assets/13.png)
![alt text](assets/14.png)

**Screenshot 10 – Scheduled actions (Step 11)**

![alt text](assets/15.png)

**Exercise**
![alt text](assets/16.png)
![alt text](assets/17.png)

After it fires, an at() action stays listed in describe-scheduled-actions and, if it ran, it leaves MinCapacity at 6, so six months later someone may assume the higher floor is deliberate or mistake the stale entry for a live schedule. The runbook page that creates it should also contain delete-scheduled-action --scheduled-action-name usms-enrolment-results-night followed by register-scalable-target --min-capacity 2 --max-capacity 10.

**Alarm fired and the result (Step 12 parts 2–4)**
![alt text](assets/18.png)
![alt text](assets/19.png)
![alt text](assets/20.png)
![alt text](assets/21.png)
![alt text](assets/22.png)
![alt text](assets/23.png)

**Screenshot 12 – Control-plane scaling proof (Step 12 part 5)**
![alt text](assets/24.png)
![alt text](assets/25.png)


**Screenshot 13 – Suspend and resume (Step 13)**
![alt text](assets/26.png)
![alt text](assets/27.png)
![alt text](assets/28.png)


**Screenshot 14 – Persistence across restart (Step 14)**
![alt text](assets/29.png)

**Screenshot 15 – Metric-to-task trace (Step 15)**

![alt text](assets/30.png)

**Screenshot 16 – `configs/lab-06.env` (Step 16)**

![alt text](assets/31.png)


**Screenshot 17 – Verification script and commit (Section 8, Step 17)**

![alt text](assets/32.png)

### Exercise 3: Problem solving: a scaling report tool

```bash
cat > scripts/utilities/usms-scaling-report.sh << 'EOF'
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
EOF

chmod +x scripts/utilities/usms-scaling-report.sh
bash -n scripts/utilities/usms-scaling-report.sh && echo "syntax ok"
./scripts/utilities/usms-scaling-report.sh | tee outputs/lab-06-scaling-report.txt
```
![alt text](assets/32.png)

### Exercise 4 – Challenge: the enrolment-week capacity plan
 
 The traffic figures below are **assumptions** for the worked example. 
 
**1. Does the ceiling of 10 fit in the network? (Lab 02 subnet sizes)**
 
| Subnet                  | CIDR         | Addresses | AWS-reserved | Usable | Already used          |
| ----------------------- | ------------ | --------- | ------------ | ------ | --------------------- |
| `usms-private-subnet-a` | 10.0.3.0/24  | 256       | 5            | 251    | `usms-db-01` (1)      |
| `usms-private-subnet-b` | 10.0.4.0/24  | 256       | 5            | 251    | –                     |
 
Each Fargate task in `awsvpc` mode takes **one IP address** (its ENI). Ten tasks split across two AZs need about 5 addresses per subnet, so the subnets could hold far more than 10. **The ceiling is not limited by the network.** It is a safety limit on cost and on downstream capacity, such as database connections.
 
**2. How many tasks does enrolment week need?**
 
```
tasks needed = ceil( peak requests per minute / target requests per task per minute )
```
 
| Assumption                    | Value              |
| --------------------------------------------- | ------------------ |
| Peak load on opening morning                  | 11,000 req/min     |
| Normal enrolment-week daytime load            | 6,000 req/min      |
| Target per task (Step 9 `TargetValue`)        | 1,000 req/min      |
| Measured capacity of one task (load test)     | ~1,500 req/min     |
 
- Normal daytime: 6,000 / 1,000 = **6 tasks**. This fits within the current 2–10 range.
- Opening morning: 11,000 / 1,000 = **11 tasks**. This **exceeds the ceiling of 10**, so the policy would be clamped and every task would run at about 1,100 req/min, which is above target but still below the measured ~1,500 capacity.
- Target 1,000 against measured capacity 1,500 leaves about 33% headroom per task, which covers the minutes before scale-out takes effect.
**3. The plan**
 
| When                              | Action                                   | MinCapacity | MaxCapacity |
| --------------------------------- | ---------------------------------------- | ----------- | ----------- |
| Week before enrolment             | Load test; confirm per-task capacity     | 2           | 10          |
| Enrolment week, Monday 07:00      | Raise ceiling for the week               | 4           | 14          |
| Opening morning, 07:30            | One-off `at()`: pre-warm before opening  | 8           | 14          |
| Opening day, 18:00                | Release the pre-warm floor               | 4           | 14          |
| End of week, Friday 20:00         | Back to normal                           | 2           | 10          |
 
Commands (the first two shown; the others follow the same pattern). Note that `put-scheduled-action` is unsupported on Floci 2.0.1, so record these as configuration only:
 
```bash
aws application-autoscaling put-scheduled-action --service-namespace ecs \
  --resource-id "$RID" --scalable-dimension "$SDIM" \
  --scheduled-action-name usms-enrolment-week-start \
  --schedule "cron(0 7 ? * MON *)" --timezone "Asia/Thimphu" \
  --scalable-target-action MinCapacity=4,MaxCapacity=14 \
  || echo "put-scheduled-action unsupported on Floci 2.0.1 - recorded as configuration only"
 
aws application-autoscaling put-scheduled-action --service-namespace ecs \
  --resource-id "$RID" --scalable-dimension "$SDIM" \
  --scheduled-action-name usms-enrolment-opening-prewarm \
  --schedule "at(2027-01-11T07:30:00)" --timezone "Asia/Thimphu" \
  --scalable-target-action MinCapacity=8,MaxCapacity=14 \
  || echo "put-scheduled-action unsupported on Floci 2.0.1 - recorded as configuration only"
```
 
 ![alt text](assets/33.png)

**4. Risks and checks**
 
- **Database connections:** 14 tasks × the per-task connection pool must stay below `usms-db-01`'s connection limit. Check this before raising the ceiling.
- **Pre-warming is the only way to be early.** Reactive scaling needs about 5 minutes, so the opening-morning surge must be covered by the scheduled floor of 8, not by the policies.
- **Remove one-off actions afterwards** (lesson from A3), and put the ceiling back to 10.
- **Cost:** extra cost ≈ (extra tasks) × (hours) × (Fargate price for 0.25 vCPU / 1 GB). Add current Fargate pricing for your region if the exercise asks for a figure.

### Exercise 5 – Integration: the hand-off to Lab 10
 
Lab 10's first `put-object` needs a real file: `outputs/lab-06-scaling-history.json`. This script builds it from live readbacks, so the file is evidence of what existed.
 
```bash
python3 - "$RID" << 'PY'
import datetime, json, subprocess, sys
 
rid = sys.argv[1]
 
def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return {"unavailable": r.stderr.strip()[:300]}
    return json.loads(r.stdout)
 
doc = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "resource_id": rid,
    "scalable_target": aws("application-autoscaling", "describe-scalable-targets",
                           "--service-namespace", "ecs", "--resource-ids", rid),
    "policies": aws("application-autoscaling", "describe-scaling-policies",
                    "--service-namespace", "ecs", "--resource-id", rid),
    "scheduled_actions": aws("application-autoscaling", "describe-scheduled-actions",
                             "--service-namespace", "ecs", "--resource-id", rid),
    "activities": aws("application-autoscaling", "describe-scaling-activities",
                      "--service-namespace", "ecs", "--resource-id", rid),
    "custom_alarms": aws("cloudwatch", "describe-alarms",
                         "--alarm-name-prefix", "usms-enrolment-queue"),
    "service": aws("ecs", "describe-services", "--cluster", "usms-ecs-cluster",
                   "--services", "usms-enrolment-svc",
                   "--query", "services[0].{desired:desiredCount,running:runningCount,taskDefinition:taskDefinition}"),
}
 
with open("outputs/lab-06-scaling-history.json", "w") as f:
    json.dump(doc, f, indent=2, default=str)
print("wrote outputs/lab-06-scaling-history.json")
PY
 
python3 -m json.tool outputs/lab-06-scaling-history.json >/dev/null && echo "valid JSON"
ls -l outputs/lab-06-scaling-history.json
python3 -c "import json;d=json.load(open('outputs/lab-06-scaling-history.json'));print(list(d.keys()))"
git check-ignore -v outputs/lab-06-scaling-history.json     # must name the outputs/* rule
```

### 6.2 AWS Management Console Verification

This practical was performed on Floci, a local emulator with no AWS Management Console. Resource creation was verified with read-back CLI commands instead (`describe-scalable-targets`, `describe-scaling-policies`, `describe-alarms`, `describe-scheduled-actions`, `describe-scaling-activities`, `describe-services`), shown in Section 6.1.

## 7. Analysis and Discussion

The scaling configuration was built as designed: a scalable target with bounds of 2 and 10, two target tracking policies, a step scaling policy linked to a custom alarm, scale-in suspension and resumption, and an env file recording every object. The parts that depend on the emulator *running* the scaling loop (alarms evaluating on their own, scheduled actions firing, and `desiredCount` moving without operator input) are limited on Floci 2.0.1, as documented on the course's Known Issues page.

### Observations

- Application Auto Scaling writes only one integer, `desiredCount`; ECS, the target group and the load balancer do everything after that.
- Reactive scaling is always late. Alarm evaluation (3 × 60 s for the managed high alarm), task start-up and the 60-second grace period add up to several minutes. That is why the minimum capacity is a latency decision and why scheduled scaling is the only form that can act early.
- There is no `update-scalable-target` or `suspend-scaling` call. Both are done by re-registering the target, and any parameter left out is kept.
- Scale-out uses the largest capacity any policy asks for, but target tracking scales in only when every policy agrees.
- A scheduled action changes the bounds, not the count, and deleting an action does not undo a floor it has already raised.
- A successful command is not proof; only a readback is.

## 8. Reflection

**1. What did you learn about this AWS service?**
I learned that Application Auto Scaling is built from a scalable target, policies and scheduled actions, and that every reactive decision is really a CloudWatch alarm invoking a policy. I learned the difference between target tracking, which computes a capacity and creates its own alarms, and step scaling, which applies fixed adjustments from an alarm I write myself. I also learned how cooldowns, evaluation periods and the grace period together decide how late scaling is.

**2. What challenges did you encounter?**
The main challenge was separating my own mistakes from emulator limitations. Floci accepts most of the configuration but does not run the full scaling loop, so I had to prove the wiring through readbacks rather than by watching tasks appear. Problems carried over from Lab 05, such as the missing `loadBalancers` field, also had to be handled carefully in JMESPath queries.

**3. How would you apply this service in a real-world cloud environment?**
For a web API I would make request-count target tracking the main policy, keep a floor of at least one task per Availability Zone, scale out quickly and scale in slowly, and use scheduled actions to raise the floor before known events such as enrolment day. For queue workers I would scale on backlog per task. I would also alert on any scalable target that stays suspended.

**4. What additional concepts or features would you like to explore?**
- Target tracking on a custom backlog-per-task metric
- Predictive scaling for EC2 Auto Scaling groups
- Kubernetes Horizontal Pod Autoscaler and node autoscaling (Lab 08)
- Alarm actions to SNS and composite alarms (Lab 13)
- Load testing to measure real per-task capacity
- Declaring the whole scaling stack in CloudFormation

## 9. Conclusion

The configuration objectives of this practical were achieved. The enrolment service was registered as a scalable target with bounds of 2 and 10, given CPU and request-count target tracking policies, a step scaling policy driven by a custom alarm, and a suspension mechanism, with every object recorded in `configs/lab-06.env`. Floci 2.0.1 does not run scheduled actions or let a forced alarm change the ECS desired count, so those behaviours were proven through the control-plane chain and the local scaling demonstration, and labelled honestly.

The practical developed my skills in Application Auto Scaling, CloudWatch alarms and metrics, JMESPath and systematic verification. It showed why auto scaling is central to cloud-native systems: it matches capacity to demand automatically, protecting performance during spikes and reducing cost when load falls.

