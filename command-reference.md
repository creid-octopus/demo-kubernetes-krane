# Command Reference

## Install cert-manager (prereq for Octopus Permissions Controller)

[Docs](https://cert-manager.io/docs/installation/helm/)

```bash
helm install \
  cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.1 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

## Helm value customizations (required for non-default agent tooling)

[Docs](https://octopus.com/docs/kubernetes/targets/kubernetes-agent#agent-tooling)

```bash
  --set scriptPods.deploymentTarget.image.repository="ghcr.io/creid-octopus/demo-kubernetes-krane-toolbox" \
  --set scriptPods.deploymentTarget.image.tag="1" \
```
