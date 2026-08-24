# MIGRATION FROM ANSIBLE PLAYBOOK BUNDLES (APB / OpenShift) TO ANSIBLE

## Executive Summary

This repository is the **`apb-examples`** collection from the `fusor` project — a set of seven Ansible Playbook Bundles (APBs) originally designed to run inside the **OpenShift Ansible Service Broker (ASB)**. APBs are containerised Ansible playbooks that provision applications onto OpenShift clusters using OpenShift-specific Kubernetes extensions: `DeploymentConfig`, `Route`, `ImageStream`, `BuildConfig`, and the `asb_encode_binding` module.

The migration goal is to convert these APBs into **standard Ansible roles and playbooks** that target plain Kubernetes (or OpenShift 4.x without the legacy ASB) using the `kubernetes.core` collection, replacing all OpenShift-specific resource types with their upstream Kubernetes equivalents and removing the APB runtime container dependency entirely.

**Jenkins is explicitly out of scope** per user requirements and will not be migrated.

### Scope
| APB | Complexity | Bindable | Deprovision | Status |
|---|---|---|---|---|
| etherpad-apb | Medium | Yes (broken) | Partial (no deprovision playbook) | Migrate |
| hastebin-apb | Medium | No | Broken (no-op) | Migrate |
| mediawiki123-apb | Low–Medium | No | Present | Migrate |
| nginx-oss-apb | Low–Medium | No | Present | Migrate |
| pyzip-demo-apb | Low | No | Absent | Migrate |
| pyzip-demo-db-apb | Medium | Yes (working) | Absent | Migrate |
| jenkins-apb | High | No | Present | **OUT OF SCOPE** |

### Timeline Estimate
- **Phase 1 – Foundation & simple APBs** (pyzip-demo, nginx-oss, mediawiki123): 1–2 weeks
- **Phase 2 – Stateful APBs** (hastebin, pyzip-demo-db): 1–2 weeks
- **Phase 3 – Complex multi-service APB** (etherpad): 1–2 weeks
- **Phase 4 – Integration testing & cleanup**: 1 week
- **Total estimated effort**: 4–7 weeks for a single engineer; 2–3 weeks with a two-person team.

---

## Module Migration Plan

This repository contains **six in-scope Ansible Playbook Bundles** that each need individual migration planning. All APBs share the same structural pattern: an `apb.yml` spec, a `playbooks/` directory with `provision.yml` (and sometimes `deprovision.yml`), and a `roles/` directory containing `provision-<name>` and optionally `deprovision-<name>` roles.

### MODULE INVENTORY

- **etherpad-apb**:
  - Description: Collaborative real-time note-taking application (Etherpad Lite) backed by MariaDB. Provisions two DeploymentConfigs (`mariadb` using `docker.io/mariadb:latest` and `etherpad` using `tvelocity/etherpad-lite:latest`), two Services, one Route, and two PVCs (`mariadb-storage` 1Gi and `mariadb-logs` 1Gi). Marked `bindable: True` in `apb.yml` but the provision role never calls `asb_encode_binding` — bind credentials are silently dropped (confirmed bug).
  - Path: `etherpad-apb/`
  - Technology: Ansible Playbook Bundle (APB) — OpenShift-targeted Ansible
  - Key Features: MariaDB with MYSQL_ROOT_PASSWORD/MYSQL_USER/MYSQL_PASSWORD/MYSQL_DATABASE env vars; Etherpad with ETHERPAD_DB_* env vars; persistent storage for both MariaDB data and logs; no deprovision playbook present; `ansible.kubernetes-modules` role dependency; four hardcoded credential parameters (mariadb_name, mariadb_user, mariadb_password, mariadb_root_password).

