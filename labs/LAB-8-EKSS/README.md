# Lab 08 – EKS Scaling and Service Exposure

## 1. Aim / Objective

The objective of this practical is to make the Lab 07 USMS microservices grow with demand and become reachable from outside the cluster. Specifically, to:

- Scale a Deployment by hand, declaratively from its manifest, and automatically with an `autoscaling/v2` HorizontalPodAutoscaler (HPA), and map the HPA to Lab 06's Application Auto Scaling.
- Change the managed node group's scaling configuration from the AWS side, as a separate control loop from the HPA.
- Use resource requests, QoS classes, `nodeSelector` and PodDisruptionBudgets, including their limits.
- Climb the exposure ladder (port-forward, NodePort, LoadBalancer, Ingress) and compare Ingress with Lab 05's ALB.
- Prove the configuration survives a restart and save it to `configs/lab-08.env`.

## 2. Introduction

Kubernetes on **Amazon EKS** scales at two independent layers. At the workload layer, the **HorizontalPodAutoscaler** is a controller inside the cluster that reads pod CPU from the metrics API and changes a Deployment's `replicas`. At the infrastructure layer, the **managed node group** (an EC2 Auto Scaling group) decides how many nodes exist, changed by hand or by Cluster Autoscaler or Karpenter. The two loops do not talk to each other: an HPA can ask for pods the nodes have no room for.

Exposure works as a ladder of **Service** types. A **ClusterIP** is reachable only inside the cluster; a **NodePort** opens the same port (30000–32767) on every node; a **LoadBalancer** asks the cloud for a load balancer in front of those ports; and an **Ingress** describes HTTP routing rules that an Ingress controller turns into a layer-7 proxy (on EKS, the AWS Load Balancer Controller creates an ALB). These features matter in cloud computing because they let a service follow demand automatically while giving users one stable address.

### Key Features

- HorizontalPodAutoscaler (`autoscaling/v2`) with scale-up and scale-down `behavior` policies
- Metrics pipeline (metrics-server and `kubectl top`)
- Resource requests and limits, and the three QoS classes
- Managed node group scaling (`minSize` / `maxSize` / `desiredSize`)
- `nodeSelector` and node labels for placement
- PodDisruptionBudgets for voluntary disruptions such as drains
- Service types ClusterIP, NodePort and LoadBalancer
- Ingress with path-based routing, mapped to the AWS Load Balancer Controller

## 3. Use Case

The **University Student Management System (USMS)** sees traffic rise sharply during enrolment week and on results night.

| Requirement                                          | Kubernetes / EKS feature used                                      |
| ---------------------------------------------------- | ------------------------------------------------------------------ |
| Enrolment must add pods when busy and shrink after   | HPA on `usms-enrolment`: 2–8 replicas at 50% CPU                   |
| Scale up fast, scale down slowly                     | HPA `behavior`: scale-up window 0 s, scale-down window 300 s       |
| More nodes when pods no longer fit                   | Node group raised to min 2 / max 6 / desired 3                     |
| Enrolment pods only on USMS nodes                    | `nodeSelector: workload=usms`                                      |
| Node maintenance without taking the portal down      | PodDisruptionBudgets on the gateway and enrolment                  |
| A fixed port for the Examinations Office test tools  | NodePort Service `usms-results-np` on 30080                        |
| One public address for students                      | Gateway Service changed to `type: LoadBalancer`                    |
| Path routing at the edge, like Lab 05's listener rules | Ingress `usms-portal-ingress`: `/enrolment`, `/results`, `/`     |

Other common uses include autoscaling web APIs and queue workers, exposing many microservices through one ALB with Ingress, and protecting stateful workloads during cluster upgrades with PDBs.

## 4. System Architecture / Design

