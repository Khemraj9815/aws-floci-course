## Lap Practical 01: Identity and Access Management

**Aims/Objectives**

**Introduction**

### Procedure 

Starting with completion of persistent storage for the floci and its health.

![alt text](../screenshots/1.png)
![alt text](../screenshots/2.png)
![alt text](../screenshots/3.png)

it looks like the persistent storage is set up correctly and the floci is healthy. lets proceed with the next step of the practical that is installing the aws cli amd configure floci aws CLI profile.

![alt text](../screenshots/4.png)

This shows that 
![alt text](../screenshots/5.png)

Run aws configure list --profile floci. Identify which column tells you where each value came from, and explain why the Type for the access key says shared-credentials-file.
- The LOCATION column tells where each value came from. The Type for the access key says shared-credentials-file because it is stored in the shared credentials file, which is located at ~/.aws/credentials.

Executing my first aws command 
![alt text](../screenshots/6.png)
![alt text](../screenshots/7.png)
It shows that I am not real aws user by looking at the userid.

![alt text](../screenshots/9.png)
It shows that my floci is persisted.

![alt text](../screenshots/8.png)
this output shows that everything is working perfectly fine.

![alt text](../screenshots/10.png)
This output shows that floci is not using stray vlolume.


