# POC guide

What a customer needs to have ready, who authenticates to whom, where every pod runs, and a POC plan with pass
criteria. Setup commands are in the [README](../README.md); identities, network rules and secrets in
[architecture.md](architecture.md).

## What the POC proves

| # | Capability | Pass when |
| --- | --- | --- |
| 1 | Internet clients reach a private Kafka only through the Gateway | `kafka.gateway.<PUBLIC_ZONE>:9092` works; broker metadata shows only Gateway names; `*.<PRIVATE_ZONE>` does not resolve publicly |
| 2 | mTLS at the edge | a trusted client certificate connects; none or an untrusted one fails in the TLS handshake |
| 3 | Authorization stays in the core | the brokers authorize Gateway traffic with RBAC; a client without role bindings (bob) is refused by the schema registry |
| 4 | Data contracts at the Gateway | invalid records (CEL rules) are rejected before they reach the brokers |
| 5 | Field encryption at the Gateway | brokers store ciphertext; consumers through the Gateway read plaintext; keys stay in AWS KMS |
| 6 | Topic fencing | produce to `demo-fenced` is refused at the Gateway only |
| 7 | Schema linking | `https://sr.<PUBLIC_ZONE>` serves the core's schemas with the same IDs, read-only, without DEKs |
| 8 | Operations | Gateway metrics in Grafana, Gateway and broker logs in Loki, cluster in Control Center |

`./check.sh` tests 1-7 automatically; [DEMO.md](../DEMO.md) shows each one by hand.

## What the customer provides

| Item | Needed for | Notes |
| --- | --- | --- |
| AWS account, one region, three AZs | everything | a sandbox account is simplest |
| An operator identity with admin rights in that account | `setup.sh` / `teardown.sh` | Terraform creates resources in VPC/EC2, EKS, IAM (roles, OIDC provider, pod identity), ELB, Route 53, ACM and KMS. In a restricted account, grant those services, including `iam:CreateRole` and `iam:PassRole` |
| A public Route 53 zone (`PARENT_ZONE`) in the same account | public names | Terraform creates `<PUBLIC_ZONE>` under it and writes the NS delegation. Without one, delegate `<PUBLIC_ZONE>` from your DNS by hand |
| Two non-overlapping VPC CIDRs | `CORE_VPC_CIDR`, `DMZ_VPC_CIDR` | must not overlap networks they will later peer with |
| Allowlisted client source IPs | `PUBLIC_ALLOWED_CIDRS` | only these reach the Gateway (9092) and the public schema registry (443) |
| Confluent license | Schema Registry rules and encryption (CSFLE add-on), Gateway | file at `CONFLUENT_LICENSE_FILE` |
| Image access | pulls from Docker Hub | `confluentinc/cp-server:8.4.1`, `cp-schema-registry:8.4.1`, `cpc-gateway:1.4.0`, `confluent-init-container:3.4.0`, `cp-enterprise-control-center-next-gen` / `-prometheus` / `-alertmanager:2.7.0`, `osixia/openldap:1.5.0`, `grafana/{grafana,loki,alloy}`, `prom/prometheus`. Mirror them if nodes can't reach Docker Hub |
| Workstation | running the scripts | `aws terraform kubectl helm jq envsubst openssl curl nc dig keytool java mvn` |