```
                    Internet / my machine
                             |
              localhost:8081 / 8082  (from the _lb_ports_ tag)
                             |
      +----------------------+------------------------------+
      |  Ingress usms-portal-ingress   (class: traefik ✏️)   |
      |    /enrolment -> svc usms-enrolment:80               |
      |    /results   -> svc usms-results:80                 |
      |    /          -> svc usms-gateway:80                 |
      |  Service usms-gateway   type LoadBalancer            |
      |  Service usms-results-np type NodePort  :30080       |
      +----------------------+------------------------------+
                             |
   namespace usms            v
   +----------------------------------------------------------------+
   | Deployment usms-enrolment  2..8 replicas  nodeSelector workload=usms |
   |   ^ HPA usms-enrolment-hpa  cpu 50% of the 50m request         |
   |   |   scaleUp: window 0s, +100% or +2 pods / 15s (max)          |
   |   |   scaleDown: window 300s, -1 pod / 60s                      |
   |   |   reads metrics.k8s.io  <-- metrics-server                  |
   |   PDB usms-enrolment-pdb  maxUnavailable 1                      |
   | Deployment usms-gateway    1 replica                            |
   |   PDB usms-gateway-pdb    minAvailable 1  (allows 0 disruptions)|
   | Deployment usms-results    2 replicas                           |
   | Deployment usms-loadgen    3 replicas  (temporary load source)  |
   +----------------------------------------------------------------+

   CONTROL LOOP 1 (in the cluster):  HPA  -> Deployment.spec.replicas
   CONTROL LOOP 2 (AWS side):        you / Cluster Autoscaler / Karpenter
                                     -> usms-eks-nodes scalingConfig
                                        min 2  max 6  desired 3
   Pods the nodes cannot fit stay Pending until loop 2 adds capacity.
```

**Data flow:** a request reaches the Ingress controller (or the LoadBalancer Service) → the path rule picks a backend Service → kube-proxy sends it to a ready pod. Meanwhile, metrics-server samples pod CPU, the HPA compares it with 50% of the request, and writes a new replica count.

## 5. Implementation Procedure

The practical began by starting Floci, sourcing the Lab 01–07 environment files and running `verify-lab-07.sh`, then confirming the two Lab 07 prerequisites this lab depends on: the `50m` CPU request on `usms-enrolment` and the `_lb_ports_` cluster tag (`8081,8082`). A baseline of Deployments, endpoints, Service types and nodes was saved to `outputs/lab-08-baseline.txt`.

Scaling started by hand: `kubectl scale` raised `usms-enrolment` to 5 replicas while endpoints were watched, and requests through the gateway reached 4–5 distinct pods before it was scaled back to 2. Declarative scaling then showed configuration drift: with the cluster at 6 and the manifest at 2, `kubectl diff` reported the difference and `kubectl apply` reverted the cluster to the file. Pod QoS classes were read from the cluster (Burstable for the Lab 07 containers), and the HPA arithmetic was worked through as a percentage of the request.

The metrics pipeline was checked through the `metrics.k8s.io` API and `kubectl top`. The HPA `usms-enrolment-hpa` (min 2, max 8, 50% CPU) was created from `manifests/lab-08/10-hpa-enrolment.yaml` with a scale-up window of 0 seconds and a scale-down window of 300 seconds. A three-replica busybox load generator drove CPU above the target while `hpa-watch.sh` recorded the replica count, and the load was then removed to observe the slow scale-down.

On the AWS side, the node group was read and an update to min 2 / max 6 / desired 3 was attempted with `update-nodegroup-config`. Cluster Autoscaler and Karpenter were compared conceptually, and a `nodeSelector` of `workload=usms` was enforced on `usms-enrolment`, tested with a non-existent label (new pod `Pending`, old pods serving) and written back into the Lab 07 manifest. Two PodDisruptionBudgets were applied; an eviction through the eviction API was refused while `kubectl delete pod` was not, and a drain was dry-run.

Finally the exposure ladder was climbed: a ClusterIP was shown unreachable from the host and reached through `kubectl port-forward`; `usms-results-np` exposed results on NodePort 30080; the gateway Service was replaced with a `type: LoadBalancer` manifest; and the Ingress `usms-portal-ingress` added path routing, with its annotations mapped to Lab 05's `aws elbv2` commands. ECS and EKS were compared in the notes, persistence was proven across a Floci restart, the values were written to `configs/lab-08.env` (19 exports), and the work was committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Screenshot 1 – Environment and Lab 07 prerequisites (Step 1)**

![alt text](assets/1.png)
![alt text](assets/2.png)

**Screenshot 2 – Baseline (Step 2)**

![alt text](assets/3.png)

**Scale by hand, and watch what moves (Step 4)**
![alt text](assets/4.png)


