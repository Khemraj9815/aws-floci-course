# Lab 10 – Serverless at the Edge: Lambda@Edge, CloudFront and an S3-Triggered Lambda

## 1. Aim / Objective

The objective of this practical is to use AWS Lambda in two very different places in the USMS architecture, using only the AWS CLI. Specifically, to:

- Create the `usms-student-data` bucket as both the CloudFront origin and the transcript store that Labs 01 and 09 already named.
- Build two **Lambda@Edge** functions (viewer-request and origin-response), invoke them with CloudFront event payloads, publish versions, and check them against the edge restrictions.
- Associate both functions with a CloudFront distribution (or validate the configuration where CloudFront is unavailable) and prove they work together with a local edge simulator.
- Build a **regional** S3-triggered notifier with a version, an alias and a scoped resource policy, and prove it ran.
- Prove everything survives a restart and save the identifiers to `configs/lab-10.env`.

## 2. Introduction

**AWS Lambda** runs code without servers: you upload a function, choose a runtime, memory and timeout, and Lambda runs it in response to an event, billing per request and per GB-second of execution. A function has an **execution role** (what the function may call) and a **resource policy** (who may invoke the function). **Versions** are immutable snapshots of code and configuration, and **aliases** are movable names pointing at a version.

**Lambda@Edge** runs Lambda functions inside **Amazon CloudFront**, AWS's content delivery network, at four points in a request: viewer request, origin request, origin response and viewer response. Because the code is replicated to edge locations worldwide, it has strict limits: it must be created in `us-east-1`, be referenced by a published version (never `$LATEST` or an alias), have no environment variables and no VPC, and, for viewer triggers, use at most 128 MB and 5 seconds. A **regional** Lambda, by contrast, runs in one region, can use environment variables and longer timeouts, and is typically triggered by events such as an S3 upload.

Serverless functions matter in cloud computing because they remove server management for event-driven work and let small pieces of logic run exactly where they are needed: at the edge for request handling close to users, or in the region for background processing.

### Key Features

- Function runtimes (Node.js, Python), memory and timeout settings
- Execution roles and resource-based policies
- Immutable versions and movable aliases
- Lambda@Edge triggers: viewer request, origin request, origin response, viewer response
- Edge restrictions (published version, no env vars, no VPC, size and time caps)
- CloudFront distributions, cache keys and TTLs
- S3 event notifications that invoke Lambda
- CloudWatch Logs for every invocation

## 3. Use Case

The **University Student Management System (USMS)** needs to deliver student transcripts quickly to students and employers, and to tell the registry when a new transcript is uploaded.

| Requirement                                              | Serverless feature used                                              |
| -------------------------------------------------------- | -------------------------------------------------------------------- |
| Serve transcripts fast to readers anywhere               | CloudFront distribution `usms-transcript-cdn` in front of `usms-student-data` |
| Refuse transcript requests without a student identity before reaching the origin | Lambda@Edge viewer-request `usms-edge-viewer-request` (403 at the edge) |
| Normalise URLs so one transcript has one cache entry     | Viewer-request lowercases the URI                                    |
| Add security headers and cache rules to every response   | Lambda@Edge origin-response `usms-edge-origin-response`              |
| Notify the registry when a transcript JSON is uploaded   | Regional `usms-transcript-notifier`, triggered by S3 `ObjectCreated` on `transcripts/*.json` |
| Release notifier changes safely and roll back instantly  | Version 1 and alias `live`                                           |
| Only our bucket may trigger the notifier                 | Resource policy scoped by `--source-arn` and `--source-account`      |

Other common uses include image resizing and A/B routing at the edge, authentication checks before content is served, and regional functions for file processing, queue consumers and scheduled jobs.

## 4. System Architecture / Design

```
                              Student / employer browser
                                         |
                                         v
            +-------------------- CloudFront: usms-transcript-cdn --------------------+
            |  cache key: URI + x-usms-student   TTL default 300 s, max 3600 s        |
            |                                                                         |
            |  (1) VIEWER REQUEST  usms-edge-viewer-request:1   nodejs20.x 128 MB 5 s |
            |        lowercase URI; /transcripts/* without x-usms-student -> 403      |
            |        (origin never contacted); else stamp x-usms-edge                 |
            |                    |                                                    |
            |                 cache miss                                              |
            |                    v                                                    |
            |  ORIGIN  usms-student-data.s3.us-east-1.amazonaws.com                   |
            |                    |                                                    |
            |  (2) ORIGIN RESPONSE usms-edge-origin-response:1  nodejs20.x 128 MB 5 s |
            |        add HSTS, nosniff, X-Frame-Options DENY, Referrer-Policy;        |
            |        /transcripts/ -> cache-control public, max-age=300, s-maxage=3600|
            |        append ;origin-response to x-usms-edge-chain                     |
            +-------------------------------------------------------------------------+

   REGIONAL (us-east-1)
   registry upload -> s3://usms-student-data/transcripts/....json
                        | ObjectCreated:* , prefix transcripts/ , suffix .json
                        | notification id usms-transcript-upload
                        v
             usms-transcript-notifier:live  (-> version 1)   python3.12 256 MB 30 s
               env USMS_BUCKET, USMS_NOTIFY_CHANNEL
               resource policy: s3.amazonaws.com, source-arn = this bucket, source-account
               logs USMS_NOTIFY lines -> /aws/lambda/usms-transcript-notifier

   IDENTITY
   usms-lambda-exec-role  trusts lambda.amazonaws.com + edgelambda.amazonaws.com
                          -> USMSLambdaBasic (logs, s3:GetObject)
```

