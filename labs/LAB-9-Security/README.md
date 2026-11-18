# Lab 09 – Security Review of the USMS Estate (IAM and Network)

## 1. Aim / Objective

The objective of this practical is to review and harden the security of everything built in Labs 01–06, using only the AWS CLI. The review covers two questions: **who can call what** (IAM) and **what can reach what** (security groups and routing). Specifically, to:

- Inventory and audit every role and security group with read-only scripts.
- Fix the identity findings: a read-only transcripts policy, confused-deputy trust conditions, a scoped `iam:PassRole`, a permissions boundary, a session policy, an access key rotation and IMDSv2.
- Fix the network findings: written egress rules on three security groups, a bastion-sourced SSH rule, and a proof that the data tier is unreachable.
- Prove the controls survive a restart, confirm nothing earlier broke, and save the results to `configs/lab-09.env`.

## 2. Introduction

**AWS Identity and Access Management (IAM)** decides whether an API call is allowed. Every request is evaluated against several layers: identity policies on the user or role, **permissions boundaries** that cap what an identity can ever be granted, **session policies** passed when a role is assumed, resource policies such as S3 bucket policies, and **trust policies** that decide who may assume a role at all. An explicit `Deny` in any layer wins. **Security groups** are the network half: stateful firewalls attached to network interfaces, with separate ingress and egress rules, that can name other security groups as sources or destinations.

A security review in the cloud is mostly reading configuration carefully: which principals can assume which roles, which actions are allowed on which resources, and which network paths exist. It matters because most cloud breaches come from configuration (over-broad permissions, open ports, leaked long-lived keys) rather than from flaws in AWS itself. The principle applied throughout is **least privilege**: every identity and every network path should have exactly what its job needs, and nothing else.

### Key Features

- Identity policies, trust policies and the explicit-deny rule
- Confused-deputy protection with `aws:SourceAccount` and `aws:SourceArn`
- Scoped `iam:PassRole` with `iam:PassedToService`
- Permissions boundaries and session policies (intersection of permissions)
- Access key rotation (create → move → deactivate → delete)
- IMDSv2 (session tokens) and the hop limit on EC2 metadata
- Security group ingress and **egress** rules, group references and prefix lists
- Defence in depth: public IP, routing, security groups and NACLs together

## 3. Use Case

The **University Student Management System (USMS)** holds student transcripts, which are personal data. The College's information security officer asks the cloud team to show that only the right services can read or change them, and that the database cannot be reached from the internet.

| Risk                                                         | Control applied in this lab                                       |
| ------------------------------------------------------------ | ----------------------------------------------------------------- |
| A service that only *displays* transcripts can also *change* them | New `USMSStudentDataReadOnly` policy and `usms-transcripts-reader-role` |
| Another AWS account tricks ECS into assuming our task role   | Trust conditions `aws:SourceAccount` / `aws:SourceArn`            |
| A deployer passes a powerful role to a new EC2 instance      | `iam:PassRole` limited to three roles, only to `ecs-tasks`        |
| A deployment role grants itself more permissions             | `USMSPermissionsBoundary` caps `usms-deploy-role`                 |
| A leaked developer key stays valid for months                | Access key rotated; old key deleted                               |
| SSRF on the web server steals instance credentials           | IMDSv2 required, hop limit 1                                      |
| A compromised task sends data anywhere on the internet       | Written egress rules instead of allow-all                         |
| SSH to the web server from anywhere in the VPC               | SSH only from `usms-bastion-sg`                                   |

The same review applies to any AWS workload holding sensitive data: university records, health data, payments or government services.

## 4. System Architecture / Design

```
                      IDENTITY ("who can call what")

  usms-admin-01 ──assume──> usms-deploy-role
                              ├─ USMSDeployBase
                              │    iam:PassRole ONLY:
                              │      usms-ecs-exec-role, usms-ecs-task-role,
                              │      usms-transcripts-reader-role
                              │      AND iam:PassedToService = ecs-tasks
                              └─ boundary: USMSPermissionsBoundary
                                   (denies IAM identity changes, organizations:*,
                                    VPC/subnet/IGW/NAT deletion)

  ecs-tasks.amazonaws.com ──assume──> usms-ecs-task-role       (trust now requires
                                      usms-transcripts-reader-role  SourceAccount 000000000000
                                                                    and SourceArn arn:aws:ecs:...)
     usms-ecs-task-role           -> USMSStudentDataReadWrite  (List, Get, Put)
     usms-transcripts-reader-role -> USMSStudentDataReadOnly   (List, Get; Deny Put/Delete)

  usms-dev-01 (one access key, rotated) ──assume + session policy──> usms-developer-role
     effective = role policy ∩ session policy

                      NETWORK ("what can reach what")

  Internet ─80─> usms-alb-sg ─80─> usms-enrolment-sg ─443─> S3 prefix list / 0.0.0.0/0
                  egress: 80 to            egress: 443 only
                  enrolment-sg only
  Internet ─80/443─> usms-app-sg (usms-web-01, IMDSv2 required, hop limit 1)
  203.0.113.10/32 ─22─> usms-bastion-sg ─22─> usms-app-sg   (was 22 from 10.0.0.0/16)
  usms-app-sg ─5432─> usms-db-sg (usms-db-01)     egress: 443 only (updates via NAT)

  usms-db-01 negative proof: no public IP · no auto-assign · no IGW route ·
                             one source group · non-default NACL
```

## 5. Implementation Procedure

The practical began by starting Floci, sourcing the environment files from Labs 01–06 and recording a baseline of every earlier verification script in `outputs/lab-09-pre-verify.txt`. A probe recorded which IAM features the Floci build supports (support path B, management only, was expected), because Floci stores policies but never evaluates them.

The identity review started with an inventory of roles, users and customer-managed policies, saved to `outputs/lab-09-identity-inventory.json`, and an audit script (`usms-iam-audit.sh`) that flagged wildcard actions, `Resource: "*"` on mutating actions, unscoped `iam:PassRole` and service trust policies without conditions. Reading `USMSStudentDataReadWrite` showed that every role reading transcripts could also write them, so a new `USMSStudentDataReadOnly` policy (List and Get allowed; Put, Delete and bucket-policy changes explicitly denied) and a `usms-transcripts-reader-role` were created. The trust policy of `usms-ecs-task-role` was rewritten with the same principal and two confused-deputy conditions.