**Screenshot 4 – Declarative drift (Step 5)**
![alt text](assets/5.png)


**Screenshot 5 – QoS classes, and the gateway made Guaranteed (Step 6)**

![alt text](assets/6.png)

**make usms-gateway Guaranteed, then restore it**
```bash
qos() { kubectl get pods -n usms -l app=usms-gateway -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'; }

qos | tee outputs/lab-08-qos-before.txt                 # Burstable

kubectl set resources deployment/usms-gateway -n usms \
  --requests=cpu=200m,memory=128Mi --limits=cpu=200m,memory=128Mi
kubectl rollout status deployment/usms-gateway -n usms --timeout=120s
qos | tee outputs/lab-08-qos-guaranteed.txt             # Guaranteed, NEW pod name

kubectl set resources deployment/usms-gateway -n usms \
  --requests=cpu=50m,memory=32Mi --limits=cpu=200m,memory=128Mi
kubectl rollout status deployment/usms-gateway -n usms --timeout=120s
qos | tee outputs/lab-08-qos-restored.txt               # Burstable again, another new pod
```
![alt text](assets/7.png)

**Screenshot 6 – Metrics pipeline (Step 7)**

![alt text](assets/8.png)

**Screenshot 7 – HPA created (Step 8)**

![alt text](assets/9.png)

**Screenshot 8 – Load test: scale-up (Step 9)**

![alt text](assets/10.png)


**Screenshot 10 – Node group scaling attempt (Step 10)**

![alt text](assets/11.png)

**Screenshot 11 – nodeSelector enforced (Step 11)**

![alt text](assets/12.png)

**Screenshot 12 – PodDisruptionBudgets (Step 12)**

![alt text](assets/13.png)


**Screenshot 13 – ClusterIP and port-forward (Step 13)**

![alt text](assets/14.png)
![alt text](assets/15.png)

**Screenshot 14 – NodePort 30080 (Step 14)**

![alt text](assets/16.png)

**Screenshot 15 – LoadBalancer (Step 15)**

![alt text](assets/17.png)
![alt text](assets/18.png)

**Screenshot 16 – Ingress (Step 16)**

![alt text](assets/19.png)


**Screenshot 17 – ECS vs EKS side by side (Step 17)**

![alt text](assets/20.png)


**Screenshot 18 – Persistence across restart (Step 18)**

![alt text](assets/21.png)
![alt text](assets/22.png)

**Screenshot 19 – `configs/lab-08.env` (Step 19)**

![alt text](assets/23.png)


**Verification, smoke test and commit**

![alt text](assets/24.png)


### Exercise

**Exercise 1 - Basic: a second autoscaler**

```bash
kubectl get deploy usms-results -n usms \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'; echo   # 50m
```

```bash
cat > manifests/lab-08/11-hpa-results.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: usms-results-hpa
  namespace: usms
  labels:
    app: usms-results
    project: usms
    tier: app
    lab: "08"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: usms-results
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
        - type: Pods
          value: 2
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 180
      selectPolicy: Min
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
EOF

kubectl apply --dry-run=client -f manifests/lab-08/11-hpa-results.yaml
kubectl apply -f manifests/lab-08/11-hpa-results.yaml
sleep 45
kubectl get hpa -n usms
kubectl describe hpa usms-results-hpa -n usms | sed -n '/Conditions:/,/Events:/p'
```

![alt text](assets/25.png)

**Exercise 2 – Intermediate: a drainable gateway**

```bash
kubectl get pdb -n usms
kubectl get deploy usms-gateway -n usms -o jsonpath='{.spec.replicas}'; echo   # 1
```

```bash
cp manifests/lab-07/40-gateway.yaml outputs/lab-08-40-gateway.before.yaml

python3 - << 'PY'
p = 'manifests/lab-07/40-gateway.yaml'
docs = open(p).read().split('\n---\n')
kept = [d for d in docs if not ('kind: Service' in d and 'name: usms-gateway' in d)]
text = '\n---\n'.join(kept)
text = text.replace('  replicas: 1\n', '  replicas: 2\n', 1)
open(p, 'w').write(text if text.endswith('\n') else text + '\n')
print('documents kept:', len(kept), '(ConfigMap + Deployment)')
PY

grep -n 'replicas:' manifests/lab-07/40-gateway.yaml          # replicas: 2
kubectl diff -f manifests/lab-07/40-gateway.yaml || true       # only replicas 1 -> 2
kubectl apply -f manifests/lab-07/40-gateway.yaml
kubectl rollout status deployment/usms-gateway -n usms --timeout=120s
kubectl diff -f manifests/lab-07/40-gateway.yaml && echo "CLEAN DIFF"

kubectl get pdb usms-gateway-pdb -n usms                       # ALLOWED DISRUPTIONS 1
kubectl get pods -n usms -l app=usms-gateway -o wide           # NODE column
kubectl get svc usms-gateway -n usms                           # still LoadBalancer
```