- **hastebin-apb**:
  - Description: Hastebin pastebin web application with Memcached storage backend. Provisions a single DeploymentConfig (`hastebin`) containing **two sidecar containers** — `dymurray/hastebin:latest` on port 7777 and `modularitycontainers/memcached:latest` on port 11211 — sharing a pod so Memcached is reachable at `0.0.0.0:11211` from within the pod. Generates a `config.js` via Jinja2 template and mounts it as a ConfigMap at `/usr/src/haste-server/config`. Service (port 80→7777) and Route are created. Deprovision playbook exists but all tasks are commented out — running deprovision is a complete no-op and leaves all resources in place.
  - Path: `hastebin-apb/`
  - Technology: Ansible Playbook Bundle (APB) — OpenShift-targeted Ansible
  - Key Features: Sidecar container architecture (hastebin + memcached in same pod); ConfigMap generated via `oc create configmap` shell command (requires `oc` CLI in APB container, not a k8s module); three user-configurable parameters (hastebin_port, max_length, key_length); `bindable: False`; broken deprovision role.

- **mediawiki123-apb**:
  - Description: MediaWiki 1.23 wiki application using the `dymurray/mediawiki123:latest` image. Provisions a Route **first** (before the DeploymentConfig) so that `route.route.spec.host` can be injected as the `MEDIAWIKI_SITE_SERVER` environment variable into the DeploymentConfig — an order-dependent provisioning pattern. Also provisions a PVC (`mediawiki123-pvc`, 1Gi RWO) mounted at `/persistent` and a Service on port 8080. Includes a `verify-mediawiki123-apb` role directory (tasks directory is empty).
  - Path: `mediawiki123-apb/`
  - Technology: Ansible Playbook Bundle (APB) — OpenShift-targeted Ansible
  - Key Features: Route-first provisioning order (hostname must be known before DC creation); five configurable parameters (mediawiki_db_schema, mediawiki_site_name, mediawiki_site_lang, mediawiki_admin_user, mediawiki_admin_pass); `mediawiki_admin_pass` is a credential requiring secret management; `bindable: False`; 1Gi persistent volume for wiki data.

- **nginx-oss-apb**:
  - Description: NGINX Open Source reverse proxy and load balancer. Generates an `nginx.conf`-style `default.conf` from a Jinja2 template supporting optional upstream load balancing (round_robin, least_conn, ip_hash, hash algorithms) with a CSV-parsed server list. The generated config is mounted as a ConfigMap at `/etc/nginx/conf.d` using `oc create configmap nginx-conf --from-file` (shell command, not a k8s module). Provisions a DeploymentConfig (`nginx-oss-apb`, image `alessfg/openshift-nginx`, port 8080), Service (port 80→8080), and Route. Full deprovision role present and functional.
  - Path: `nginx-oss-apb/`
  - Technology: Ansible Playbook Bundle (APB) — OpenShift-targeted Ansible
  - Key Features: Dynamic NGINX config generation via Jinja2 (`default.conf.j2`); optional upstream block toggled by `lb: true` boolean; CSV-to-upstream-entries parsing logic in template; `oc` CLI dependency for ConfigMap creation; three plan parameters (lb, server, lb_method); `bindable: false`; no persistent storage.

- **pyzip-demo-apb**:
  - Description: Minimal Python ZIP code lookup demo web application. The simplest APB in the repository — provisions only a DeploymentConfig (`pyzip-demo`, image `ansibleplaybookbundle/py-zip-demo:latest`, port 8080), a Service (port 8080), and a Route. No environment variables, no PVC, no bind credentials, no templates. No deprovision playbook.
  - Path: `pyzip-demo-apb/`
  - Technology: Ansible Playbook Bundle (APB) — OpenShift-targeted Ansible
  - Key Features: Stateless single-container deployment; zero configuration parameters; `bindable: False`; depends on `ansible.kubernetes-modules` role; ideal first migration candidate due to minimal complexity.

- **pyzip-demo-db-apb**:
  - Description: PostgreSQL database with PostGIS extension pre-seeded with geospatial data (airports, zipcodes, park coordinates) for use with the pyzip-demo application. Provisions a PVC (`demodb`, 1Gi RWO), a Service (`dbservice_name` variable, port 5432), an OpenShift ImageStream (`postgresql:postgis` from `docker.io/fabianvf/postgresql`), and a DeploymentConfig (`demodb`) with ImageStream trigger. After deployment, waits for port 5432 to be reachable then seeds the database by executing five SQL/DDL files via `psql` shell commands. Calls `asb_encode_binding` to expose `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` as bind credentials. `bindable: True` and binding is correctly implemented.
  - Path: `pyzip-demo-db-apb/`
  - Technology: Ansible Playbook Bundle (APB) — OpenShift-targeted Ansible
  - Key Features: PostGIS-enabled PostgreSQL (`fabianvf/postgresql:postgis`); five bundled SQL seed files (airports.ddl, airports.sql, zipcodes.ddl, zipcodes.sql, parkcoord.sql) in `roles/provision-pyzip-demo-db-apb/files/`; database seeding via `psql` shell with `wait_for` port check; working `asb_encode_binding` for service binding; three credential parameters (database_name, database_password, database_user); OpenShift ImageStream trigger for automatic redeployment on image update; no deprovision playbook.

