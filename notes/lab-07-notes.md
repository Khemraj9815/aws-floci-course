## Lab 07 

### Step 3 – "EKS is just ECS with different names"
The statement is false because on EKS the right-hand (data plane) column is mine: I run, patch and pay for the nodes, and I need a separate node role that trusts ec2.amazonaws.com, while ECS on Fargate leaves that column almost empty. An upgrade is also two operations (cluster version, then node group version). It is nearly true because both take a declared container spec, keep N copies running, replace failed ones, and give them a stable name behind a load balancer; a task definition maps to a pod template, and an ECS service maps to a Deployment plus a Service.

**Exercise 16**: I deleted one of the two pods in the Deployment.The replacement was created by the ReplicaSet controller (owned by the Deployment), which noticed that only one of the two desired pods existed and created another; neither the Deployment directly nor I created it.


## Step 20 - ECS and Kubernetes, compared with both running

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | | |
| What keeps N copies alive? | | |
| What gives it a stable name? | | |
| How does another service find it? | | |
| What does a rolling update create? | | |
| Where does rollback state live? | | |
| Which IAM role does the app code use? | | |
| What would I have to change to move to another cloud? | | |

Two sentences: which one would I choose for USMS, and why.
