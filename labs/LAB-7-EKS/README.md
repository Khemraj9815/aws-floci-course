# Lab 07 – Deploying a Microservices Application on Amazon EKS

## 1. Aim / Objective

The objective of this practical is to run the USMS application as a set of microservices on Amazon Elastic Kubernetes Service (EKS), building every AWS object with the AWS CLI and every Kubernetes object from declarative manifests. Specifically, to:

- Create an EKS cluster and a managed node group inside the Lab 02 VPC, each with its own IAM role.
- Point `kubectl` at the cluster and deploy three microservices (`usms-gateway`, `usms-enrolment`, `usms-results`) from YAML manifests.
- Prove that the services discover each other by DNS name, then perform a rolling update, a rollback and three deliberate failure diagnoses.
- Use a ConfigMap and a Secret, and demonstrate what a Secret does not protect.
- Prove the cluster survives a restart and save its identifiers to `configs/lab-07.env` for Lab 08.

## 2. Introduction

**Amazon EKS** is AWS's managed Kubernetes service. AWS runs the Kubernetes **control plane** (the API server, etcd, the scheduler and the controller managers) across multiple Availability Zones, and the customer provides the **data plane**: the worker nodes on which pods run. A **managed node group** lets EKS create and update those nodes as an Auto Scaling group of EC2 instances.

Kubernetes describes an application as objects. A **Deployment** keeps a set number of identical **pods** running through a **ReplicaSet**; a **Service** gives those pods a stable virtual IP and DNS name; **ConfigMaps** and **Secrets** inject configuration; and **namespaces** group related objects. Because these objects are standard, the same manifests run on any conformant Kubernetes cluster. EKS is important in cloud computing because it combines that portability with AWS integration: IAM for identity, the VPC for networking, and load balancers and autoscaling for production traffic.

### Key Features

- Managed, highly available Kubernetes control plane
- Managed node groups with min / max / desired sizing
- Pods with real VPC IP addresses through the Amazon VPC CNI
- Built-in service discovery through CoreDNS and kube-proxy
- Declarative rolling updates and rollbacks
- ConfigMaps and Secrets (with optional KMS envelope encryption)
- IAM Roles for Service Accounts (IRSA) for per-pod AWS permissions
- Upstream Kubernetes conformance, so manifests are portable

## 3. Use Case

The **University Student Management System (USMS)** at the College of Science and Technology is split into independent services, so each can be updated, scaled and debugged on its own.

| Requirement                                         | How EKS / Kubernetes meets it                                          |
| --------------------------------------------------- | ---------------------------------------------------------------------- |
| One entry point for students                        | `usms-gateway` (nginx) routes `/enrolment/` and `/results/`            |
| Enrolment must survive a pod failure                | `usms-enrolment` runs 2 replicas; the ReplicaSet replaces lost pods    |
| Services must find each other without hard-coded IPs | Cluster DNS: `usms-enrolment.usms.svc.cluster.local`                   |
| New releases without downtime                       | Rolling updates with `maxUnavailable: 0`, and `rollout undo`           |
| Shared settings across services                     | ConfigMap `usms-app-config` (environment, campus, version, region)     |
| Credentials kept out of images                      | Secret `usms-enrolment-secret`                                         |
| Ready to autoscale in Lab 08                        | CPU and memory requests declared on every container                    |

Other common uses of EKS include running microservice platforms across many teams, machine-learning and batch workloads, hybrid deployments with EKS Anywhere, and migrating existing Kubernetes workloads to AWS without rewriting their manifests.

## 4. System Architecture / Design

```
                              MY MACHINE
   aws CLI  ------------------------------->  Floci (port 4566)
                                                 |  creates and manages
                                                 v
   kubectl  ------- https://localhost:6443 -->  EKS control plane (k3s API server)
                                                 |  schedules pods onto
                                                 v
                                       usms-eks-nodes (2 nodes)

                      INSIDE THE CLUSTER - namespace "usms"
   +-----------------------------------------------------------------------+
   |  Service usms-gateway (ClusterIP :80)                                  |
   |    └── Deployment usms-gateway  1 replica   nginx reverse proxy        |
   |          /enrolment/ -> usms-enrolment.usms.svc.cluster.local:80       |
   |          /results/   -> usms-results.usms.svc.cluster.local:80         |
   |                                                                        |
   |  Service usms-enrolment (ClusterIP)      Service usms-results (ClusterIP)|
   |    └── Deployment, 2 replicas              └── Deployment, 2 replicas    |
   |        requests cpu=50m mem=32Mi               default 25% strategy     |
   |        readiness + liveness /healthz           readiness /healthz       |
   |        maxUnavailable 0, maxSurge 1                                     |
   |                                                                        |
   |  ConfigMaps: usms-app-config, usms-enrolment-conf,                      |
   |              usms-results-conf, usms-gateway-conf                       |
   |  Secret:     usms-enrolment-secret   (base64, NOT encrypted)            |
   |  ServiceAccount: usms-enrolment-sa   (IRSA-ready on real AWS)           |
   +-----------------------------------------------------------------------+

                      AWS-SIDE OBJECTS, IN LAB 02's VPC
   usms-vpc 10.0.0.0/16
     public-a / public-b    -> cluster resourcesVpcConfig (endpoint, Lab 08 LB)
     private-a / private-b  -> cluster resourcesVpcConfig + node group placement
     usms-eks-cluster-sg    -> tcp/443 from 10.0.0.0/16 only

   usms-eks-cluster-role  trusts eks.amazonaws.com -> USMSEKSClusterPolicy
   usms-eks-node-role     trusts ec2.amazonaws.com -> USMSEKSNodePolicy
                                                  -> USMSStudentDataReadWrite (Lab 01)
```