Optional, to use your own instead of the demo ones (see [Use your own pieces](../README.md#use-your-own-pieces)):

| Item | Replaces | Requirement |
| --- | --- | --- |
| Certificate authority | `wf-demo-ca` (self-signed) | any cert-manager issuer. Leaf CNs must stay the principal names below |
| Directory | OpenLDAP | an LDAP bind user and groups for MDS; users for the schema registry, Control Center and the Gateway |
| Client identities | alice, bob | one certificate per application, CN = the principal used in role bindings |

## Authentication per hop

| From → to | Transport | Client proves identity with | Server proves identity with | Authorization |
| --- | --- | --- | --- | --- |
| Client → Gateway | TLS on 9092 (public NLB) | client certificate from the trusted CA (`clientAuth: required`) | `cpcgw-dmz-server-tls` (`*.kafka.gateway.<PUBLIC_ZONE>`) | none at the Gateway; trust in the CA is the gate |
| Gateway → brokers | mTLS on 9092 (internal NLB) | `cpcgw-dmz-client-tls` (CN=cpcgw-dmz-client) | `tls-kafka` | Kafka RBAC for `User:cpcgw-dmz-client` (`cfk/dmz/01-gateway/core-rbac.yaml`) |
| Gateway → core SR | HTTPS on 443 (internal NLB) | LDAP basic auth `cpcgw-dmz-sr-client` | `tls-schemaregistry` | SR RBAC: read `demo-*` subjects and the payments KEK |
| Gateway → AWS KMS | HTTPS | IRSA role, then the KMS role in `aws-kms-role-params` | AWS | KMS key policy: `Encrypt`, `Decrypt`, `GenerateDataKey`, `DescribeKey` on the payments key |
| Serializer → public SR | HTTPS on 443 (public ALB, ACM certificate) | LDAP basic auth (e.g. alice), verified by MDS in the core | ACM certificate for `sr.<PUBLIC_ZONE>` | SR RBAC on the read-only cluster: read only |
| DMZ SR followers → brokers, MDS | mTLS on 9092 / 8090 | `tls-schemaregistry-dmz` (CN=sr-dmz) | `tls-kafka` | store topic and group of the read-only cluster, license topics |
| Core SR → read-only SR (schema link) | HTTPS, in-cluster | LDAP basic auth `sr-exporter` | `tls-schemaregistry-ro` | ResourceOwner on the read-only cluster's subjects |
| Core components ↔ each other | mTLS | `tls-*` per component (CN = principal) | same | RBAC via MDS; `kafka` and `kraftcontroller` are super users |

The brokers never see the client's certificate: every Gateway connection is `User:cpcgw-dmz-client`. Per-client
authorization at the brokers would need the Gateway's identity mode (principal mapping), which CFK 3.4.0 doesn't
render correctly (see [architecture.md](architecture.md#gateway-configuration-notes)).

## Certificates

All are cert-manager `Certificate` resources signed by `ClusterIssuer wf-demo-ca` in the core cluster. Each secret has
`tls.crt`, `tls.key` and `ca.crt`. The DMZ copies are made by `cfk/dmz/00-platform` and `cfk/dmz/02-schema-registry`.

| Secret | CN | Presented by | To | Defined in |
| --- | --- | --- | --- | --- |
| `cpcgw-dmz-server-tls` | `kafka.gateway.<PUBLIC_ZONE>` (+ wildcard) | Gateway (server) | external clients | `core/00-platform/certificates.yaml` |
| `cpcgw-dmz-client-tls` | `cpcgw-dmz-client` | Gateway (client) | brokers | same |
| `client-alice-tls`, `client-bob-tls` | `alice`, `bob` | external clients | Gateway | same; exported as JKS by `clients/export-client-config.sh` |
| `tls-kafka` | `kafka` | brokers | everyone (incl. the Gateway) | same |
| `tls-kraftcontroller`, `tls-schemaregistry` (`sr`), `tls-controlcenter` (`c3`), `ldap-sslcerts`, Prometheus and Alertmanager | per component | core components | each other | same |
| `tls-schemaregistry-ro` | `sr-ro` | read-only SR leader | brokers, exporter | `core/06-schema-linking/certificates.yaml` |
| `tls-schemaregistry-dmz` | `sr-dmz` | DMZ SR followers | brokers, MDS, the ALB | same |

The public schema registry name is served by an ACM certificate on the ALB (`terraform/dmz/sr-alb.tf`), so external
serializers need no private CA. Gateway clients do need the CA: it's in `.secrets/clients/truststore.jks`.

## Pod placement

Both clusters run one managed node group spread over three AZs (sizes in `terraform/*/variables.tf`). Storage is `gp3`
EBS, deleted with the volume claim.

**Core cluster `<CORE_CLUSTER>`**: 3 × `m6i.2xlarge` (autoscale 3-6), private subnets only.

| Namespace | Workload | Replicas | Placement | Storage |
| --- | --- | --- | --- | --- |
| `confluent` | KRaft controllers | 3 | one per node | 20 GiB each |
| `confluent` | Kafka brokers | 3 | one per node, rack = AZ (`rackAssignment`) | 100 GiB each |
| `confluent` | Schema Registry (writable) | 2 | spread over AZs | none |
| `confluent` | Schema Registry read-only leader | 1 | any | none |
| `confluent` | Control Center (+ Prometheus, Alertmanager) | 1 | any | 10 + 20 GiB |
| `confluent` | OpenLDAP, CFK operator | 1 each | any | 2 × 1 GiB (LDAP) |
| `logging` | Loki, Alloy | 1 each | any | 20 GiB (Loki) |
| `clients` | internal client pod | 1 | any | none |
| `kube-system`, `cert-manager` | Load Balancer Controller, ExternalDNS, cert-manager, EBS CSI | add-ons | any | none |

**DMZ cluster `<DMZ_CLUSTER>`**: 3 × `m6i.large` (autoscale 3-4), pods in private subnets; only the NLB and ALB sit
in public subnets.

| Namespace | Workload | Replicas | Placement | Storage |
| --- | --- | --- | --- | --- |
| `gateway` | CPC Gateway | 3 | one per AZ (`topologySpreadConstraints`) | none |
| `gateway` | Schema Registry followers (read-only) | 2 | spread over AZs | none |
| `gateway` | CFK operator | 1 | any | none |
| `monitoring` | Prometheus, Grafana | 1 each | any | none (demo) |
| `monitoring` | Alloy (ships Gateway logs to the core Loki) | 1 | any | none |
| `kube-system` | Load Balancer Controller, ExternalDNS | add-ons | any | none |

Nothing holding data or keys runs in the DMZ: no brokers, no CA key, no DEK registry, no MDS signing key.

## Network openings

| Path | Port | Opened by |
| --- | --- | --- |
| Allowlisted internet → Gateway NLB | 9092 | Terraform security group (CFK's 9180 and 9190 stay closed) |
| Allowlisted internet → public SR ALB | 443 | Terraform security group |
| DMZ private subnets → core | 9092 (Kafka), 443 (SR), 8090 (MDS), 3100 (Loki) | VPC peering, network ACL, core NLB source ranges |
| Core → DMZ | none | |
| Nodes → internet | 443 | NAT gateways (images, AWS APIs) |

In an existing network, request exactly these flows from the firewall team.

## POC runbook

| Step | Who | Action | Done when |
| --- | --- | --- | --- |
| 1. Prepare | customer | provide the items in [What the customer provides](#what-the-customer-provides); decide demo CA or own CA | `config.env` filled in, license in place, `aws sts get-caller-identity` shows the POC account |
| 2. Deploy | either | `./setup.sh -y` (60-75 min), or one step at a time (`./setup.sh list`) | exits 0 |
| 3. Verify | either | `./check.sh` | `All checks passed.` |
| 4. Demo | Confluent | walk through [DEMO.md](../DEMO.md) | capabilities 1-8 shown |
| 5. Customer data | customer | add their topics, role bindings and schemas (see [Use your own pieces](../README.md#use-your-own-pieces)); issue a certificate per application; run their client with a config like `.secrets/clients/alice-gateway.properties` | their app produces and consumes through the Gateway |
| 6. Review | both | go through [Before production](../README.md#before-production) | open items listed |
| 7. Tear down | either | `./teardown.sh -y` (about 40 min) | exits 0; only KMS keys remain, in their 7-day deletion window |