A permissions boundary (`USMSPermissionsBoundary`) and a deployment policy (`USMSDeployBase`, with `iam:PassRole` limited to three named roles and only to ECS tasks) were created and combined in `usms-deploy-role`. A session policy narrowed an assumed `usms-developer-role` session, and the effective permissions were computed as the intersection. The `usms-dev-01` access key was rotated in the safe order (create, repoint the profile, verify, deactivate, delete). IMDSv2 was required on `usms-web-01` with a hop limit of 1.

The network review used `usms-sg-audit.sh` to answer four questions for each group: who reaches me, what do I reach, by group or by address, and am I attached to anything. Default allow-all egress was replaced with written rules on `usms-enrolment-sg` (HTTPS to the S3 prefix list and AWS endpoints), `usms-alb-sg` (HTTP only to the enrolment group) and `usms-db-sg` (HTTPS for updates), each time writing an undo document first and authorising the new rule before revoking the old one. SSH to `usms-app-sg` was narrowed from the whole VPC to `usms-bastion-sg`. A reachability matrix and a five-control negative proof showed `usms-db-01` is not reachable from the internet. Finally, persistence was proven across a restart, the earlier verification scripts were re-run and diffed against the baseline, `configs/lab-09.env` (16 exports) was written, and the work was committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Screenshot 1 – Environment loaded (Step 1)**

![alt text](assets/1.png)

**Screenshot 2 – Security baseline (Step 2)**
![alt text](assets/2.png)

**Screenshot 3 – Floci support probe and path (Step 3)**

![alt text](assets/3.png)

**Screenshot 4 – Identity inventory (Step 4)**

![alt text](assets/4.png)
![alt text](assets/5.png)
![alt text](assets/6.png)


**Screenshot 5 – IAM audit findings (Step 5)**

![alt text](assets/7.png)



**Screenshot 6 – Transcripts policy read (Step 6)**

![alt text](assets/8.png)


**Screenshot 7 – Read-only policy, reader role and scoped trust (Step 7)**

![alt text](assets/9.png)

**Screenshot 8 – Boundary and scoped PassRole (Step 8)**

![alt text](assets/10.png)

**Screenshot 9 – Session policy and intersection (Step 9)**

![alt text](assets/13.png)

**Screenshot 10 – Access key rotation (Step 10)**

![alt text](assets/11.png)
![alt text](assets/12.png)

**Screenshot 11 – IMDSv2 on usms-web-01 (Step 11)**

![alt text](assets/14.png)

```bash
DB_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=usms-db-01" "Name=instance-state-name,Values=running" \
          --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 describe-instances --instance-ids "$DB_ID" \
  --query 'Reservations[0].Instances[0].[IamInstanceProfile.Arn,MetadataOptions]' --output json

aws ec2 modify-instance-metadata-options --instance-id "$DB_ID" \
  --http-endpoint disabled \
  || echo "not supported on this build - record it"

aws ec2 describe-instances --instance-ids "$DB_ID" \
  --query 'Reservations[0].Instances[0].MetadataOptions' --output json
```


**Screenshot 12 – Security group audit (Step 12)**

![alt text](assets/15.png)

**Screenshot 13 – Enrolment egress (Step 13)**

![alt text](assets/16.png)

**Screenshot 14 – ALB egress (Step 14)**

![alt text](assets/17.png)

**Screenshot 15 – Data tier egress (Step 15)**

![alt text](assets/18.png)

**Screenshot 16 – SSH narrowed to the bastion group (Step 16)**

![alt text](assets/19.png)

**Screenshot 17 – Reachability matrix and negative proof (Step 17)**

![alt text](assets/20.png)
![alt text](assets/21.png)

**Screenshot 18 – Persistence and regression (Step 18)**

![alt text](assets/22.png)

**Screenshot 19 – `configs/lab-09.env` (Step 19)**

![alt text](assets/23.png)


**Screenshot 20 – Verification and commit (Section 8, Step 20)**

![alt text](assets/24.png)

## Exercise 

# Lab 09 – Exercises (Your-turn tasks, Section 12 and Section 14)

**Student:** Khem Raj Ghalley
**Run every command from:** `~/Documents/4year/dso303/aws-floci-course`

> These solutions follow the Section 12 requirements on the course page. Output marked "Expected" is what the commands should produce; replace it with your own output and screenshots. Floci stores IAM and security group configuration but does not enforce it, so every proof here is a readback, and should be labelled that way.

## 0. Set up the shell (every new terminal)

```bash
cd ~/Documents/4year/dso303/aws-floci-course
source configs/course.env
for n in 01 02 03 04 05 06 09; do source configs/lab-$n.env 2>/dev/null; done
./scripts/utilities/whoami.sh

# Look security groups up by name, so no ID is typed by hand
sgid() { aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$USMS_VPC_ID" \
           --query 'SecurityGroups[0].GroupId' --output text; }
APP_SG=$(sgid usms-app-sg); ALB_SG=$(sgid usms-alb-sg); DB_SG=$(sgid usms-db-sg)
ENR_SG=$(sgid usms-enrolment-sg); BAS_SG=$(sgid usms-bastion-sg)
printf '%-12s %s\n' app "$APP_SG" alb "$ALB_SG" db "$DB_SG" enrolment "$ENR_SG" bastion "$BAS_SG"
```

All five must print an `sg-` ID. If any prints `None`, the `vpc-id` variable is empty; re-source `configs/lab-02.env`.

---

## Part A – The "Your turn" tasks inside Section 7

### A1. Step 4 – compare two trust policies

```bash
for R in usms-ec2-app-role usms-developer-role; do
  echo "== $R =="
  aws iam get-role --role-name "$R" --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal' --output json
done
```

**Answer for `notes/lab-09-notes.md`:**
> `usms-ec2-app-role` trusts a **service principal** (`ec2.amazonaws.com`): no person ever assumes it; EC2 obtains short-lived credentials on the instance's behalf and hands them to code on the instance through the metadata service. `usms-developer-role` trusts an **AWS principal** (an IAM user or the account): a person who already holds credentials calls `sts:AssumeRole` deliberately, so who obtains the credentials depends on which human identities the trust names, and how depends on their own keys or MFA.