![alt text](assets/26.png)

**Exercise 3 - Problem solving: the autoscaler that will not act**

![alt text](assets/27.png)


**Exercise 4 – Challenge: expose results properly**

```bash
kubectl get ingress usms-portal-ingress -n usms -o jsonpath='{range .spec.rules[*].http.paths[*]}{.path} -> {.backend.service.name}{"\n"}{end}'
#   /enrolment -> usms-enrolment
#   /results   -> usms-results
#   /          -> usms-gateway
```

```bash
cat > manifests/lab-08/61-ingress-exams.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: usms-portal-ingress
  namespace: usms
  labels:
    project: usms
    tier: web
    lab: "08"
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/group.name: usms-portal
    alb.ingress.kubernetes.io/tags: Project=USMS,Tier=web,Lab=08
spec:
  rules:
    - http:
        paths:
          - path: /exams
            pathType: Prefix
            backend:
              service:
                name: usms-results
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: usms-gateway
                port:
                  number: 80
EOF

kubectl diff -f manifests/lab-08/61-ingress-exams.yaml || true    # removes /enrolment and /results, adds /exams
kubectl apply -f manifests/lab-08/61-ingress-exams.yaml
kubectl describe ingress usms-portal-ingress -n usms
```

![alt text](assets/28.png)

**Exercise 5 – Integration: Lab 10 artefacts and the argument**

```bash
python3 - << 'PY'
import datetime, json, subprocess

def run(*cmd):
    r = subprocess.run(list(cmd), capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return {"unavailable": (r.stderr.strip() or "no output")[:300]}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"raw": r.stdout.strip()}

hpa = run("kubectl", "get", "hpa", "usms-enrolment-hpa", "-n", "usms", "-o", "json")
dep = run("kubectl", "get", "deploy", "usms-enrolment", "-n", "usms", "-o", "json")
ng  = run("aws", "eks", "describe-nodegroup", "--cluster-name", "usms-eks-cluster",
          "--nodegroup-name", "usms-eks-nodes", "--output", "json")

doc = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "hpa": {"spec": hpa.get("spec", hpa), "status": hpa.get("status")} if "spec" in hpa else hpa,
    "deployment_replicas": {
        "spec": dep.get("spec", {}).get("replicas"),
        "ready": dep.get("status", {}).get("readyReplicas"),
    } if "spec" in dep else dep,
    "nodegroup": ng.get("nodegroup", {}).get("scalingConfig", ng) if "nodegroup" in ng else ng,
}
json.dump(doc, open("outputs/lab-08-scaling-evidence.json", "w"), indent=2)
print("wrote outputs/lab-08-scaling-evidence.json")
PY

python3 -m json.tool outputs/lab-08-scaling-evidence.json > /dev/null && echo "valid JSON"
```

![alt text](assets/29.png)

### 6.2 AWS Management Console Verification

This practical was performed on Floci, a local emulator with no AWS Management Console. The node group was verified with `aws eks describe-nodegroup` and `list-updates`, and all Kubernetes objects with `kubectl get`, `describe` and `top`, as shown in Section 6.1.

## 7. Analysis and Discussion

The workload half of this lab ran on a real Kubernetes API, so manual and declarative scaling, QoS, the HPA (given metrics), `nodeSelector`, PDBs and the Service types behaved as they would on EKS. The infrastructure half is where Floci stops: node group changes are not enacted, and external addresses depend on what the emulator publishes to the host.


**1. `update-nodegroup-config` fails (Step 10) – known Floci 2.0.1 issue**
The course's Known Issues page records that `aws eks update-nodegroup-config` fails on this build, so the node group could not be resized. The before readback (min 2 / max 4 / desired 2) and the error were recorded, and the documented alternative was used: the HPA drill from Steps 8–9, which proves that load changes pod replicas but does **not** prove that nodes are added.


