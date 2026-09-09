# OCI infrastructure recovery

The original Terraform source is currently unavailable. The likely authoritative
state remains in OCI Object Storage. Reconstruct configuration here only after
taking an encrypted independent state backup.

Safety requirements:

- preserve the existing state lineage and serial;
- reproduce the current VM and public-network design first;
- reach a zero-change plan before any apply;
- protect the instance and boot volume from destruction;
- treat migration to a private subnet as a separate reviewed change.
