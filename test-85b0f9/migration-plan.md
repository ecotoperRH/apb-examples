# MIGRATION FROM ANSIBLE PLAYBOOK BUNDLES (APB) TO MODERN ANSIBLE

## Executive Summary

This repository contains **7 Ansible Playbook Bundles (APBs)** plus a shared **apb-base** runtime image, all targeting **OpenShift Origin / OKD** via the now-deprecated **Ansible Service Broker (ASB)** framework. APBs are containerized Ansible playbooks that were executed by the OpenShift Service Catalog broker to provision, deprovision, bind, and test services. The entire APB ecosystem (ansible.kubernetes-modules, ansibleplaybookbundle.asb-modules, the `asb_encode_binding` action plugin, `openshift_v1_*` / `k8s_v1_*` modules) has been **deprecated and removed** from the Ansible ecosystem.

The migration target is **modern Ansible** using the `kubernetes.core` collection (formerly `community.kubernetes`) against a current Kubernetes or OpenShift cluster, replacing the APB dispatch model with standard Ansible playbooks, roles, and inventories. Each APB maps 1-to-1 to an Ansible role or collection of roles.

**Scope:** 7 application APBs + 1 base runtime  
**Complexity:** Medium — the Kubernetes resource logic is largely intact; the primary work is module replacement, credential handling, and lifecycle orchestration  
**Estimated Timeline:** 3–5 weeks for a single engineer; 2 weeks with two engineers working in parallel

---

## Module Migration Plan

This repository contains 7 APB modules (plus the shared base) that each require individual migration planning.

### MODULE INVENTORY

**apb-base**
- **Description:** Shared base runtime image and entrypoint framework for all APBs. Provides `entrypoint.sh` (action dispatcher for provision/deprovision/bind/test), `oc-login.sh` (OpenShift authentication via token or in-cluster service account), `bind-init` (keeps the APB pod alive while the broker collects bind credentials from `/var/tmp/bind-creds`), `broker-bind-creds` (reads and removes the bind-creds file for broker pickup), and `test-retrieval-init` (keeps pod alive while test results are collected). Also ships `ansible.cfg` setting dual roles paths (`/etc/ansible/roles:/opt/ansible/roles`).
- **Path:** `apb-base/`
- **Technology:** Ansible Playbook Bundle base image (Bash + Ansible)
- **Key Features:** Action-based dispatch (`$ACTION` env var), in-cluster Kubernetes service account auth, mounted secrets injection as `--extra-vars @/tmp/secrets`, bind credential lifecycle via filesystem polling, test result lifecycle management

---

**etherpad-apb**
- **Description:** Deploys Etherpad Lite (collaborative note-taking) backed by MariaDB on OpenShift. Provisions 2 PersistentVolumeClaims (mariadb-storage 1Gi RWO, mariadb-logs 1Gi RWO), 2 Services (mariadb:3306, etherpad:9001), 1 Route (etherpad, port-9001), and 2 DeploymentConfigs (mariadb using `docker.io/mariadb:latest`, etherpad using `docker.io/tvelocity/etherpad-lite:latest`). Marked `bindable: true` in apb.yml but the bind action playbook and `asb_encode_binding` call are entirely absent — bind is non-functional.
- **Path:** `etherpad-apb/`
- **Technology:** Ansible Playbook Bundle (APB)
- **Key Features:** MariaDB with dual PVC (data + logs), Etherpad env-var-driven DB connection, idempotent `state: "{{ state }}"` on most resources, missing deprovision playbook, broken bind contract

---

**hastebin-apb**
- **Description:** Deploys Hastebin (pastebin-style web app) with a Memcached sidecar on OpenShift. Provisions a ConfigMap (`haste-config`) via a raw `oc create configmap` shell command (non-idempotent), a multi-container DeploymentConfig (`docker.io/dymurray/hastebin:latest` port 7777 + `docker.io/modularitycontainers/memcached:latest` port 11211) with the ConfigMap mounted as `config.js`, 1 Service (port 80→7777), and 1 Route. The deprovision role exists but all tasks are commented out, making deprovision a no-op.
- **Path:** `hastebin-apb/`
- **Technology:** Ansible Playbook Bundle (APB)
- **Key Features:** Jinja2 `config.js.j2` template for Hastebin configuration (port, max_length, key_length, memcached storage backend), multi-container pod pattern, non-idempotent ConfigMap creation via shell, completely broken deprovision