**Data flow:** a request to `usms-gateway` → nginx matches the path → resolves the backend Service name through CoreDNS to a ClusterIP → kube-proxy forwards to one ready endpoint pod → the pod returns JSON naming itself.

## 5. Implementation Procedure

The practical began by starting Floci, loading the environment files from Labs 01–04 and confirming with `verify-lab-02.sh` that all four Lab 02 subnets existed across two Availability Zones. A probe script (`eks-support-probe.sh`) checked whether the `eks` API answered and which local tools were installed, and recorded the support path in `notes/lab-07-notes.md`.

On the AWS side, two trust policies were written (the cluster role trusting `eks.amazonaws.com` and the node role trusting `ec2.amazonaws.com`), together with two local permissions policies standing in for the AWS managed EKS policies. The cluster role, the node role and the cluster security group `usms-eks-cluster-sg` (TCP 443 from the VPC CIDR only) were created, and Lab 01's `USMSStudentDataReadWrite` was attached unchanged to the node role as its third holder. The cluster request body was generated with an unquoted heredoc so it contained real subnet and security-group IDs, including the `_lb_ports_` tag Lab 08 depends on. While holding assumed `usms-developer-role` credentials, `usms-eks-cluster` was created across all four subnets; the identity was then restored. After the cluster reached `ACTIVE`, the managed node group `usms-eks-nodes` (min 2, max 4, desired 2) was created in the two private subnets only.

`aws eks update-kubeconfig` connected `kubectl` to the cluster, and the namespace `usms` was created and set as the context default. Three microservices were deployed from numbered manifests: `usms-enrolment` (2 replicas, requests, readiness and liveness probes, `maxUnavailable: 0`), `usms-results` (2 replicas, default strategy) and `usms-gateway` (an nginx proxy that routes by DNS name). Service discovery was proven from inside a busybox pod with `nslookup`, and twelve requests through the gateway were tallied to show load spread across both enrolment pods.

A Secret was created and decoded with `base64 -d` to show that it is encoded, not encrypted, then injected into the enrolment Deployment. A ConfigMap change was rolled out, inspected with `rollout history` and reverted with `rollout undo`. Three failures were produced deliberately and diagnosed with `describe` and `logs`: `ImagePullBackOff`, `Pending`/`FailedScheduling` and `CrashLoopBackOff`. The ECS and Kubernetes models were compared side by side, IRSA was traced as far as the build allowed, persistence was proven across a Floci restart by re-deriving every identifier from the API, and the identifiers were written to `configs/lab-07.env` and committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Screenshot 1 – Environment, identity and four subnets (Step 1)**

![image](assets/1.png)
![image](assets/2.png)

**Support probe and recorded path (Step 2)**

![image](assets/3.png)

**Write the two trust policies**

![alt text](assets/4.png)

**Write the two permissions policies**
![alt text](assets/5.png)


**Cluster role and security group (Step 6)**
![alt text](assets/6.png)



**Create the noode role and Lab 01 policy's three holders (Step 7)**
![alt text](assets/7.png)

**Cluster request body and creation (Step 8)**

![alt text](assets/8.png)
![alt text](assets/9.png)

**Cluster ACTIVE and `_lb_ports_` tag (Step 9)**

![alt text](assets/10.png)
**Exercise**
![alt text](assets/11.png)

**Managed node group (Step 10)**

![alt text](assets/12.png)

**Kubectl connected (Step 11)**
![alt text](assets/13.png)

**Namespace (Step 12)**

![alt text](assets/14.png)

**usms-enrolment deployed and serving (Step 13)**

![alt text](assets/15.png)

**usms-results and strategy comparison (Step 14)**
![alt text](assets/16.png)

<!-- **Gateway deployed (Step 15)** -->


**Service discovery and load spreading (Step 16)**

![alt text](assets/17.png)

**Self-healing (Step 16 Your-turn)**

![alt text](assets/18.png)

**Secret decoded and consumed (Step 17)**

![alt text](assets/19.png)

**Rolling update and rollback (Step 18)**

![alt text](assets/20.png)

**Exercise**: Rolling update and rollback (Step 18)**
![alt text](assets/21.png)
![alt text](assets/22.png)

**Three failures diagnosed (Step 19)**

![alt text](assets/23.png)
![alt text](assets/24.png)

**ECS and EKS side by side (Step 20)**

![alt text](assets/25.png)

**IRSA trace (Step 21)**

![alt text](assets/26.png)