### A2. Step 6 – transcript actions

**Answer for notes:**
> *Display a transcript (enrolment API):* `s3:GetObject` on `arn:aws:s3:::<bucket>/*`, plus `s3:ListBucket` on `arn:aws:s3:::<bucket>` if it lists a student's files or needs a clean "not found" (without `ListBucket`, S3 returns 403 instead of 404 for a missing key).
> *Upload a transcript (registry):* `s3:PutObject` on `/*` (and usually `s3:ListBucket` and `s3:GetObject` to check what is already there).
> *The one action only in the second list:* **`s3:PutObject`**. That single action is why the read-only policy and role exist.

### A3. Step 11 – metadata on `usms-db-01`, which has no instance profile

```bash
DB_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=usms-db-01" "Name=instance-state-name,Values=running" \
          --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 describe-instances --instance-ids "$DB_ID" \
  --query 'Reservations[0].Instances[0].[IamInstanceProfile.Arn,MetadataOptions]' --output json

aws ec2 modify-instance-metadata-options --instance-id "$DB_ID" \
  --http-endpoint disabled \
  || echo "not supported on this build - record it"

aws ec2 describe-instances --instance-ids "$DB_ID" \
  --query 'Reservations[0].Instances[0].MetadataOptions' --output json
```

**Expected:** `IamInstanceProfile` is `null`; after the change `HttpEndpoint: disabled` (or unchanged on Floci, known issue).

**Answer for notes:**
> For `usms-db-01`, which holds no role, the stronger setting is `--http-endpoint disabled`: there are no credentials to protect, so the metadata service has nothing to offer anyone. If the same setting were applied to `usms-web-01`, the instance would lose its **instance profile credentials**, because the AWS SDK on the instance fetches `usms-ec2-app-role` credentials from the metadata service (Lab 3 Step 11). Every AWS call from the web tier, such as reading transcripts from S3, would fail with "Unable to locate credentials". That is why the web instance gets `--http-tokens required` and a hop limit of 1 instead.

---

## Part B – Section 12 Independent Exercises

### Exercise 1 – Basic: finish the egress work on the web tier

**The five requirements, reasoned out:**

| # | Need | Rule | Why this destination |
|---|------|------|---------------------|
| 1 | S3 transcripts via the Lab 02 gateway endpoint | tcp/443 to the **S3 prefix list** | A gateway endpoint is reached through its prefix list, not an address |
| 2 | AWS endpoints over HTTPS, including STS | tcp/443 to `0.0.0.0/0` | Service endpoints have no fixed addresses without interface endpoints; traffic leaves through the IGW |
| 3 | Enrolment API through the load balancer | tcp/80 to **`usms-alb-sg`** | Since Lab 05 the web tier calls the ALB's DNS name; the ALB nodes carry `usms-alb-sg`, and the tasks only admit the ALB |
| 4 | Database on PostgreSQL | tcp/5432 to **`usms-db-sg`** | Group reference: follows `usms-db-01` if its address changes |
| 5 | Name resolution | **udp/53 and tcp/53 to `10.0.0.2/32`** | The Amazon resolver is the VPC CIDR base + 2 (`10.0.0.0/16` → `10.0.0.2`); DNS uses UDP and falls back to TCP for large answers |

Lab 2's reserved addresses in each subnet are `.0` (network), `.1` (VPC router), `.2` (Amazon DNS), `.3` (reserved for AWS) and `.255` (broadcast). The resolver lives at the **VPC** base + 2, so `10.0.0.2/32` is the exact destination, narrower than the whole VPC.

```bash
S3_PL=$(aws ec2 describe-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.${AWS_REGION_COURSE:-us-east-1}.s3" \
  --query 'PrefixLists[0].PrefixListId' --output text)
echo "S3 prefix list: $S3_PL"     # pl-...  (if None, drop rule 1 and record it; rule 2 still covers S3 over the internet)

# UNQUOTED heredoc: the document must contain the real prefix-list and group IDs,
# so $S3_PL, $ALB_SG and $DB_SG have to expand when the file is written.
cat > policies/usms-app-sg-egress.json << EOF
[
  { "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
    "PrefixListIds": [ { "PrefixListId": "$S3_PL", "Description": "S3 transcripts via the Lab 02 gateway endpoint" } ] },
  { "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
    "IpRanges": [ { "CidrIp": "0.0.0.0/0", "Description": "HTTPS to AWS service endpoints incl. STS" } ] },
  { "IpProtocol": "tcp", "FromPort": 80, "ToPort": 80,
    "UserIdGroupPairs": [ { "GroupId": "$ALB_SG", "Description": "Enrolment API through the load balancer (Lab 05)" } ] },
  { "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
    "UserIdGroupPairs": [ { "GroupId": "$DB_SG", "Description": "PostgreSQL to the data tier" } ] },
  { "IpProtocol": "udp", "FromPort": 53, "ToPort": 53,
    "IpRanges": [ { "CidrIp": "10.0.0.2/32", "Description": "DNS to the Amazon resolver (VPC base + 2), UDP" } ] },
  { "IpProtocol": "tcp", "FromPort": 53, "ToPort": 53,
    "IpRanges": [ { "CidrIp": "10.0.0.2/32", "Description": "DNS to the Amazon resolver, TCP fallback for large answers" } ] }
]
EOF

python3 -m json.tool policies/usms-app-sg-egress.json > /dev/null && echo "valid JSON"
grep -c '\$' policies/usms-app-sg-egress.json        # must print 0
grep -c '"None"' policies/usms-app-sg-egress.json    # must print 0
```

**Record the ingress first, so you can prove it did not change:**

```bash
aws ec2 describe-security-groups --group-ids "$APP_SG" --query 'SecurityGroups[0].IpPermissions' --output json \
  > outputs/lab-09-app-sg-ingress-before.json
```

**Authorise first, then revoke the default rule by its rule ID:**