---

**jenkins-apb**
- **Description:** Deploys Jenkins CI/CD server on OpenShift with optional persistence, OAuth integration, and optional Source-to-Image (S2I) custom build. Provisions 2 Services (jenkins:80→8080, jenkins-jnlp:50000), 1 Route (TLS edge termination with redirect), 1 ServiceAccount, 1 RoleBinding (`edit` role, created via `oc create -f` with `ignore_errors: True`), optional PVC (1Gi RWO when `persistent=true`), optional ImageStream + BuildConfig (when S2I git params are provided), and 1 DeploymentConfig (persistent uses PVC mount, ephemeral uses emptyDir; ImageStreamTag trigger from `openshift` namespace or project namespace for S2I). Deprovision is comprehensive, deleting all resources including PVC, ServiceAccount, RoleBinding, ImageStream, BuildConfig, and DC.
- **Path:** `jenkins-apb/`
- **Technology:** Ansible Playbook Bundle (APB)
- **Key Features:** Conditional persistence plan, TLS edge route, OAuth toggle via `OPENSHIFT_ENABLE_OAUTH` env var, S2I custom Jenkins image build, JNLP agent port exposure, `ignore_errors` masking real ServiceAccount failures, non-idempotent RoleBinding creation

---

**mediawiki123-apb**
- **Description:** Deploys MediaWiki 1.23 on OpenShift using a pre-built image. Provisions 1 Route (host injected back as `MEDIAWIKI_SITE_SERVER` env var into the DC), 1 PVC `mediawiki123-pvc` (1Gi RWO), 1 DeploymentConfig (`docker.io/dymurray/mediawiki123:latest`, port 8080, PVC mounted at `/persistent`), and 1 Service (port 8080). Includes a separate `deprovision.yml` playbook (scales DC to 0, deletes RC, DC, Service, Route, PVC) and a `test.yml` playbook with a `verify-mediawiki123-apb` role stub. All required parameters (db schema, site name, language, admin user/password) must be supplied at provision time.
- **Path:** `mediawiki123-apb/`
- **Technology:** Ansible Playbook Bundle (APB)
- **Key Features:** Route hostname feedback loop into DC env var, persistent wiki storage, separate test playbook with verify role, hardcoded `state: present` in provision tasks (not idempotent for deprovision reuse), deprovision uses hardcoded `namespace: mediawiki123-apb` instead of dynamic namespace variable

---

**nginx-oss-apb**
- **Description:** Deploys NGINX OSS as a reverse proxy or static web server on OpenShift, with optional load balancing configuration. Provisions a DeploymentConfig (`docker.io/alessfg/openshift-nginx`, port 8080) with a ConfigMap volume mount at `/etc/nginx/conf.d`, 1 Service (port 80→8080), and 1 Route. The NGINX `default.conf` is generated from a Jinja2 template supporting four load-balancing algorithms (round_robin, least_conn, ip_hash, hash) with dynamic upstream server list, then loaded into a ConfigMap via `oc create configmap` shell command (non-idempotent). Deprovision cleanly removes Route, Service, and DeploymentConfig but does NOT delete the ConfigMap.
- **Path:** `nginx-oss-apb/`
- **Technology:** Ansible Playbook Bundle (APB)
- **Key Features:** Jinja2 `default.conf.j2` with conditional upstream block and lb_method enum, four LB algorithm support, ConfigMap-as-config-file pattern, non-idempotent ConfigMap creation via shell, ConfigMap leak on deprovision

---

**pyzip-demo-apb**
- **Description:** Deploys the py-zip-demo Python web application on OpenShift. Provisions 1 Route, 1 Service (port 8080), and 1 DeploymentConfig (`docker.io/ansibleplaybookbundle/py-zip-demo:latest`, port 8080) with a ConfigChange trigger. No parameters are required. Uses `state: "{{ state }}"` for idempotent resource management. No deprovision playbook exists — the APB directory contains only `provision.yml`.
- **Path:** `pyzip-demo-apb/`
- **Technology:** Ansible Playbook Bundle (APB)
- **Key Features:** Zero-parameter deployment, ConfigChange trigger, idempotent state variable, missing deprovision playbook

