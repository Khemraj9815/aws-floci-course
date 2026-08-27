## Virtual Private Cloud and Networking

**Aims/Objectives**
- To create web tier which can be accessed from the public internet
- Data tier which is not accessible from the public internet



**Prerequisites**
everything is perfectly fine to start with practical 2.
![alt text](../../screenshots/p2-1.png)

- aws accepts the vpc CIDR block in the range of /16 to /28.
- subnet CIDR block must be a subset of the VPC CIDR block.
- each subnet must not overlap with any other subnet in the VPC

**Assume the developer role and create the VPC**

making sure I am in right place to create the VPC.
![alt text](../../screenshots/P2-2.png)
It shows that I am in the right region and lets create VPC

![alt text](../../screenshots/p2-3.png)
VPC created

**Restore your normal identity**

From my perspective, in this step we are restoring the normal identity after creating the VPC. because we created the VPC using the developer role, now we need to switch back to our normal identity. and that user have session duration of 1 hour. 
![alt text](../../screenshots/p2-4.png)

**Enable DNS support and DNS hostnames**

when vpc is created using CLI it automatically enables DNS resolution but does not enable DNS hostnames. 
- Means no public DNS name for instances with public IP addresses.
- Service endpoints inside the VPC won't resolve to their private addresses.
- To avoid confusion later, let's enable DNS hostnames now.

![alt text](../../screenshots/p2-5.png)
completed enabling DNS support and DNS hostnames.

**Create and attach the internet gateway**

Internet gateway is VPC component that allows communication between instances in VPC the internet.
![alt text](../../screenshots/p2-6.png)
![alt text](../../screenshots/p2-7.png)

Internet gateway is created and attached to the VPC. It can be attached to only one VPC at a time. 