```bash
aws ec2 authorize-security-group-egress --group-id "$APP_SG" \
  --ip-permissions file://policies/usms-app-sg-egress.json \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text

DEFAULT_RULE=$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$APP_SG" \
  --query "SecurityGroupRules[?IsEgress==\`true\` && IpProtocol=='-1' && CidrIpv4=='0.0.0.0/0'].SecurityGroupRuleId | [0]" \
  --output text)
echo "default egress rule: $DEFAULT_RULE"            # must be sgr-..., not None

aws ec2 revoke-security-group-egress --group-id "$APP_SG" --security-group-rule-ids "$DEFAULT_RULE"
```

**Why authorise before revoking:** if the default rule were revoked first, the group would have no egress for the moments in between, so live connections (DNS, STS credential refresh, database sessions) would fail. Authorising first means there is never a moment with no egress, and if the authorise fails, nothing has been lost.

**Verify:**

```bash
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$APP_SG" \
  --query 'SecurityGroupRules[?IsEgress==`true`].{Proto:IpProtocol,Port:FromPort,Cidr:CidrIpv4,PL:PrefixListId,Group:ReferencedGroupInfo.GroupId,Desc:Description}' \
  --output table

aws ec2 describe-security-groups --group-ids "$APP_SG" --query 'SecurityGroups[0].IpPermissions' --output json \
  | diff outputs/lab-09-app-sg-ingress-before.json - && echo "INGRESS UNCHANGED"

./scripts/utilities/usms-sg-audit.sh | grep -A8 usms-app-sg
./scripts/utilities/usms-reachability-matrix.sh | grep -i app
./scripts/utilities/verify-lab-09.sh | tail -2
```

**Expected:** six egress rules each with a description, no `-1` rule, `INGRESS UNCHANGED`, the audit showing written egress on `usms-app-sg`, and `FAIL=0`.

**Why `169.254.169.254` needs no rule:** the instance metadata service is a link-local address handled by the hypervisor (the Nitro system) on the host itself; the traffic never leaves the instance's host onto the VPC network, so security groups never see it. AWS also does not filter traffic to the Amazon DNS resolver with security groups, so rule 5 is belt-and-braces documentation of intent rather than something AWS requires. ✏️ *State this in your notes; it is the reasoning the exercise asks for.*

**Two sentences on `usms-bastion-sg`:**
> `usms-bastion-sg`'s egress differs in kind: the bastion is an administrative hop, not a service, so it should reach nothing on the internet and nothing except SSH to the instances it administers. Its egress should be tcp/22 to `usms-app-sg` (and `usms-db-sg` if the database is administered the same way), by group reference only.

### Exercise 2 – Intermediate: break-glass role and the two open findings

**Part A – `usms-breakglass-role`**

```bash
ADMIN_ARN=$(aws iam get-user --user-name usms-admin-01 --query 'User.Arn' --output text)
echo "$ADMIN_ARN"

# UNQUOTED heredoc: the admin ARN must expand.
cat > policies/trust-breakglass.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OnlyAdminWithMfaAndExternalId",
      "Effect": "Allow",
      "Principal": { "AWS": "$ADMIN_ARN" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "Bool":         { "aws:MultiFactorAuthPresent": "true" },
        "StringEquals": { "sts:ExternalId": "usms-breakglass-2026" }
      }
    }
  ]
}
EOF

# QUOTED heredoc: no variables.
cat > policies/usms-breakglass-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SuspendAndResumeEcsScalingOnly",
      "Effect": "Allow",
      "Action": [
        "application-autoscaling:DescribeScalableTargets",
        "application-autoscaling:RegisterScalableTarget"
      ],
      "Resource": "*"
    }
  ]
}
EOF

for f in policies/trust-breakglass.json policies/usms-breakglass-policy.json; do
  python3 -m json.tool "$f" > /dev/null && echo "$f valid"; grep -c '\$' "$f"
done

BOUNDARY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSPermissionsBoundary'].Arn | [0]" --output text)

aws iam create-role --role-name usms-breakglass-role \
  --assume-role-policy-document file://policies/trust-breakglass.json \
  --max-session-duration 3600 \
  --permissions-boundary "$BOUNDARY_ARN" \
  --description "Break-glass: suspend/resume ECS scaling only. MFA + ExternalId required." \
  --tags Key=Project,Value=USMS Key=Lab,Value=09 \
  --query 'Role.Arn' --output text

BG_POLICY_ARN=$(aws iam create-policy --policy-name USMSBreakGlassScaling \
  --policy-document file://policies/usms-breakglass-policy.json --query 'Policy.Arn' --output text)
aws iam attach-role-policy --role-name usms-breakglass-role --policy-arn "$BG_POLICY_ARN"

aws iam get-role --role-name usms-breakglass-role \
  --query 'Role.{Max:MaxSessionDuration,Boundary:PermissionsBoundary.PermissionsBoundaryArn,Trust:AssumeRolePolicyDocument.Statement[0].Condition}' \
  --output json
```

**Design notes (for the report):**
- **Shortest maximum session:** 3600 seconds (1 hour) is the smallest value IAM accepts for `MaxSessionDuration`; a caller can still request less with `--duration-seconds 900`.
- **Both conditions in one `Condition` block combine with AND.** Different condition operators (`Bool`, `StringEquals`) inside one block must all be true; only multiple *values* for the same key combine with OR. That is exactly what is wanted: MFA **and** the external ID.
- **What `sts:ExternalId` gives inside one account:** it is normally a cross-account control against confused deputies, but here it works as a deliberate "I mean it" step. Nobody assumes the role by accident or from a copied command or script, because they must know and type the external ID; it also lets CloudTrail record that the break-glass procedure, not routine work, was used. It is not a secret and not a substitute for MFA.
- **Exactly the Lab 06 calls:** Lab 06 suspended and resumed scaling with `register-scalable-target --suspended-state` and checked it with `describe-scalable-targets`; no wildcard actions. ✏️ On real AWS, `RegisterScalableTarget` may also need permissions on the ECS service and CloudWatch alarms it touches; record that as a limit you would test.
- **"A ten-second policy":** the permissions document has one statement and two actions, so anyone can read and understand it in ten seconds.

**Part B – the three unconditioned service trusts**