---

**pyzip-demo-db-apb**
- **Description:** Deploys a PostGIS-enabled PostgreSQL database seeded with geospatial demo data (parks, airports, zip codes) for use with pyzip-demo-apb. Marked `bindable: true`. Provisions 1 PVC `demodb` (1Gi RWO), 1 Service (port 5432), 1 ImageStream (`docker.io/fabianvf/postgresql:postgis`), and 1 DeploymentConfig with Rolling strategy and ImageChange trigger. After deployment, waits for port 5432 to be reachable, then seeds the database by executing 5 SQL/DDL files via `psql` shell commands. Emits bind credentials (POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB) via `asb_encode_binding`. Deprovision playbook has a variable mismatch bug: uses `postgresql_service_name` and hardcoded name `postgresql` instead of the actual `demodb`/`dbservice_name` used at provision time.
- **Path:** `pyzip-demo-db-apb/`
- **Technology:** Ansible Playbook Bundle (APB)
- **Key Features:** PostGIS image, geospatial seed data (5 SQL files: parkcoord.sql, airports.ddl, airports.sql, zipcodes.ddl, zipcodes.sql), `asb_encode_binding` for service binding, `wait_for` readiness gate, ImageChange trigger, deprovision variable name mismatch bug

---

### Infrastructure Files

- `Makefile`: Defines `REGISTRY`, `ORG`, `TAG` variables and targets for `build` (docker build all APB images), `push` (docker push all images), `release` (build + push). Migration consideration: replace with a CI/CD pipeline (GitHub Actions, Tekton, etc.) or Ansible playbook for role/collection publishing.
- `README.md`: Top-level documentation listing all APBs and linking to the APB development guide. Migration consideration: update to document new Ansible collection/role structure and usage.
- `apb-base/files/etc/ansible/ansible.cfg`: Sets `roles_path = /etc/ansible/roles:/opt/ansible/roles`. Migration consideration: replace with a standard `ansible.cfg` in the project root or collection structure.
- `apb-base/files/etc/ansible/hosts`: Static inventory file for the APB runtime (localhost). Migration consideration: replace with a proper inventory file or dynamic inventory plugin.
- `apb-base/files/usr/bin/entrypoint.sh`: Core APB dispatch script. Migration consideration: entirely replaced by standard Ansible playbook invocation; no equivalent needed in modern Ansible.
- `apb-base/files/usr/bin/oc-login.sh`: OpenShift authentication helper. Migration consideration: replace with `kubernetes.core` collection auth via `kubeconfig`, `host`+`api_key`, or in-cluster service account via environment variables.
- `apb-base/files/usr/bin/bind-init`, `broker-bind-creds`, `test-retrieval-init`, `test-retrieval`: APB broker lifecycle scripts. Migration consideration: entirely replaced by Ansible Vault, external secrets management, and standard test frameworks (Molecule).
- `*/Dockerfile`: Each APB has a Dockerfile building from the APB base image. Migration consideration: no longer needed; roles/collections are distributed via Ansible Galaxy or a private Automation Hub.
- `*/apb.yml`: APB service catalog metadata (name, image, bindable, parameters, plans). Migration consideration: parameter definitions should be migrated to role `defaults/main.yml` and documented in role `README.md`; plan variants become separate variable files or tags.

---

### Target Details

- **Operating System:** Linux containers on OpenShift/Kubernetes. The APBs themselves run as containers; the workloads they deploy are also containerized. No host OS configuration is performed. Target cluster OS is not specified; OpenShift Origin (OKD) is implied by `openshift_v1_*` module usage. For the migrated Ansible roles, **Red Hat Enterprise Linux 9** is assumed for the control node.
- **Virtual Machine Technology:** Not specified. All workloads are container-based on Kubernetes/OpenShift. No VM-level provisioning is performed.
- **Cloud Platform:** Not specified. The repository targets a generic OpenShift cluster reachable via `OPENSHIFT_TARGET` URL. No cloud-provider-specific resources (AWS, Azure, GCP) are referenced.

---

## Migration Approach

### Key Dependencies to Address

