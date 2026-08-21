## Lab 01 Notes

**IAM**

Never attach policy to all the users instead, create a group and attach the policy to the group. Then add users to the group. This way, we can manage the permissions of all the user effectively.

**Floci Storage**

- Floci default storage is in memory. Once the power is lost, all the data will be lost.
- It also deletes docker volumes itself.
- New start --> new volume. Floci clean itself
- floci start, floci restart, and docker desktop restart will brings container back to default state. 