| Role | Principal | Decision | Reason |
|---|---|---|---|
| `usms-ecs-exec-role` | `ecs-tasks.amazonaws.com` | **Fix** | ECS sends `aws:SourceAccount` and `aws:SourceArn`, so the Step 7 conditions apply unchanged |
| `usms-lambda-exec-role` | `lambda.amazonaws.com` | **Fix** | Lambda sends `aws:SourceAccount` when assuming an execution role; scope it to the account |
| `usms-ec2-app-role` | `ec2.amazonaws.com` | **Accept** | EC2 delivers credentials through the instance metadata service and does not send `aws:SourceArn`; compensating control: IMDSv2 required and hop limit 1 (Step 11), plus no wildcard actions in its policy |

```bash
# Fix 1: ecs-exec-role reuses the Step 7 scoped trust
aws iam get-role --role-name usms-ecs-exec-role --query 'Role.AssumeRolePolicyDocument' --output json \
  > outputs/lab-09-ecs-exec-trust-before.json
aws iam update-assume-role-policy --role-name usms-ecs-exec-role \
  --policy-document file://policies/trust-ecs-tasks-scoped.json

# Fix 2: lambda-exec-role scoped to this account
cat > policies/trust-lambda-scoped.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaInThisAccountOnly",
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "aws:SourceAccount": "000000000000" } }
    }
  ]
}
EOF
aws iam get-role --role-name usms-lambda-exec-role --query 'Role.AssumeRolePolicyDocument' --output json \
  > outputs/lab-09-lambda-trust-before.json
aws iam update-assume-role-policy --role-name usms-lambda-exec-role \
  --policy-document file://policies/trust-lambda-scoped.json

for R in usms-ecs-exec-role usms-lambda-exec-role; do
  echo "== $R"; aws iam get-role --role-name "$R" --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
done
```

**Accepted-findings file (committed, one reason per line):**

```bash
cat > policies/usms-iam-accepted-findings.txt << 'EOF'
# role|check|reason (a finding without a reason is not accepted)
usms-ec2-app-role|unconditioned-service-trust|EC2 does not send aws:SourceArn; credentials come via IMDS. Compensating control: IMDSv2 required, hop limit 1 (Lab 09 Step 11). Reviewed 2026-11 by K. R. Ghalley.
EOF
```

**Make the audit read it.** Add this block to `scripts/utilities/usms-iam-audit.sh`, just before the line that prints the final `HIGH=… MED=…` summary and sets the exit code:

```bash
# --- accepted findings: read from a committed file, never hard-coded ---
ACCEPTED_FILE="$REPO_ROOT/policies/usms-iam-accepted-findings.txt"
is_accepted() {   # $1 = role, $2 = check
  [ -f "$ACCEPTED_FILE" ] || return 1
  grep -v '^#' "$ACCEPTED_FILE" | awk -F'|' -v r="$1" -v c="$2" \
    '$1==r && $2==c && length($3)>0 {found=1} END {exit !found}'
}
```

and, where each HIGH finding is printed and counted, wrap it like this:

```bash
if is_accepted "$ROLE" "$CHECK"; then
  printf "  ACCEPTED %-28s %s\n" "$ROLE" "$CHECK"
  ACCEPTED=$((ACCEPTED+1))
else
  printf "  HIGH     %-28s %s\n" "$ROLE" "$CHECK"
  HIGH=$((HIGH+1))
fi
```


```bash
bash -n scripts/utilities/usms-iam-audit.sh && echo "syntax ok"
./scripts/utilities/usms-iam-audit.sh | tail -6; echo "exit=$?"
```

**Expected:** `ACCEPTED usms-ec2-app-role unconditioned-service-trust`, a lower HIGH count, and exit code 1 only if other HIGH findings remain.



### Exercise 3 – Problem solving: the exposure report