- **ansible.kubernetes-modules (deprecated):** Used in every APB as `role: ansible.kubernetes-modules`. This role provided the `openshift_v1_*` and `k8s_v1_*` modules. Replace entirely with the **`kubernetes.core`** collection (`kubernetes.core.k8s`, `kubernetes.core.k8s_info`, `kubernetes.core.k8s_scale`). Install via `ansible-galaxy collection install kubernetes.core`.

- **ansibleplaybookbundle.asb-modules (deprecated):** Used in `pyzip-demo-db-apb` for the `asb_encode_binding` action plugin. This plugin wrote bind credentials to `/var/tmp/bind-creds` for broker pickup. Replace with **Ansible Vault** for secrets at rest, or emit credentials as Ansible facts/registered variables and store them in a secrets manager (HashiCorp Vault, AWS Secrets Manager, OpenShift Secrets). The `asb_encode_binding` call in `pyzip-demo-db-apb` must be replaced with a `kubernetes.core.k8s` task creating a Kubernetes Secret.

- **openshift_v1_deployment_config / openshift_v1_route / openshift_v1_image_stream / openshift_v1_project (deprecated):** OpenShift-specific resource types from the APB module set. Replace with:
  - `openshift_v1_deployment_config` → `kubernetes.core.k8s` with `kind: Deployment` (Kubernetes-native) or `kind: DeploymentConfig` if targeting OpenShift 4.x with the `redhat.openshift` collection.
  - `openshift_v1_route` → `kubernetes.core.k8s` with `kind: Route` (requires `redhat.openshift` collection) or Kubernetes `Ingress`.
  - `openshift_v1_image_stream` → `kubernetes.core.k8s` with `kind: ImageStream` (requires `redhat.openshift` collection) or remove in favor of direct image references.
  - `openshift_v1_project` → `kubernetes.core.k8s` with `kind: Namespace` or `kind: Project` via `redhat.openshift`.

- **k8s_v1_persistent_volume_claim / k8s_v1_service / k8s_v1_replication_controller (deprecated):** Replace with `kubernetes.core.k8s` using standard Kubernetes API versions (`v1` for PVC, Service; `apps/v1` for Deployment).

- **docker.io/mariadb:latest (floating tag):** Used by etherpad-apb. Pin to a specific version (e.g., `mariadb:10.11`) to ensure reproducible deployments.

- **docker.io/tvelocity/etherpad-lite:latest (unmaintained image):** Used by etherpad-apb. Evaluate replacing with the official `etherpad/etherpad` image from Docker Hub.

- **docker.io/fabianvf/postgresql:postgis (personal image):** Used by pyzip-demo-db-apb. Replace with an official PostGIS image such as `postgis/postgis:15-3.4`.

- **docker.io/dymurray/mediawiki123:latest and docker.io/dymurray/hastebin:latest (personal images):** Evaluate replacing with official or community-maintained images; pin versions.

- **psql CLI in pyzip-demo-db-apb:** The database seeding relies on `psql` being available inside the APB container and network-reachable to the DB service. In the migrated version, seeding should be performed via a Kubernetes Job or an init container, or via `community.postgresql` collection tasks run from the control node with port-forwarding.

- **oc CLI in hastebin-apb and nginx-oss-apb:** Both use `shell: oc create configmap ...` for non-idempotent ConfigMap creation. Replace with `kubernetes.core.k8s` tasks using `kind: ConfigMap` and `state: present` for full idempotency.

---

### Security Considerations

- **Hardcoded default credentials (HIGH RISK):** Every APB defaults sensitive credentials to trivial values:
  - `etherpad-apb`: `mariadb_password: admin`, `mariadb_root_password: admin`, `etherpad_admin_password: admin`
  - `pyzip-demo-db-apb`: `database_password: admin`, `database_user: admin`, `database_name: admin`
  - `mediawiki123-apb`: `mediawiki_admin_pass: admin` (in `test_defaults.yaml`)
  - `jenkins-apb`: No hardcoded password, but `enable_oauth: false` by default leaves Jenkins unauthenticated
  - Migration approach: All credentials must be sourced from **Ansible Vault** encrypted variables or an external secrets manager. Remove all plaintext defaults for passwords. Use `no_log: true` on tasks that handle credentials.