---

### Infrastructure Files

- `Makefile`: Top-level build orchestration for Docker image builds. References `apb-base`, `hello-world-apb`, `jenkins-apb`, and `rhscl-mysql-apb` (the latter two not present in this repository snapshot). Supports `TARGET=rhel7` for RHEL-based Dockerfiles. Not needed post-migration but documents the original build pipeline.
- `README.md`: APB framework documentation covering directory structure, Dockerfile conventions, `apb prepare` tooling, image tagging strategy (canary/latest/nightly), and instructions for running APBs against an OpenShift cluster via `docker run`. Useful as historical reference during migration.
- `apb-base/files/usr/bin/entrypoint.sh`: The APB runtime entrypoint script. Handles `oc-login.sh` authentication, mounts secrets from `/etc/apb-secrets`, dispatches to `provision.yml`/`deprovision.yml` based on `$ACTION`, invokes `bind-init` if bind credentials file exists, and handles S2I build detection. This entire runtime mechanism is replaced by standard Ansible execution in the migrated form.
- `apb-base/files/etc/ansible/ansible.cfg`: Minimal Ansible configuration setting `roles_path = /etc/ansible/roles:/opt/ansible/roles`. The migrated project should define its own `ansible.cfg` with appropriate `collections_paths` and `roles_path`.
- `apb-base/files/usr/bin/oc-login.sh`: OpenShift cluster authentication script using `OPENSHIFT_TARGET` and `OPENSHIFT_TOKEN` environment variables. Replaced by `kubernetes.core` kubeconfig/token authentication in migrated playbooks.
- `apb-base/files/usr/bin/bind-init`, `broker-bind-creds`, `test-retrieval`, `test-retrieval-init`: APB broker lifecycle scripts for credential passing and test result retrieval. These are entirely ASB-specific and have no equivalent in the migrated Ansible roles — bind credentials should be written to Kubernetes Secrets instead.

---

### Target Details