```bash
cat > scripts/utilities/usms-exposure-report.sh << 'EOF'
#!/usr/bin/env bash
# Classify every network interface in usms-vpc as EXPOSED / PUBLIC-NO-INGRESS / ISOLATED.
# Verdicts come only from routes, public addresses and security group rules -
# never from names, tags or descriptions (those are only displayed).
#
# set -uo pipefail WITHOUT -e: this is a report. One failing lookup (a deleted group,
# a detached interface) must become a line in the report, not abort the whole run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
if [ -z "$VPC" ] || [ "$VPC" = "None" ]; then
  VPC=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=usms-vpc --query 'Vpcs[0].VpcId' --output text)
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/eni.json"
aws ec2 describe-security-groups    --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/sg.json"
aws ec2 describe-route-tables       --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/rt.json"
aws ec2 describe-subnets            --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/subnet.json"

# Shell gathers raw JSON; python3 does the joins and the reasoning.
python3 - "$TMP" "$VPC" << 'PY'
import ipaddress, json, subprocess, sys
tmp, vpc = sys.argv[1], sys.argv[2]
load = lambda n: json.load(open(f"{tmp}/{n}.json"))
enis = load("eni")["NetworkInterfaces"]
sgs = {g["GroupId"]: g for g in load("sg")["SecurityGroups"]}
rts = load("rt")["RouteTables"]
subnets = {s["SubnetId"]: s for s in load("subnet")["Subnets"]}
vpc_cidr = ipaddress.ip_network(next(iter(subnets.values()))["CidrBlock"]).supernet(new_prefix=16) if subnets else None

def group(gid):
    if gid not in sgs:                      # not in the cache: fetch it on its own
        r = subprocess.run(["aws", "ec2", "describe-security-groups", "--group-ids", gid,
                            "--output", "json"], capture_output=True, text=True)
        try:
            sgs[gid] = json.loads(r.stdout)["SecurityGroups"][0]
        except Exception:
            sgs[gid] = None
    return sgs[gid]

def route_table(subnet_id):
    for rt in rts:                          # explicit association first
        if any(a.get("SubnetId") == subnet_id for a in rt.get("Associations", [])):
            return rt
    for rt in rts:                          # otherwise the VPC's main route table
        if any(a.get("Main") for a in rt.get("Associations", [])):
            return rt
    return None

def internet_route(rt):
    if not rt:
        return False
    return any(r.get("DestinationCidrBlock") == "0.0.0.0/0" and str(r.get("GatewayId", "")).startswith("igw-")
               for r in rt.get("Routes", []))

def outside_ingress(group_ids):
    """Ingress rules whose source lies outside the VPC (internet-reachable sources)."""
    found, unknown = [], []
    for gid in group_ids:
        g = group(gid)
        if g is None:
            unknown.append(gid); continue
        for p in g.get("IpPermissions", []):
            port = "all" if p.get("IpProtocol") == "-1" else f'{p.get("FromPort")}'
            for r in p.get("IpRanges", []):
                net = ipaddress.ip_network(r["CidrIp"])
                if vpc_cidr is None or not net.subnet_of(vpc_cidr):
                    found.append(f'{port} from {r["CidrIp"]}')
    return found, unknown

rows = []
for e in enis:
    eid = e["NetworkInterfaceId"]
    att = e.get("Attachment") or {}
    display = e.get("Description") or att.get("InstanceId") or eid      # display only
    priv = e.get("PrivateIpAddress", "-")
    pub = (e.get("Association") or {}).get("PublicIp")
    gids = [g["GroupId"] for g in e.get("Groups", [])]
    rt = route_table(e.get("SubnetId"))
    igw = internet_route(rt)
    ing, unknown = outside_ingress(gids)
    notes = []
    if not att:
        notes.append("detached interface (leftover)")
    if unknown:
        notes.append("unknown group(s): " + ",".join(unknown))

    if pub and igw and ing:
        verdict, reason = "EXPOSED", f"public IP + IGW route + ingress {', '.join(sorted(set(ing)))}"
    elif pub and igw:
        verdict, reason = "PUBLIC-NO-INGRESS", "public IP + IGW route, but no ingress from outside the VPC" + \
                          (" (no security groups: e.g. NAT)" if not gids else "")
    else:
        why = []
        if not pub: why.append("no public IP")
        if not igw: why.append("no IGW route")
        verdict, reason = "ISOLATED", " + ".join(why)
    if notes:
        reason += " [" + "; ".join(notes) + "]"
    rows.append(dict(interface=eid, name=display[:38], private_ip=priv, public_ip=pub or "-",
                     verdict=verdict, reason=reason))

rows.sort(key=lambda r: ({"EXPOSED": 0, "PUBLIC-NO-INGRESS": 1, "ISOLATED": 2}[r["verdict"]], r["private_ip"]))
print(f'{"NAME":38} {"PRIVATE":15} {"PUBLIC":15} {"VERDICT":18} REASON')
for r in rows:
    print(f'{r["name"]:38} {r["private_ip"]:15} {r["public_ip"]:15} {r["verdict"]:18} {r["reason"]}')
json.dump({"vpc": vpc, "interfaces": rows}, open("outputs/lab-09-exposure.json", "w"), indent=2)
print(f"\n{len(rows)} interfaces; wrote outputs/lab-09-exposure.json")
PY
EOF

chmod +x scripts/utilities/usms-exposure-report.sh
bash -n scripts/utilities/usms-exposure-report.sh && echo "syntax ok"

./scripts/utilities/usms-exposure-report.sh | tee outputs/lab-09-exposure-repo.txt
(cd ~ && ~/Documents/4year/dso303/aws-floci-course/scripts/utilities/usms-exposure-report.sh) > outputs/lab-09-exposure-home.txt
diff outputs/lab-09-exposure-repo.txt outputs/lab-09-exposure-home.txt && echo "SAME FROM ANY DIRECTORY"
python3 -m json.tool outputs/lab-09-exposure.json > /dev/null && echo "valid JSON"
```

**Expected:** `usms-web-01` and the ALB node interfaces as `EXPOSED`; `usms-db-01` and the enrolment task interfaces as `ISOLATED`; the NAT interface as `PUBLIC-NO-INGRESS`; and `SAME FROM ANY DIRECTORY`. Because the verdict reads only **ingress**, the output is unchanged by Exercise 1's egress changes.

**Defending the NAT verdict:** a NAT gateway's interface has a public IP and an internet route, but it has no security groups and accepts no unsolicited inbound connections; it only forwards replies to connections started from inside. It is internet-facing but not a listening service, so calling it `EXPOSED` would be a false positive and calling it `ISOLATED` would hide the fact that it is public. `PUBLIC-NO-INGRESS` states exactly that.

**The four edge cases handled:** a group missing from the cache is fetched individually and, if still missing, named as `unknown group(s)`; an interface with no description falls back to its instance ID or interface ID (display only); a subnet with no explicit association uses the VPC's main route table; and a detached interface left behind by a terminated instance still gets a verdict, flagged `detached interface (leftover)`.

**Where shell stops and Python starts:** shell gathers four raw JSON documents (one API call each, no IDs hard-coded); Python does the joins, CIDR arithmetic and verdicts, because doing that in `jq` and `awk` would be harder to read and to check.

📸 Screenshot the report, `SAME FROM ANY DIRECTORY` and `valid JSON`.

### Exercise 4 – Challenge: the security review for the information security officer

**Write the review into `labs/lab-09-security/exercises.md`.** A draft follows; every ✏️ must be checked, and every cost needs a citation from the AWS pricing page linked. I have not quoted prices here, because they change and must be cited from the current page on the day you write.

**Build the transcripts access table from your own files first:**

```bash
python3 - << 'PY'
import json
inv = json.load(open('outputs/lab-09-identity-inventory.json'))
print(json.dumps(inv, indent=1)[:1500])   # inspect the structure, then fill the table below from it
PY
for P in USMSStudentDataReadWrite USMSStudentDataReadOnly; do
  ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$P'].Arn | [0]" --output text)
  echo "== $P"; aws iam list-entities-for-policy --policy-arn "$ARN" \
    --query '{Roles:PolicyRoles[].RoleName,Users:PolicyUsers[].UserName,Groups:PolicyGroups[].GroupName}' --output json
done
```

**Numbered command sequence to move the web tier behind the load balancer (written, NOT run):**

```bash
# 1. Create the web target group
aws elbv2 create-target-group --name usms-web-tg --protocol HTTP --port 80 \
  --vpc-id "$USMS_VPC_ID" --target-type instance --health-check-path / \
  --query 'TargetGroups[0].TargetGroupArn' --output text

# 2. Register usms-web-01
aws elbv2 register-targets --target-group-arn "$WEB_TG_ARN" --targets Id="$USMS_WEB_INSTANCE"

# 3. Add a listener rule for the portal (priority 20, below /alb-health at 10)
aws elbv2 create-rule --listener-arn "$USMS_ALB_LISTENER_ARN" --priority 20 \
  --conditions Field=path-pattern,Values='/portal','/portal/*' \
  --actions Type=forward,TargetGroupArn="$WEB_TG_ARN"

# 4. Admit the ALB to the web tier
aws ec2 authorize-security-group-ingress --group-id "$APP_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$ALB_SG,Description='HTTP from the ALB only'}]"
```