- **Credentials passed as plain-text environment variables (HIGH RISK):** All APBs inject database passwords, admin passwords, and connection strings directly as container environment variables (e.g., `MYSQL_ROOT_PASSWORD`, `POSTGRES_PASSWORD`, `ETHERPAD_ADMIN_PASSWORD`). Migration approach: Replace with Kubernetes Secrets referenced via `secretKeyRef` in the container env spec. Create Secrets using `kubernetes.core.k8s` with `no_log: true`.

- **TLS/SSL:** Only `jenkins-apb` configures TLS (edge termination on the Route). All other APBs expose services over plain HTTP. Migration approach: Enforce TLS on all Routes/Ingresses. Use cert-manager or OpenShift's built-in certificate management for automated certificate provisioning.

- **`oc login --insecure-skip-tls-verify=true` (HIGH RISK):** `oc-login.sh` uses `--insecure-skip-tls-verify=true` when an `OPENSHIFT_TOKEN` is provided, disabling TLS certificate validation. Migration approach: Remove this flag; configure proper CA certificate trust in the kubeconfig or via `validate_certs: true` in `kubernetes.core` tasks.

- **`ignore_errors: True` on ServiceAccount creation (jenkins-apb):** Masks real provisioning failures. Migration approach: Remove `ignore_errors`; use `kubernetes.core.k8s` with `state: present` which is idempotent and will not fail on re-provision.

- **Bind credential exposure (etherpad-apb):** `bindable: true` is declared but no bind playbook or `asb_encode_binding` call exists, meaning credentials are never securely transmitted to consuming services. Migration approach: Implement a proper Kubernetes Secret creation task and document the secret name/namespace for consuming applications.

- **`pyzip-demo-db-apb` bind credentials:** `asb_encode_binding` writes credentials to a file on the container filesystem for broker pickup — an insecure pattern. Migration approach: Create a Kubernetes Secret directly via `kubernetes.core.k8s` and output the secret name as an Ansible fact.

- **Floating image tags (`:latest`):** `mariadb:latest`, `etherpad-lite:latest`, `hastebin:latest`, `mediawiki123:latest`, `py-zip-demo:latest` all use `:latest`, making deployments non-reproducible and potentially pulling vulnerable images. Migration approach: Pin all image tags to specific digest-verified versions and integrate image scanning into the CI pipeline.

- **Credential count by module:**
  - `etherpad-apb`: 4 credentials (mariadb_root_password, mariadb_password, etherpad_admin_user, etherpad_admin_password)
  - `pyzip-demo-db-apb`: 3 credentials (database_name, database_user, database_password)
  - `mediawiki123-apb`: 2 credentials (mediawiki_admin_user, mediawiki_admin_pass)
  - `jenkins-apb`: 0 explicit credentials (relies on OpenShift OAuth or unauthenticated access)
  - `hastebin-apb`: 0 credentials
  - `nginx-oss-apb`: 0 credentials
  - `pyzip-demo-apb`: 0 credentials

---

### Technical Challenges

- **Deprecated module ecosystem:** The entire `ansible.kubernetes-modules` role and `ansibleplaybookbundle.asb-modules` collection are removed from Ansible Galaxy. They cannot be installed with current tooling. Every single task across all 7 APBs must be rewritten using `kubernetes.core.k8s`. This is the largest single body of work.

- **OpenShift DeploymentConfig vs. Kubernetes Deployment:** All APBs use `openshift_v1_deployment_config` (OpenShift-specific). Modern OpenShift 4.x supports standard Kubernetes `Deployment` objects. Migrating to `kind: Deployment` (apps/v1) is strongly recommended for portability, but requires adjusting trigger logic (ImageChange triggers become `image:` field updates or external CI triggers) and rolling update strategy parameters.

- **Non-idempotent shell-based ConfigMap creation:** `hastebin-apb` and `nginx-oss-apb` both use `shell: oc create configmap ...` which fails on re-run with "already exists". Migration approach: Replace with `kubernetes.core.k8s` tasks using `kind: ConfigMap` and `state: present`, embedding the template-rendered content directly in the task.

- **ConfigMap leak on nginx-oss-apb deprovision:** The `nginx-conf` ConfigMap is never deleted during deprovision. Migration approach: Add an explicit `kubernetes.core.k8s` delete task for the ConfigMap in the deprovision play.

