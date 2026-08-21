## Lap Practical 01: Identity and Access Management

**Aims/Objectives**

**Introduction**

### Procedure 

Starting with completion of persistent storage for the floci and its health.
![alt text](../../screenshots/1.png)
![alt text](../../screenshots/1.png)
![alt text](../../screenshots/2.png)
![alt text](../../screenshots/3.png)

it looks like the persistent storage is set up correctly and the floci is healthy. lets proceed with the next step of the practical that is installing the aws cli amd configure floci aws CLI profile.

![alt text](../../screenshots/4.png)

This shows that 
![alt text](../../screenshots/5.png)

Run aws configure list --profile floci. Identify which column tells you where each value came from, and explain why the Type for the access key says shared-credentials-file.
- The LOCATION column tells where each value came from. The Type for the access key says shared-credentials-file because it is stored in the shared credentials file, which is located at ~/.aws/credentials.

Executing my first aws command 
![alt text](../../screenshots/6.png)
![alt text](../../screenshots/7.png)
It shows that I am not real aws user by looking at the userid.

![alt text](../../screenshots/9.png)
It shows that my floci is persisted.

![alt text](../../screenshots/8.png)
this output shows that everything is working perfectly fine.

![alt text](../../screenshots/10.png)
This output shows that floci is not using stray vlolume.

End of part A

### Building the IAM Foundation

**4 IAM building blocks**

USER: identity that represents a person or service that interacts with AWS resources.
GROUP: group of users that share the same permissions.
ROLE: identity that can be assumed by anyone who needs it.
POLICY: A JSON object that says ALLOW or DENY access to AWS resources.

basic rules to remember:
- Default deny: all requests are denied by default, unless explicitly allowed.
- Explicit deny always wins: if a request is explicitly denied, it will be denied even if there is an allow policy that would otherwise allow it.

![alt text](../../screenshots/11.png)
My account exist, but there is no user created yet. 



Run aws iam list-roles --output table. Floci may pre-create some service-linked roles. Are the results the same in text format? Which one would you use inside a script, and why?
- I would use the table format because when there is no user created, text format doesn't show any output. The table format shows the table with the column names and the values, which is more readable.

**Create the IAM groups**

![alt text](../../screenshots/12.png)
![alt text](../../screenshots/13.png)

created an empty IAM group. A group has no permissions and no members.

![alt text](../../screenshots/14.png)
It shows IAM group created

