Step 4: CreateServiceLinkedRole -> UnsupportedOperation on Floci 2.0.1.
get-role: NoSuchEntity. Recorded as an emulator limitation.
On real AWS this role would hold ecs:UpdateService for Application Auto Scaling,
and Step 5 would fail without it. Floci does not assume roles, so it does not block the lab here.