**Persistence across restart (Step 22)**

![alt text](assets/27.png)

**`configs/lab-07.env` (Step 23)**

![alt text](assets/28.png)


**Exercise 1 - Basic: a fourth microservice**




### 6.2 AWS Management Console Verification

This practical was performed on Floci, a local emulator with no AWS Management Console. AWS-side objects were verified with read-back CLI commands (`describe-cluster`, `describe-nodegroup`, `get-role`, `list-attached-role-policies`, `describe-security-groups`), and Kubernetes objects with `kubectl get`, `describe` and in-cluster requests, as shown in Section 6.1.

## 7. Analysis and Discussion

Unlike Labs 05 and 06, the Kubernetes half of this lab is real: Floci starts a genuine k3s cluster, so Deployments, Services, DNS discovery, rollouts and failure modes all behaved exactly as they would on EKS. The AWS half (IAM policies, node group sizing, instance types and the VPC CNI) was recorded but not enforced. The observed results matched the expected outcomes.


**1. Gateway in `CrashLoopBackOff` with `host not found in upstream`**
nginx resolves `proxy_pass` hostnames once at start-up. If the gateway starts before the enrolment and results Services exist, nginx exits and the pod restarts repeatedly. Applying the manifests in numeric order (`20-`, `30-`, then `40-`) avoids it; when it happened, `kubectl rollout restart deployment/usms-gateway` after the Services existed fixed it.

**2. `kubectl` credential plugin error (`aws eks get-token`)**
If the exec-plugin in the generated kubeconfig is unsupported, `kubectl` cannot authenticate. The fix is the certificate-based kubeconfig from `k3d kubeconfig get`, saved to `outputs/lab-07-kubeconfig.yaml` with `chmod 600`, and confirmed git-ignored, because a kubeconfig with embedded certificates is itself a credential.

**3. Pods `Pending` because only a control-plane node exists**
A control-plane node carries a `NoSchedule` taint. If no worker nodes registered, pods cannot be scheduled. The correct fix is the node group (Step 10); the local-only workaround of removing the taint must be recorded, because it would be unsafe on a real cluster.

**4. Configuration change did not reach the pods (Step 18)**
After editing `usms-app-config`, the enrolment pods still reported `1.0.0`. ConfigMaps are read when a container starts, so changing one does not restart pods. Annotating the Deployment's own metadata did not change the pod template either, so `kubectl rollout restart` was used, which writes a timestamp into the template and creates a new ReplicaSet.    

### Observations

- `kubectl` and the AWS CLI talk to two different endpoints (port 6443 and port 4566). The only link between them is that one created the other.
- Nothing in the namespace mentions AWS. The manifests are portable; the IAM roles, VPC, node group and `_lb_ports_` tag are not.
- The gateway holds two DNS names and no IP addresses. Pods can be deleted and replaced while the gateway keeps working.
- Readiness controls Service membership; liveness controls restarts. Mixing them up turns a slow service into a restarting one.
- With `maxUnavailable: 0`, the bad-image update never removed a working pod: old pods kept serving while the new one sat in `ImagePullBackOff`.
- `kubectl describe` answers "why" for failures where the container never started; `kubectl logs` only helps once it has.

## 8. Reflection

**1. What did I learn about this AWS service?**
I learned how EKS splits responsibility: AWS runs the control plane, while I run the data plane and its node role. I learned to express an application as Deployments, Services, ConfigMaps and Secrets, and that Kubernetes keeps the declared state by replacing pods automatically. I also learned that a Secret is only base64-encoded, and that IRSA is the correct way to give individual pods AWS permissions.

**2. Challenges encountered**
The main challenge was the number of moving parts across two tools: IAM roles that must trust different principals, heredocs that must be quoted for manifests but unquoted for request bodies, and `kubectl` contexts. The most instructive moment was the rollback that did not revert the version, which showed that configuration outside the pod template is not part of a Deployment's history.

**3. How would you apply this service in a real-world cloud environment?**
I would run the same manifests on EKS with nodes in private subnets across at least two AZs, expose the gateway through the AWS Load Balancer Controller, enable KMS envelope encryption for Secrets, use IRSA or EKS Pod Identity instead of node-role permissions, add PodDisruptionBudgets and topology spread constraints, and deploy through a GitOps pipeline so configuration is versioned with the workload.

## 9. Conclusion

The objectives of this practical were achieved. An EKS cluster and a managed node group were created in the Lab 02 VPC with separate IAM roles, and three USMS microservices were deployed declaratively into namespace `usms`. Service discovery by DNS, load spreading, self-healing, rolling updates, rollback, Secret handling and three failure modes were all demonstrated on a real Kubernetes API, and the configuration survived a restart. Features that depend on real AWS infrastructure, such as IAM enforcement, the VPC CNI, IRSA and KMS encryption of Secrets, were recorded or explained rather than claimed.

This practical strengthened my skills in Kubernetes, `kubectl`, YAML manifests, IAM for EKS and systematic troubleshooting. It showed why Kubernetes is central to cloud-native systems: it keeps a declared state, finds services by name and replaces failed components without manual intervention.