- **Broken deprovision in hastebin-apb:** All deprovision tasks are commented out. Migration approach: Implement full deprovision using `kubernetes.core.k8s` with `state: absent` for all provisioned resources (Route, Service, DeploymentConfig/Deployment, ConfigMap).

- **Missing deprovision in etherpad-apb and pyzip-demo-apb:** Neither APB has a deprovision playbook. Migration approach: Create deprovision plays that delete all resources created during provision, in reverse dependency order (Route → Service → Deployment → PVC).

- **pyzip-demo-db-apb deprovision variable mismatch:** The deprovision playbook references `postgresql_service_name` and hardcoded resource name `postgresql`, but provision creates resources named `demodb` and uses `dbservice_name`. Migration approach: Align all resource names between provision and deprovision; use a shared `vars/main.yml` for resource name constants.

- **mediawiki123-apb deprovision namespace hardcoding:** `deprovision.yml` hardcodes `namespace: mediawiki123-apb` instead of using the dynamic `{{ namespace }}` variable. Migration approach: Remove the hardcoded `vars:` block and rely on the `namespace` variable passed at runtime.

- **Database seeding via shell psql (pyzip-demo-db-apb):** The `wait_for` + `shell: psql` pattern requires the `psql` binary and direct network access to the database service from the control node. In a modern Ansible execution environment, this may not be available. Migration approach: Use a Kubernetes Job with the PostGIS image to run the seed scripts, or use the `community.postgresql` collection with `kubernetes.core.k8s_exec` for port-forwarded execution.

- **`wait_for` on service hostname (pyzip-demo-db-apb):** `wait_for: host: "{{ dbservice_name }}"` relies on DNS resolution of the Kubernetes service name from within the APB pod. From an external control node, this will not resolve. Migration approach: Replace with `kubernetes.core.k8s_info` polling on the Deployment's `readyReplicas` field.

- **S2I BuildConfig in jenkins-apb:** The optional S2I build path creates an ImageStream and BuildConfig, which are OpenShift-specific. Migration approach: Replace with a standard Kubernetes Job or Tekton Pipeline for custom Jenkins image builds, or use a pre-built image pushed to a registry.

- **APB container dispatch model:** The entire `entrypoint.sh` / `bind-init` / `broker-bind-creds` lifecycle is specific to the Ansible Service Broker. Migration approach: Replace with standard `ansible-playbook` invocations from a CI/CD system, Ansible Automation Platform job templates, or Operator SDK.

- **Verify role stub (mediawiki123-apb):** The `verify-mediawiki123-apb` role is referenced in `test.yml` but its `tasks/main.yml` does not exist. Migration approach: Implement proper smoke tests using `kubernetes.core.k8s_info` to verify pod readiness and HTTP endpoint checks via `uri` module. Consider adopting **Molecule** for role testing.

---

### Migration Order

1. **pyzip-demo-apb** — Zero parameters, no credentials, no persistence, no deprovision needed. Simplest possible migration; ideal for establishing the `kubernetes.core.k8s` pattern and validating the new playbook structure.

2. **nginx-oss-apb** — No credentials, straightforward resource set (DC + Service + Route + ConfigMap). Primary work is replacing the `oc create configmap` shell with a `kubernetes.core.k8s` ConfigMap task and fixing the deprovision ConfigMap leak. Good second step for validating the template-to-ConfigMap pattern.

3. **hastebin-apb** — No credentials, multi-container pod pattern, Jinja2 config template. Primary work is fixing the non-idempotent ConfigMap creation and implementing the entirely missing deprovision logic.

4. **mediawiki123-apb** — Introduces credentials (admin user/pass), PVC, and a separate deprovision playbook. Primary work is fixing the hardcoded namespace in deprovision, moving credentials to Vault, and implementing the verify role. Good checkpoint for credential handling patterns.

5. **etherpad-apb** — Multiple credentials, dual PVC, two-tier deployment (MariaDB + Etherpad). Primary work is implementing the missing deprovision playbook, implementing the missing bind action (create a Kubernetes Secret with DB credentials), and securing all credentials via Vault.

