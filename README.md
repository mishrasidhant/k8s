# Virtualbox Kubernetes Cluster

Goal: 
- Provision and configure a basic K8s cluster 
- Include storage capabilities 
- Include "ingress" or "api-gateway" implementation

- Practice (for CKA)
  - Cluster installation
  - Node addtion/removal
  - Cluster Upgrade
  - API Gateway
  - CRDs

## Notes
> Trigger a preseed file using boot parameter
![alt text](image.png)

```
auto=true DEBIAN_FRONTEND=text preseed/file=/cdrom/preseed.cfg
```