### Step 3 – a plan for ten times the traffic
1. Dimension 3 first (node count): raise the node group's maxSize and desiredSize so there is room before anything asks for pods; check with kubectl get nodes that the new nodes are Ready and kubectl describe nodes shows allocatable CPU.
2. Dimension 1 (pod count): raise the HPA's maxReplicas (for example 8 → 20); check with kubectl get hpa and kubectl get pods that no pod is Pending.
3. Dimension 2 (pod size), only if measurements justify it: adjust requests and limits from load-test data, remembering that this restarts every pod and changes the HPA's percentage; check kubectl top pods against the new request.
4. Dimension 4 (node size) last: larger instance types cannot be changed in place, so it means a new node group, cordoning and draining the old one, and deleting it; check the PDBs allow the drain first.

Note from step 6: the pod name changed twice, because resources are part of the pod template and Kubernetes cannot resize a running pod in place here. Every vertical change restarts pods, which is why the Vertical Pod Autoscaler is used far less than the HPA.
## Step 17 - Practical 2 and Practical 4, compared with both running

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | | |
| Who writes it? | | |
| Where does that thing run? | | |
| Where does the metric come from? | | |
| What does "50% CPU" mean - 50% of what? | | |
| How is scale-in slowed down? | | |
| What happens if there is no capacity for the new instance/pod? | | |
| What creates the alarms, if anything? | | |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | | |
| What is the target type, and why? | | |
| How are targets registered and deregistered? | | |
| How are competing routing rules disambiguated? | | |
| What would I change to move this to another cloud? | | |
| What is the cost of exposing ten services? | | |

### Two paragraphs, in prose

1. If the AWS control plane has a bad afternoon, what happens to each of the two
   scaling arrangements, and which of them can I still debug?

2. For USMS specifically - one small team, one region, quiet for eight months and
   very busy for two - which would I choose, and what is the strongest argument
   AGAINST my own choice?