- **Operating System**: The APBs target containerised workloads on OpenShift/Kubernetes — the host OS is not directly managed. Container images reference CentOS/RHEL-based images (`mariadb:latest`, `jenkins:latest` from OpenShift's `openshift` namespace). The APB runner container itself is based on `ansibleplaybookbundle/apb-base` (CentOS 7). For the migrated Ansible control node, **Red Hat Enterprise Linux 9** or equivalent is assumed.
- **Virtual Machine Technology**: Not specified. Workloads run as containers on OpenShift/Kubernetes. No VM-level provisioning is performed by any APB.
- **Cloud Platform**: Not specified explicitly. The APBs are designed for **OpenShift Origin / OKD** (on-premises or cloud-hosted). References to `https://172.17.0.1.nip.io:8443` in the README suggest local/on-premises OpenShift clusters (e.g., Minishift). The migrated playbooks should be cloud-agnostic but may need Ingress class configuration for specific cloud providers.

---

## Migration Approach

### Key Dependencies to Address

- **`ansible.kubernetes-modules` role (legacy)**: Used in every APB's provision playbook (`role: ansible.kubernetes-modules`). This is the pre-collection-era role that provided `k8s_v1_*` and `openshift_v1_*` modules. Replace entirely with the **`kubernetes.core` Ansible collection** (`kubernetes.core.k8s` module). All `k8s_v1_service`, `k8s_v1_persistent_volume_claim`, `openshift_v1_deployment_config`, `openshift_v1_route`, `openshift_v1_image_stream` module calls must be rewritten as `kubernetes.core.k8s` tasks with inline resource manifests.

- **`ansibleplaybookbundle.asb-modules` role (legacy)**: Used in `pyzip-demo-db-apb` and `hastebin-apb` provision playbooks. Provides the `asb_encode_binding` action plugin. Replace with a `kubernetes.core.k8s` task that creates a Kubernetes **Secret** in the target namespace containing the bind credential key-value pairs. The secret name should follow a predictable convention (e.g., `<release-name>-bind-credentials`).

- **`openshift_v1_deployment_config` → `kubernetes.core.k8s` Deployment**: All six APBs use OpenShift `DeploymentConfig` objects. These must be replaced with standard Kubernetes `Deployment` resources (API version `apps/v1`). Key differences: ImageStream triggers become `imagePullPolicy: Always` or external CI; rolling update strategy parameters map to `spec.strategy.rollingUpdate`; `spec_template_metadata_labels` maps to `spec.template.metadata.labels`.

- **`openshift_v1_route` → Kubernetes Ingress**: All APBs expose services via OpenShift `Route` objects. Replace with `networking.k8s.io/v1 Ingress` resources. TLS edge termination (jenkins-apb, out of scope) maps to Ingress TLS with cert-manager. The `mediawiki123-apb` route-first pattern (registering hostname before DC creation) must be re-implemented using a Kubernetes Ingress with a known hostname (passed as a variable) rather than dynamically discovered from the Route object.

- **`openshift_v1_image_stream` → direct image references**: `pyzip-demo-db-apb` creates an ImageStream for `fabianvf/postgresql:postgis` with an ImageChange trigger on the DeploymentConfig. Replace with a direct `image: docker.io/fabianvf/postgresql:postgis` reference in the Deployment spec and remove the ImageStream entirely. If automatic redeployment on image update is required, use a Kubernetes `CronJob` or external CI pipeline.

- **`oc create configmap` shell tasks → `kubernetes.core.k8s`**: Both `nginx-oss-apb` and `hastebin-apb` create ConfigMaps by shelling out to `oc create configmap --from-file`. This requires the `oc` CLI binary inside the APB container. Replace with `kubernetes.core.k8s` tasks using the `data` field populated by Jinja2 template rendering via `lookup('template', ...)`.

- **`wait_for` port check in `pyzip-demo-db-apb`**: The `wait_for: port: 5432 host: "{{ dbservice_name }}"` task works inside the APB container because it runs in the same network namespace as the cluster. In a standard Ansible playbook running on a control node outside the cluster, this must be replaced with `kubernetes.core.k8s_info` polling on the Deployment's `readyReplicas` field, or a `uri` module health check through an exposed endpoint.

- **`psql` shell seeding in `pyzip-demo-db-apb`**: Database seeding via `shell: "PGPASSWORD=... psql -U ... -f {{ role_path }}/files/{{ item }}"` requires `psql` on the control node and direct network access to the database Service. Replace with a Kubernetes `Job` resource that runs a seeding container (e.g., `postgres:alpine`) with the SQL files mounted from a ConfigMap, or use `community.postgresql` collection tasks if the database is accessible from the control node.

- **`dymurray/mediawiki123:latest` image**: Community-maintained image with no official support. Verify image availability and consider mirroring to an internal registry. The image exposes port 8080 (non-standard for MediaWiki) — document this assumption.

- **`tvelocity/etherpad-lite:latest` image**: Unofficial Etherpad image. Consider replacing with the official `etherpad/etherpad` image and verifying environment variable compatibility (`ETHERPAD_DB_*` vs `DB_*`).

---

### Security Considerations

- **Hardcoded default credentials across all APBs**: Every APB with credentials uses `default: admin` for passwords in `apb.yml` plan parameters and role defaults. These defaults propagate directly into running containers as environment variables. In the migrated Ansible roles, all credential parameters must be declared without defaults and sourced from **Ansible Vault** or an external secrets manager (HashiCorp Vault, AWS Secrets Manager). Affected APBs and credential counts:
  - `etherpad-apb`: 4 credentials (mariadb_name, mariadb_user, mariadb_password, mariadb_root_password) — passed as plaintext env vars to MariaDB and Etherpad containers.
  - `mediawiki123-apb`: 1 credential (mediawiki_admin_pass) — passed as env var to MediaWiki container.
  - `pyzip-demo-db-apb`: 3 credentials (database_name, database_password, database_user) — passed as env vars to PostgreSQL container and exposed via `asb_encode_binding`.
  - `hastebin-apb`: 0 credentials (no authentication configured).
  - `nginx-oss-apb`: 0 credentials.
  - `pyzip-demo-apb`: 0 credentials.

- **`asb_encode_binding` credential exposure**: In `pyzip-demo-db-apb`, bind credentials (including `POSTGRES_PASSWORD`) are written to `/var/tmp/bind-creds` inside the APB container and retrieved by the broker via `exec`. In the migrated form, these must be written to a Kubernetes **Secret** (not a ConfigMap) with `type: Opaque`. Ensure the Secret is created in the correct namespace and RBAC prevents unauthorized reads.

- **`etherpad-apb` bindable gap**: `apb.yml` declares `bindable: True` but the provision role never calls `asb_encode_binding`. This means any application attempting to bind to etherpad receives no credentials — a silent failure. During migration, add a `kubernetes.core.k8s` task to create a Secret containing `MARIADB_HOST`, `MARIADB_PORT`, `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_DATABASE` after the MariaDB DeploymentConfig is ready.

- **`hastebin-apb` deprovision no-op**: All deprovision tasks are commented out. Running the deprovision playbook leaves the Deployment, Service, Route, and ConfigMap in place. This is a data-loss/resource-leak risk. The migrated deprovision playbook must explicitly delete all created resources using `kubernetes.core.k8s` with `state: absent`.

- **`OPENSHIFT_TOKEN` in environment**: The APB runtime authenticates to OpenShift using a bearer token passed as `OPENSHIFT_TOKEN` environment variable (see `oc-login.sh`). In the migrated Ansible playbooks, cluster authentication must use a kubeconfig file or `K8S_AUTH_*` environment variables, and tokens must never be stored in playbook variables or version control. Use Ansible Vault for `k8s_auth_api_key` if token-based auth is required.

- **`mediawiki_admin_pass` in env var**: MediaWiki admin password is passed as a container environment variable (`MEDIAWIKI_ADMIN_PASS`). Environment variables in Kubernetes are visible via `kubectl describe pod`. Migrate to a Kubernetes Secret with `valueFrom.secretKeyRef` in the container spec.

- **`PGPASSWORD` in shell command**: `pyzip-demo-db-apb` seeds the database with `PGPASSWORD={{ database_password }} psql ...`. This exposes the password in the process list and shell history. Replace with a `.pgpass` file or a Kubernetes Job that reads the password from a Secret.

- **Image provenance**: Several images are from unofficial/community sources (`dymurray/mediawiki123`, `tvelocity/etherpad-lite`, `fabianvf/postgresql`, `alessfg/openshift-nginx`, `modularitycontainers/memcached`). Audit each image for vulnerabilities, establish a mirroring policy to an internal registry, and pin image tags to specific SHA digests rather than `latest`.

- **Vault/Secrets management recommendation**: Introduce **Ansible Vault** for all credential variables. Create a `group_vars/all/vault.yml` file (encrypted) containing all passwords and database credentials. Reference vault variables in role defaults. For production, integrate with an external secrets manager and use the `community.hashi_vault` collection.

---

### Technical Challenges

- **Route-first hostname injection in `mediawiki123-apb`**: The provision role creates the OpenShift Route before the DeploymentConfig specifically to capture `route.route.spec.host` and inject it as `MEDIAWIKI_SITE_SERVER`. In standard Kubernetes, an Ingress hostname is defined by the user (not auto-generated by the cluster), so this pattern must be inverted: the operator provides the hostname as a required variable (`mediawiki_site_server`), which is used in both the Ingress and the Deployment env var. Document this as a breaking change from the APB behaviour.

- **Sidecar container architecture in `hastebin-apb`**: Memcached runs as a sidecar in the same pod as Hastebin, reachable at `0.0.0.0:11211` (localhost). This is an intentional architectural choice reflected in `config.js.j2`. The migrated Kubernetes Deployment must preserve this two-container pod spec. Do not split Memcached into a separate Deployment/Service, as that would require changing the Hastebin config to use a service hostname and port.

- **Database seeding requires cluster network access**: `pyzip-demo-db-apb` seeds PostgreSQL by running `psql` from within the APB container, which has direct access to the cluster network. A standard Ansible control node outside the cluster cannot reach `{{ dbservice_name }}:5432` directly. Mitigation options: (a) use `kubernetes.core.k8s_exec` to exec into the running pod and run `psql` there; (b) create a Kubernetes `Job` with the SQL files in a ConfigMap; (c) use port-forwarding via `kubernetes.core.k8s_portforward` (if available). Option (b) is recommended for idempotency.

- **SQL seed files are large static assets**: Five SQL/DDL files (airports, zipcodes, park coordinates) are bundled in `roles/provision-pyzip-demo-db-apb/files/`. If converted to a Kubernetes ConfigMap, the 1MB ConfigMap size limit may be exceeded. Use a Kubernetes `Job` with an init container that downloads the files from a known URL, or embed them in a custom seeding container image.

- **`oc` CLI dependency in nginx-oss and hastebin**: Both APBs use `shell: oc create configmap ...` instead of the `k8s_v1_config_map` module. This is a technical debt item in the original APBs. The migration eliminates this dependency by using `kubernetes.core.k8s` with `lookup('template', ...)` to render and apply ConfigMaps declaratively.

- **`openshift_v1_deployment_config` ImageChange triggers**: `pyzip-demo-db-apb` uses an ImageStream + ImageChange trigger to automatically redeploy when the `postgresql:postgis` image is updated. Standard Kubernetes Deployments have no equivalent native mechanism. If automatic redeployment on image update is required, implement a separate pipeline (e.g., Tekton, GitHub Actions, or a Kubernetes `CronJob` that checks image digests).

- **`ansible.kubernetes-modules` role is unmaintained**: This role was the pre-collection mechanism for Kubernetes modules and is no longer maintained. The `kubernetes.core` collection (formerly `community.kubernetes`) is the supported replacement. All module names change: `k8s_v1_service` → `kubernetes.core.k8s` with `kind: Service`; `openshift_v1_route` → `kubernetes.core.k8s` with `kind: Route` (on OpenShift) or `kind: Ingress` (on plain Kubernetes).

- **Namespace injection via environment variable**: All APBs read `namespace` from `lookup('env', 'NAMESPACE')`. In the migrated roles, namespace should be an explicit Ansible variable with a documented default, passed via inventory or `--extra-vars`, not read from the process environment.

- **Missing deprovision playbooks**: `etherpad-apb`, `pyzip-demo-apb`, and `pyzip-demo-db-apb` have no deprovision playbook. The migrated roles should implement idempotent teardown using `kubernetes.core.k8s` with `state: absent` for all resources created during provisioning.

---

### Migration Order

1. **`pyzip-demo-apb`** — Lowest complexity: single stateless container, no credentials, no PVC, no templates, no bind credentials. Ideal first migration to establish the `kubernetes.core.k8s` pattern, Ingress template, and role structure that all subsequent migrations will follow.

2. **`nginx-oss-apb`** — Low complexity with one added challenge: replace `oc create configmap` shell task with `kubernetes.core.k8s` + `lookup('template', ...)`. Establishes the pattern for ConfigMap-from-template that `hastebin-apb` also needs. Full deprovision role already present.

3. **`mediawiki123-apb`** — Low–medium complexity. Introduces the hostname-as-variable pattern to replace route-first provisioning. One credential (admin password) to move to Ansible Vault. PVC migration is straightforward.

4. **`pyzip-demo-db-apb`** — Medium complexity. Introduces the bind-credentials-as-Secret pattern to replace `asb_encode_binding`. Requires solving the database seeding challenge (recommend Kubernetes Job approach). Establishes the PostgreSQL provisioning pattern reusable for etherpad.

5. **`hastebin-apb`** — Medium complexity. Requires preserving the sidecar container architecture, replacing `oc create configmap` shell task (pattern already established from nginx-oss), and implementing a functional deprovision role to replace the broken no-op.

6. **`etherpad-apb`** — Highest in-scope complexity. Two-service architecture (MariaDB + Etherpad), two PVCs, fix the `bindable: True` / missing `asb_encode_binding` bug by adding a bind-credentials Secret, implement missing deprovision playbook. Depends on PostgreSQL/database patterns established in step 4.

---

### Assumptions

1. **Target platform is plain Kubernetes (not OpenShift)**. The migration replaces all OpenShift-specific resources (`DeploymentConfig`, `Route`, `ImageStream`, `BuildConfig`) with upstream Kubernetes equivalents (`Deployment`, `Ingress`, direct image references). If the target remains OpenShift 4.x, `Route` objects can be retained and `DeploymentConfig` can optionally be kept, but the `ansible.kubernetes-modules` role must still be replaced with `kubernetes.core`.

2. **Jenkins is excluded from migration** per explicit user requirement. The `jenkins-apb/` directory and all its roles, templates, and playbooks are not analysed for migration tasks.

3. **The `ansible-service-broker` (ASB) will not be present** in the target environment. The entire APB lifecycle (broker registration, `asb_encode_binding`, `bind-init`, `entrypoint.sh` dispatch) is being replaced by direct Ansible playbook execution.

4. **`apb-base` is a runtime container, not an application**. It is not migrated as an application module — its `entrypoint.sh`, `oc-login.sh`, and broker scripts are replaced by standard Ansible execution patterns.

5. **The `hello-world-apb` and `rhscl-mysql-apb` referenced in the `Makefile` are not present** in this repository snapshot and are assumed to be out of scope.

6. **Image availability is assumed** for all referenced container images (`dymurray/mediawiki123:latest`, `tvelocity/etherpad-lite:latest`, `fabianvf/postgresql:postgis`, `alessfg/openshift-nginx`, `dymurray/hastebin:latest`, `modularitycontainers/memcached:latest`, `ansibleplaybookbundle/py-zip-demo:latest`). Image availability and security scanning must be verified before migration. All `latest` tags should be pinned to specific digests.

7. **An Ingress controller is available** in the target Kubernetes cluster (e.g., nginx-ingress, Traefik). The migrated playbooks will create `networking.k8s.io/v1 Ingress` resources and assume a default IngressClass is configured. If no Ingress controller is present, Services of type `LoadBalancer` or `NodePort` may be used as an alternative.

8. **The `mediawiki123-apb` hostname must be provided as an input variable** in the migrated role. The original APB auto-discovered the hostname from the OpenShift Route object. This is a user-facing breaking change — operators must supply `mediawiki_site_server` explicitly.

9. **Direct cluster network access for database seeding is not assumed**. The `pyzip-demo-db-apb` seeding approach (running `psql` from the control node against `{{ dbservice_name }}:5432`) will not work from an external Ansible control node. A Kubernetes Job-based seeding approach is assumed for the migration.

10. **`kubernetes.core` collection version ≥ 2.3** is assumed to be available on the Ansible control node, providing `kubernetes.core.k8s`, `kubernetes.core.k8s_info`, and `kubernetes.core.k8s_exec` modules.

11. **The `etherpad-apb` bindable gap is treated as a bug to be fixed**, not a feature to be preserved. The migrated role will create a bind-credentials Secret for etherpad.

12. **The `hastebin-apb` broken deprovision is treated as a bug to be fixed**. The migrated deprovision role will delete all resources created during provisioning.

13. **Namespace is treated as a required variable** in all migrated roles, not read from the `NAMESPACE` environment variable. Callers must pass `namespace` explicitly via inventory, `group_vars`, or `--extra-vars`.

14. **No multi-tenancy or RBAC migration is in scope** beyond what is strictly necessary to run the applications. The `jenkins-apb` ServiceAccount and RoleBinding patterns are out of scope with Jenkins itself.

15. **The `pyzip-demo-apb` and `pyzip-demo-db-apb` are intended to be used together** (pyzip-demo-db provides the database that pyzip-demo queries). The migrated roles should document this dependency and optionally provide a combined playbook that provisions both in the correct order.