> ⚠️ **DANGER – step 5 removes public access to the web server.**
> **What is deleted:** the tcp/80 and tcp/443 ingress rules from `0.0.0.0/0` on `usms-app-sg`.
> **What breaks:** anything still using the Elastic IP or the instance's DNS name.
> **Undo:** re-authorise the two rules from a saved copy of the ingress before running this.

```bash
# 5. Remove the direct internet rules (by rule ID)
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$APP_SG" \
  --query "SecurityGroupRules[?IsEgress==\`false\` && CidrIpv4=='0.0.0.0/0'].SecurityGroupRuleId" --output text
aws ec2 revoke-security-group-ingress --group-id "$APP_SG" --security-group-rule-ids <rule-80> <rule-443>
```

> **DANGER – step 6 releases the web server's public address.**
> **What is deleted:** the Elastic IP association (and, if released, the address itself, which cannot be recovered).
> **What breaks:** SSH via the public IP, and any DNS record pointing at it.
> **Undo:** only re-association is possible if the EIP is kept; a released EIP is gone.

```bash
# 6. Disassociate (do not release) the Elastic IP
aws ec2 disassociate-address --association-id "$WEB_EIP_ASSOC_ID"
```


### Exercise 5 – Integration: the bucket policy the S3 lab will apply

```bash
cat > scripts/utilities/usms-bucket-policy-draft.sh << 'EOF'
#!/usr/bin/env bash
# Draft (never apply) the usms-student-data bucket policy from what IAM already grants.
# Reads policy documents only. Contains, reads and references no access key.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
RW_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)

# Bucket name comes from Lab 1's policy document, never typed.
BUCKET_ARN=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" \
  --query 'PolicyVersion.Document' --output json | python3 -c '
import json, sys, urllib.parse
d = json.load(sys.stdin)
d = json.loads(urllib.parse.unquote(d)) if isinstance(d, str) else d
for s in d["Statement"]:
    for r in ([s["Resource"]] if isinstance(s.get("Resource"), str) else s.get("Resource", [])):
        if r.startswith("arn:aws:s3:::") and "/" not in r:
            print(r); sys.exit()')
# Parameter expansion: strip everything up to and including ":::" to get the bare bucket name,
# without starting another process (cut/sed) for a one-field split.
BUCKET="${BUCKET_ARN##*:::}"
echo "bucket (from the policy): $BUCKET"

python3 - "$ACCOUNT" "$BUCKET" << 'PY'
import json, subprocess, sys, urllib.parse
account, bucket = sys.argv[1], sys.argv[2]
bucket_arn, objects_arn = f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"
targets = {bucket_arn, objects_arn}

def aws(*a):
    r = subprocess.run(["aws", *a, "--output", "json"], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {}

def doc(arn):
    ver = aws("iam", "get-policy", "--policy-arn", arn)["Policy"]["DefaultVersionId"]
    d = aws("iam", "get-policy-version", "--policy-arn", arn, "--version-id", ver)["PolicyVersion"]["Document"]
    return json.loads(urllib.parse.unquote(d)) if isinstance(d, str) else d

as_list = lambda x: [x] if isinstance(x, str) else (x or [])
statements, principals, sources = [], set(), []
for p in aws("iam", "list-policies", "--scope", "Local").get("Policies", []):
    d = doc(p["Arn"])
    for s in d.get("Statement", []):
        acts = [a for a in as_list(s.get("Action")) if a.startswith("s3:")]
        res = [r for r in as_list(s.get("Resource")) if r in targets]
        if s.get("Effect") != "Allow" or not acts or not res:
            continue
        roles = aws("iam", "list-entities-for-policy", "--policy-arn", p["Arn"]).get("PolicyRoles", [])
        arns = sorted(aws("iam", "get-role", "--role-name", r["RoleName"])["Role"]["Arn"] for r in roles)
        if not arns:
            continue
        sources.append(p["PolicyName"]); principals.update(arns)
        statements.append({"Sid": f"Allow{p['PolicyName']}{len(statements)}", "Effect": "Allow",
                           "Principal": {"AWS": arns}, "Action": sorted(acts), "Resource": sorted(res)})

statements.append({"Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
                   "Resource": [bucket_arn, objects_arn],
                   "Condition": {"Bool": {"aws:SecureTransport": "false"}}})
statements.append({"Sid": "DenyEveryoneElse", "Effect": "Deny",
                   "NotPrincipal": {"AWS": sorted(principals) + [f"arn:aws:iam::{account}:root"]},
                   "Action": "s3:*", "Resource": [bucket_arn, objects_arn]})

policy = {"Version": "2012-10-17", "Statement": statements}
json.dump(policy, open("outputs/lab-09-bucket-policy-draft.json", "w"), indent=2)

lines = [
  f"bucket name (from USMSStudentDataReadWrite): {bucket}",
  f"policies granting s3 on it: {', '.join(sorted(set(sources)))}",
  f"role ARNs: {', '.join(sorted(principals))}",
  f"principal count: {len(principals)}",
  "effect of Lab 10 create-bucket: the bucket starts to exist, so every listed role's identity "
  "policy becomes usable at once (read-write for three roles, read-only for the reader role), "
  "while this draft stays unapplied until the S3 lab.",
]
open("outputs/lab-09-lab10-readiness.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
EOF

chmod +x scripts/utilities/usms-bucket-policy-draft.sh
bash -n scripts/utilities/usms-bucket-policy-draft.sh && echo "syntax ok"
./scripts/utilities/usms-bucket-policy-draft.sh
```

**Validate the draft:**