6. **pyzip-demo-db-apb** — Most complex: PostGIS image, geospatial seed data, `asb_encode_binding` replacement, `wait_for` replacement, deprovision variable mismatch fix, and shell-based seeding replacement. Depends on patterns established in steps 4–5.

7. **jenkins-apb** — Most complex overall: conditional persistence, TLS route, OAuth, S2I optional path, ServiceAccount + RoleBinding RBAC, comprehensive deprovision. Migrate last after all patterns (credentials, RBAC, conditional resources) are established.

---

### Assumptions

1. **Target platform is OpenShift 4.x or vanilla Kubernetes 1.25+.** The migration plan recommends moving from `DeploymentConfig` to `Deployment` for portability, but if the target is strictly OpenShift 4.x, `redhat.openshift` collection resources can be used to retain `DeploymentConfig`, `Route`, `ImageStream`, and `BuildConfig`.

2. **The Ansible Service Broker (ASB) and Service Catalog are NOT present in the target environment.** The APB dispatch model (containerized playbooks invoked by the broker) is being replaced by direct `ansible-playbook` execution or Ansible Automation Platform job templates.

3. **A `kubernetes.core`-compatible kubeconfig or service account token will be available** to the Ansible control node at migration time. The `oc-login.sh` pattern is not being carried forward.

4. **Ansible Vault or an equivalent secrets manager** (HashiCorp Vault, AWS Secrets Manager, OpenShift Secrets) will be available for storing the credentials currently hardcoded as defaults. All plaintext password defaults (`admin`) are considered insecure and will not be preserved.

5. **The `pyzip-demo-apb` and `pyzip-demo-db-apb` are intended to be used together** (pyzip-demo-apb consumes the database provisioned by pyzip-demo-db-apb). The bind credential flow (currently via `asb_encode_binding`) needs to be replaced with a Kubernetes Secret that pyzip-demo-apb reads at deploy time. The exact Secret name and namespace convention must be agreed upon.

6. **The `etherpad-apb` bind action is considered unimplemented** and will be designed from scratch. The intent (sharing MariaDB credentials with a consuming service) is clear from the `bindable: true` flag and the credential set, but no existing bind playbook exists to migrate.

7. **The geospatial seed data files** (`parkcoord.sql`, `airports.ddl`, `airports.sql`, `zipcodes.ddl`, `zipcodes.sql`) in `pyzip-demo-db-apb/roles/provision-pyzip-demo-db-apb/files/` are static and will be carried forward as-is into the migrated role's `files/` directory.

8. **The `docker.io/dymurray/*` and `docker.io/fabianvf/*` personal images** may be unavailable or unmaintained. It is assumed that the migration team will evaluate and replace these with official or internally maintained images before production deployment.

9. **The `verify-mediawiki123-apb` role** is assumed to be intentionally empty/stubbed and will be implemented as part of the migration using Molecule and the `uri` module for HTTP smoke testing.

10. **The `jenkins-apb` `enable_oauth` parameter** assumes an OpenShift OAuth server is present. If migrating to vanilla Kubernetes, this parameter and the associated `OPENSHIFT_ENABLE_OAUTH` env var will need to be replaced with a Jenkins-native authentication configuration (e.g., Jenkins security realm configuration via JCasC).

11. **All APBs are assumed to target a single OpenShift namespace per deployment instance.** The `namespace` variable (sourced from the `NAMESPACE` environment variable) is the primary isolation boundary. This pattern is preserved in the migrated roles.

12. **The `Makefile` build/push targets** are assumed to be replaceable by a CI/CD pipeline. No equivalent `make` targets will be created in the migrated repository; instead, a `requirements.yml` for the `kubernetes.core` and optionally `redhat.openshift` collections will be provided.

13. **Resource naming conventions** (e.g., `nginx-oss-apb`, `pyzip-demo`, `demodb`, `mediawiki123`) are assumed to be preserved in the migrated roles to avoid breaking existing deployments that may reference these names.

14. **The `hastebin-apb` deprovision being entirely commented out** is treated as a bug, not intentional behavior. A full deprovision implementation will be created.

15. **The `mediawiki123-apb` hardcoded `namespace: mediawiki123-apb` in deprovision.yml** is treated as a bug. The migrated deprovision play will use the dynamic `{{ namespace }}` variable consistent with all other APBs.
