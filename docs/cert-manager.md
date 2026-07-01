# cert-manager — DNS-01 with Cloudflare

ClusterIssuer `letsencrypt-prod` uses DNS-01 challenge with a Cloudflare API
token to support wildcard certificates (`*.k8s.junjie.pro`). The token lives
in a manually-created Secret:

```bash
kubectl create secret generic cloudflare-api-token \
    --from-literal=api-token=<token> -n cert-manager
```

The `infrastructure/cert-manager/install.sh` creates the ClusterIssuer
referencing this Secret. HTTP-01 challenges are insufficient for wildcard
certificates — DNS-01 is mandatory.