**Data flow (edge):** request → viewer-request function decides allow or deny → cache → origin S3 → origin-response function adds headers → cached and returned. **Data flow (regional):** upload → S3 event → `live` alias → notifier logs a `USMS_NOTIFY` line.

## 5. Implementation Procedure

The practical began by starting Floci, confirming `floci-storage-check.sh` reported `PASS=16 FAIL=0`, sourcing the environment files from Labs 01–09 and creating the three function directories under `labs/lab-10-lambda-edge/`. A support probe confirmed that Lambda, S3 and CloudWatch Logs were supported and recorded whether CloudFront was available, which selected Path A or Path B for Step 15.

The bucket `usms-student-data` was created, which turned the Lab 01 and Lab 09 transcript policies from names into a real resource. The trust policy of `usms-lambda-exec-role` was replaced with one trusting both `lambda.amazonaws.com` and `edgelambda.amazonaws.com`, because Lambda@Edge needs both.

The viewer-request function was written in Node.js (with a quoted heredoc so its template literals were not expanded by the shell), packaged and created with `nodejs20.x`, 128 MB and 5 seconds. It was invoked directly with CloudFront event payloads for an allowed request and a denied one, its logs were decoded from `--log-type Tail`, and version 1 was published. The origin-response function was built the same way, invoked with an origin-response event, and published as version 1. The edge restrictions were then tested: environment variables were set on the viewer function on purpose and removed, and an eligibility check confirmed both functions met every edge rule at version 1.

The CloudFront distribution configuration (`templates/lab-10-distribution-config.json`) associated both version-qualified ARNs, with a cache key of the URI plus `x-usms-student`. Because no emulator runs Lambda@Edge, `usms-edge-simulate.sh` ran the two functions in CloudFront's order to prove they compose: three stages on the allow path, and a single 403 stage on the deny path.

The regional notifier was written in Python, created with `python3.12`, 256 MB and 30 seconds, published as version 1, and given an alias `live`. A resource policy allowed S3 to invoke only the alias, scoped to this bucket and account, and a bucket notification sent `ObjectCreated` events for `transcripts/*.json` to it. An upload under `transcripts/evidence/` was then checked in the notifier's logs (or, where delivery was missing, with a synthetic S3 event). Finally, persistence was proven across a restart, `configs/lab-10.env` was written with 25 exports, and the work was committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Screenshot 1 – Environment and storage check (Steps 1–2)**

![alt text](assets/1.png)
![alt text](assets/2.png)

**Screenshot 2 – Support probe and path (Step 4)**
![alt text](assets/3.png)
![alt text](assets/4.png)



**Screenshot 3 – Bucket created (Step 5)**

![alt text](assets/5.png)


**Screenshot 4 – Two-principal trust policy (Step 6)**

![alt text](assets/6.png)


**Screenshot 5 – Viewer-request function created (Step 8)**

![alt text](assets/7.png)


**Screenshot 6 – Allow invocation (Step 9)**

![alt text](assets/9.png)


**Screenshot 7 – Deny invocation (Step 9 Your turn)**

![alt text](assets/10.png)

**Exercise**
![alt text](assets/11.png)


**Screenshot 8 – Logs (Step 10)**

![alt text](assets/12.png)


**Screenshot 9 – Version 1 published (Step 11)**

![alt text](assets/11.png)


**Screenshot 10 – Origin-response function and invocation (Steps 12–13)**

![alt text](assets/13.png)

**Screenshot 11 – Edge restrictions (Step 14)**

![alt text](assets/14.png)

**Screenshot 12 – CloudFront distribution (Step 15)**

![alt text](assets/15.png)

![alt text](assets/16.png)

**Screenshot 13 – Edge simulator (Step 16)**

![alt text](assets/17.png)

**Screenshot 14 – Notifier created, versioned and aliased (Steps 17–18)**