```bash
python3 - << 'PY'
import json
p = json.load(open('outputs/lab-09-bucket-policy-draft.json'))
ok = True
for s in p['Statement']:
    pr = s.get('Principal', s.get('NotPrincipal'))
    star = pr == '*'
    if star and s['Sid'] != 'DenyInsecureTransport':
        ok = False; print('BAD "*" principal in', s['Sid'])
    if not star:
        arns = pr['AWS'] if isinstance(pr['AWS'], list) else [pr['AWS']]
        if not all(a.startswith('arn:aws:') for a in arns):
            ok = False; print('non-ARN principal in', s['Sid'])
res = {r for s in p['Statement'] for r in ([s['Resource']] if isinstance(s['Resource'], str) else s['Resource'])}
both = any(r.endswith('/*') for r in res) and any(not r.endswith('/*') for r in res)
print('principals OK' if ok else 'principal check FAILED')
print('bucket ARN with and without /*:', both)
PY
python3 -m json.tool outputs/lab-09-bucket-policy-draft.json > /dev/null && echo "valid JSON"
cat outputs/lab-09-lab10-readiness.txt
```

### 6.2 AWS Management Console Verification

This practical was performed on Floci, a local emulator with no AWS Management Console. Every control was verified by reading configuration back with the CLI (`get-role`, `get-policy-version`, `list-entities-for-policy`, `list-access-keys`, `describe-instances`, `describe-security-group-rules`), as shown in Section 6.1.

## 7. Analysis and Discussion

The review found and fixed the main identity and network weaknesses of the USMS estate. Because Floci stores IAM documents and security group rules but **does not enforce them**, every proof in this lab was made by reading configuration, not by observing a denial. That is a real limitation, and it is stated rather than hidden.

**2. Permissions boundary not shown on readback (Step 8) – known Floci 2.0.1 issue**
The course's Known Issues page records that after setting a permissions boundary, `get-role` shows none. `PermissionsBoundary: null` was therefore recorded as a known benign failure (the lab lists it as such in Section 8.1), and the boundary's effect was shown with the local policy-decision model (`student-fallback-demo.py security`): `s3:PutObject` is allowed by the identity policy but outside the boundary, so it is denied.

**3. IMDSv2 `HttpTokens` stays `optional` (Step 11) – known Floci 2.0.1 issue**
`modify-instance-metadata-options --http-tokens required` is accepted, but Floci still reads back `optional`, and it serves no metadata endpoint at all. This was recorded as configuration not demonstrated, and the token-gated endpoint in the same local demo showed the behaviour IMDSv2 adds (HTTP 401 without a token, 200 with one).

**4. Session policy and trust conditions not enforced (Steps 7 and 9)**
Floci returned credentials for the scoped session but ignored the session policy, and it does not check `aws:SourceAccount` / `aws:SourceArn`. The effective permissions were therefore computed from the documents (the intersection script), and the trust change was proven by comparing the before and after documents (`SAME PRINCIPAL, NEW CONDITION`).

**6. `simulate-principal-policy` and `get-account-authorization-details` unavailable (Step 3)**
These were reported "not available" by the probe, so the review relied on reading documents and on the inventory built from `list-roles`, `list-policies` and `list-entities-for-policy`.


### Observations

- **Trust and permissions are separate questions.** A trust policy decides who can become a role; its permissions decide what the role can then do. `usms-ecs-task-role` kept the same permissions but became harder to assume.
- **A boundary never grants anything.** Effective permissions are the intersection of the identity policy and the boundary, which is why the boundary is created but attached to nothing as a policy.
- **Order matters for safe changes:** create → move → deactivate → delete for keys; write the undo → authorise new → revoke old for security group rules.
- **Egress control limits what a compromised component can do next,** but HTTPS to `0.0.0.0/0` still allows data to leave over port 443; stopping that needs a proxy or AWS Network Firewall.
- **`usms-db-01` relies on five independent controls,** while the enrolment tasks rely mainly on one security group. More controls only help if they fail independently.
- **Reading configuration is a proof of intent, not of enforcement.** On real AWS, each control would also be tested by attempting a denied call.

## 8. Reflection

**1. What did you learn about this AWS service?**
I learned how IAM evaluates a request across trust policies, identity policies, permissions boundaries, session policies and explicit denies, and how the confused-deputy conditions and scoped `iam:PassRole` close gaps that ordinary policies leave open. On the network side, I learned that egress rules matter as much as ingress rules, and that security groups can reference each other instead of IP ranges.

**2. What challenges did you encounter?**
The main challenge was that Floci does not enforce IAM or security groups, so I could not prove a control by watching a call fail. I had to prove each control by reading it back and reasoning about it, and be careful to label boundary and IMDSv2 results as not reflected on this build. My counts also differed from the lab's examples because I had already completed Labs 07 and 08.

**3. How would you apply this service in a real-world cloud environment?**
I would give each workload its own role with only the actions it needs, add confused-deputy conditions to every service trust policy, use permissions boundaries for any role that can create other roles, replace long-lived user keys with IAM Identity Center for people and roles for workloads, require IMDSv2 on every instance, and write egress rules for every tier. I would then turn on CloudTrail, AWS Config and IAM Access Analyzer so changes are detected, not just prevented.

**4. What additional concepts or features would you like to explore?**
- IAM Access Analyzer and policy validation
- AWS Organizations service control policies
- S3 bucket policies and Block Public Access (Lab 10 and the S3 lab)
- AWS Network Firewall and egress proxies
- GuardDuty and Security Hub for detection
- IAM Identity Center for human access

## 9. Conclusion

The objectives of this practical were achieved at the configuration level. The review inventoried and audited every role and security group from Labs 01–06, then fixed the findings: a read-only transcripts policy and role, confused-deputy conditions, a scoped `iam:PassRole` with a permissions boundary, a session policy, a rotated access key, IMDSv2 on the web server, written egress on three security groups, bastion-only SSH, and a five-control proof that the database is not reachable from the internet. The controls survived a restart and no earlier lab regressed. Because Floci 2.0.1 does not enforce IAM or security groups, and does not reflect boundaries or IMDSv2 on readback, those results are labelled as configuration or alternative behaviour, not as observed enforcement.

This practical developed my skills in reading and writing IAM policies, designing least-privilege network rules and reviewing an environment systematically. It showed why security is part of cloud engineering from the start: every identity and network path built in earlier labs needed a second look before it could hold real student data.