**2. HPA showing `<unknown>/50%` (Steps 8–9)**
An HPA computes utilisation as a percentage of the CPU **request**, from the `metrics.k8s.io` API. `describe hpa` names the cause: `failed to get cpu utilization` means the metrics pipeline is down, and `missing request for cpu` means the Deployment has no request. On k3s, metrics-server is usually built in, so a new HPA only needs 15–60 seconds before it reports a percentage.


**3. `kubectl scale` reverted (after Step 8)**
Once the HPA exists it owns `spec.replicas`, so a manual `kubectl scale` is overwritten within about 15 seconds. This is correct behaviour, not a fault: to scale by hand the HPA must be removed temporarily.

### Observations

- The HPA and the node group are two separate control loops. The HPA can only ask for pods; something else must add nodes, or the extra pods sit in `Pending`.
- The HPA target is a percentage of the **request**, not of the node: two pods at 40m against a 50m request are at 80%, so the HPA asks for ceil(2 × 80 / 50) = 4 pods. Halving the request doubles the reported utilisation.
- Scale up eagerly and scale down reluctantly appears again, as in Lab 06: here it is the 0 s and 300 s stabilisation windows instead of ECS cooldowns.
- Lab 06's Application Auto Scaling ran outside the workload and used CloudWatch alarms; the HPA runs in the controller manager and reads an in-cluster metrics API, with no alarms at all.
- A PDB only governs voluntary disruptions through the eviction API. `kubectl delete pod` and a node crash both bypass it.
- Each Service type includes the one below it: a LoadBalancer has a NodePort, which has a ClusterIP.
- An Ingress spec plus annotations replaces the separate `elbv2` load balancer, target group, listener and rule calls from Lab 05, and routes by longest matching path instead of numeric priority.

## 8. Reflection

**1. What did you learn about this AWS service?**
I learned that scaling on EKS happens in four dimensions (pod count, pod size, node count, node size), each controlled by a different object, and that the HPA and the node group are independent control loops. I learned how the HPA's `behavior` section shapes scaling, why requests matter for both scheduling and autoscaling, and how Services, NodePorts, LoadBalancers and Ingress build on each other to expose an application.

**2. What challenges did you encounter?**
The main challenge was separating what the cluster actually did from what the emulator could not do. The Kubernetes side was real, but the node group update failed, and external addresses depended on host port publishing. I also had to remember that once an HPA exists, manual scaling no longer sticks, and that a PDB does not stop a direct `kubectl delete`.

**3. How would you apply this service in a real-world cloud environment?**
For USMS on real EKS I would run the HPA on every user-facing Deployment, pair it with Karpenter so new pods always find capacity, and pre-scale before enrolment opens because reactive scaling is late. I would expose the portal with one Ingress through the AWS Load Balancer Controller rather than several LoadBalancer Services, add HTTPS with ACM, and give every Deployment a PDB that allows at least one disruption so node upgrades can proceed.

**4. What additional concepts or features would you like to explore?**
- Karpenter NodePools and consolidation
- KEDA for event-driven and scheduled scaling
- HPA on custom metrics (requests per second, queue depth)
- Vertical Pod Autoscaler in recommendation mode
- AWS Load Balancer Controller with ACM certificates and WAF
- Gateway API as the successor to Ingress

## 9. Conclusion

The workload-level objectives of this practical were achieved: `usms-enrolment` was scaled manually, declaratively and automatically with an `autoscaling/v2` HPA, placement was controlled with `nodeSelector`, disruptions were limited with PodDisruptionBudgets, and the services were exposed through ClusterIP, NodePort, LoadBalancer and Ingress, with the configuration surviving a restart. The infrastructure-level objective, resizing the node group, was attempted and recorded, but Floci 2.0.1 does not enact it, so node scaling and the AWS controllers are described as conceptual rather than claimed.

This practical developed my skills in Kubernetes autoscaling, capacity reasoning, Service exposure and honest evidence. It showed why scaling and exposure are central to cloud-native systems: an application must grow with demand at both the pod and node layers, and present one stable address while its pods come and go.