![alt text](assets/18.png)
![alt text](assets/19.png)

**Screenshot 15 – Alias moved and restored**

![alt text](assets/20.png)


**Screenshot 16 – Resource policy (Step 19)**

![alt text](assets/21.png)

**Screenshot 17 – Bucket notification and upload (Step 20)**

![alt text](assets/22.png)

**Screenshot 18 – Proof the notifier ran (Step 21)**


![alt text](assets/23.png)


**Screenshot 20 – Persistence (Step 22)**

![alt text](assets/24.png)

**Screenshot 21 – `configs/lab-10.env` (Step 23)**

![alt text](assets/25.png)


**Exercise 1**

![alt text](assets/26.png)



### 6.2 AWS Management Console Verification

This practical was performed on Floci, a local emulator with no AWS Management Console. Functions, versions, aliases, policies, the bucket and the distribution were verified with read-back CLI commands (`get-function-configuration`, `list-versions-by-function`, `get-alias`, `get-policy`, `get-bucket-notification-configuration`, `get-distribution`), as shown in Section 6.1.

## 7. Analysis and Discussion

The function contract was demonstrated directly: both edge functions transformed real CloudFront event payloads correctly, the deny path returned a 403 without a `uri`, and the simulator showed the two functions compose in CloudFront's order. What could not be demonstrated is Lambda@Edge itself: the course's Known Issues page records that there is no global edge execution locally, and no emulator replicates functions to edge locations. That gap is stated, not hidden.

### Observations

- **Edge and regional functions are designed differently.** The edge functions hard-code their configuration, stay at 128 MB and 5 seconds and make no network calls; the regional notifier uses environment variables, more memory and a 30-second timeout, and calls S3.
- **CloudFront needs a version, not a name.** Every association uses an ARN ending `:1`, because an edge function is replicated and must not change underneath the distribution; aliases are fine for the regional notifier.
- **A deny at viewer request is cheap:** the origin is never contacted and nothing is cached, which is why the deny response carries `cache-control: no-store`.
- **Two policies, two directions:** the execution role controls what the notifier may call; the resource policy controls who may invoke it.
- **Replace-only APIs are dangerous:** `update-assume-role-policy` and `put-bucket-notification-configuration` replace the whole document, so the trust policy had to list both principals and later labs must merge notifications.
- **A command that succeeds is not proof.** Floci accepted environment variables and unqualified ARNs that real CloudFront would reject, so the checks had to be written explicitly.

## 8. Reflection

**1. What did you learn about this AWS service?**
I learned how Lambda functions are built, versioned and aliased, how an execution role differs from a resource policy, and how S3 can trigger a function. I also learned how Lambda@Edge differs from regional Lambda: the four CloudFront triggers, the strict limits on edge functions, and why CloudFront requires a published version rather than `$LATEST`.

**2. What challenges did you encounter?**
The biggest challenge was that no local emulator runs Lambda@Edge, so I had to prove the functions in pieces: invoking each with a CloudFront event and then running the simulator in CloudFront's order. I also had to be careful with shell quoting, because an unquoted heredoc would have emptied the JavaScript template literals, and with Floci accepting configurations that real CloudFront would reject.

**3. How would you apply this service in a real-world cloud environment?**
For USMS I would serve transcripts through CloudFront with an origin access control so the bucket is never public, use a CloudFront Function or Lambda@Edge viewer-request to check a signed session token, keep security headers at origin-response so they are cached once, and use regional Lambda functions behind aliases for background work such as notifications, with a staged rollout by moving the alias between versions.

**4. What additional concepts or features would you like to explore?**
- CloudFront Functions and CloudFront KeyValueStore
- Origin access control and signed URLs
- AWS WAF on CloudFront
- Lambda weighted aliases for canary releases
- Amazon EventBridge and SQS as Lambda triggers
- S3 versioning, encryption and lifecycle rules (the next lab)

## 9. Conclusion

The objectives of this practical were achieved at the function level. The `usms-student-data` bucket was created, two Lambda@Edge functions were built, invoked with real CloudFront event payloads, versioned and checked against the edge restrictions, and a CloudFront distribution configuration associated them by version. A regional notifier with a version, an alias and a scoped resource policy was triggered by S3 uploads, and everything survived a restart. Because no emulator runs Lambda@Edge at edge locations, the edge behaviour was proven with the lab's simulator and labelled as alternative behaviour rather than claimed.

This practical developed my skills in Lambda packaging, versioning, IAM for serverless functions, CloudFront configuration and event-driven design. It showed why serverless is central to cloud-native systems: small pieces of logic can run exactly where they are needed, at the edge close to users or in the region behind an event, without managing any servers.

