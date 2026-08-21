# MIGRATION FROM ANSIBLE PLAYBOOK BUNDLES (APB) TO ANSIBLE

## Executive Summary

This repository is a collection of **Ansible Playbook Bundles (APBs)** — a now-deprecated Red Hat/OpenShift technology that packaged Ansible playbooks as Docker container images to be brokered by the OpenShift Ansible Service Broker (ASB). Each APB is a self-contained Docker image that runs Ansible playbooks to provision, deprovision, and bind application workloads on OpenShift/Kubernetes clusters.

The migration target is **modern Ansible** (Ansible Core 2.12+) using the `kubernetes.core` collection (formerly `community.kubernetes`) to replace the deprecated `ansible.kubernetes-modules` role and the obsolete `openshift_v1_*` / `k8s_v1_*` task modules. The APB container-execution model is replaced by standard Ansible playbooks and roles that can be run from a control node, CI/CD pipeline, or Ansible Automation Platform (AAP).

**Repository contains 7 APBs** across the following application domains:
- Collaborative tools: Etherpad (note-taking), Hastebin (paste service)
- CMS/Wiki: MediaWiki 1.23
- CI/CD: Jenkins
- Web serving / load balancing: NGINX OSS
- Demo applications: PyZip Demo (web app + database tier)

**Migration complexity**: Medium — the Ansible logic itself is straightforward, but the migration requires replacing every deprecated OpenShift/Kubernetes module call with `kubernetes.core.k8s`, eliminating `oc` CLI shell workarounds, modernising credential handling (no more `asb_encode_binding`), and re-architecting the container-based execution model into standard playbook invocation.

**Estimated timeline**: 3–5 weeks for a single engineer; 2 weeks with two engineers working in parallel.

---

## Module Migration Plan

This repository contains 7 Ansible Playbook Bundle (APB) applications that each require individual migration planning.

### MODULE INVENTORY

- **etherpad-apb**:
    - Description: Deploys Etherpad Lite collaborative note-taking application backed by MariaDB on OpenShift. Provisions two DeploymentConfigs (MariaDB + Etherpad), two PersistentVolumeClaims (1 Gi each for MariaDB data and logs), two Services, and one Route. The APB is marked `bindable: True`, exposing database credentials to other services via the ASB binding mechanism.
    - Path: `etherpad-apb`
    - Technology: Ansible Playbook Bundle (APB)
    - Key Features: MariaDB 1 Gi data PVC + 1 Gi logs PVC, Etherpad Lite on port 9001, OpenShift Route for external access, credential binding via environment variables (`MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `ETHERPAD_ADMIN_PASSWORD`), `state` variable drives idempotent create/delete, no deprovision playbook present (only provision)

- **hastebin-apb**:
    - Description: Deploys Hastebin paste-sharing service as a two-container pod (Hastebin app + Memcached sidecar) on OpenShift. Uses a ConfigMap generated from a Jinja2 template to inject Hastebin configuration. No persistent storage. Deprovision playbook exists but all tasks are commented out (effectively a no-op).
    - Path: `hastebin-apb`
    - Technology: Ansible Playbook Bundle (APB)
    - Key Features: Two-container DeploymentConfig (Hastebin port 7777 + Memcached port 11211), ConfigMap created via `oc create configmap --from-file` shell command (not via Ansible module), `config.js.j2` template with `hastebin_port`/`key_length`/`max_length` parameters, Service mapping port 80→7777, OpenShift Route, broken deprovision (all tasks commented out)

- **jenkins-apb**:
    - Description: Deploys Jenkins CI/CD server on OpenShift with optional persistence, OpenShift OAuth integration, optional S2I (Source-to-Image) customisation via a BuildConfig, and full RBAC setup. The most complex APB in the repository. Supports both ephemeral and persistent (PVC-backed) deployment modes. Deprovision fully implemented.
    - Path: `jenkins-apb`
    - Technology: Ansible Playbook Bundle (APB)
    - Key Features: Persistent/ephemeral toggle via `persistent` parameter, OpenShift OAuth integration (`enable_oauth` parameter, `OAuthRedirectReference` annotation), Jenkins ServiceAccount + `edit` RoleBinding, JNLP agent service (port 50000), TLS edge-terminated Route, optional PVC (1 Gi default), optional S2I BuildConfig from git source using `jenkins:2` base image, ImageStream sourced from `openshift` namespace, `oc create -f` / `oc delete` shell commands used as workarounds for broken Ansible module behaviour, `ignore_errors: True` used throughout deprovision

- **mediawiki123-apb**:
    - Description: Deploys MediaWiki 1.23 wiki application on OpenShift with a persistent volume for wiki data. Implements an order-dependent provisioning sequence where the Route is created first so its hostname can be injected as the `MEDIAWIKI_SITE_SERVER` environment variable into the DeploymentConfig. Includes a test playbook with a verify role stub (directory exists but contains no tasks).
    - Path: `mediawiki123-apb`
    - Technology: Ansible Playbook Bundle (APB)
    - Key Features: Route-first provisioning order (hostname captured for `MEDIAWIKI_SITE_SERVER` env var), 1 Gi RWO PVC mounted at `/persistent`, DeploymentConfig using `docker.io/dymurray/mediawiki123:latest` (differs from `jmontleon` image listed in `apb.yml` metadata — image reference inconsistency), parameters for DB schema, site name, language, admin user/password, test playbook with `demo-app` namespace, empty verify role

- **nginx-oss-apb**:
    - Description: Deploys NGINX Open Source as a reverse proxy or static web server on OpenShift. Supports optional upstream load balancing with configurable method (round-robin, least_conn, ip_hash, hash). NGINX configuration is generated from a Jinja2 template and injected via a ConfigMap mounted at `/etc/nginx/conf.d`. Deprovision fully implemented.
    - Path: `nginx-oss-apb`
    - Technology: Ansible Playbook Bundle (APB)
    - Key Features: `default.conf.j2` template with conditional `upstream` block driven by `lb` boolean and `lb_method` enum (round_robin/least_conn/ip_hash/hash), comma-separated `server` list parsed with Jinja2 `split`, ConfigMap created via `oc create configmap nginx-conf --from-file` shell command, DeploymentConfig using `docker.io/alessfg/openshift-nginx` port 8080, Service port 80→8080, OpenShift Route, full deprovision (Route + Service + DeploymentConfig deleted)

- **pyzip-demo-apb**:
    - Description: Deploys the PyZip Python web application demo on OpenShift. Minimal APB with no parameters and no deprovision playbook. Creates a single DeploymentConfig, Service, and Route. Intended as a companion to `pyzip-demo-db-apb`.
    - Path: `pyzip-demo-apb`
    - Technology: Ansible Playbook Bundle (APB)
    - Key Features: Single-container DeploymentConfig (`docker.io/ansibleplaybookbundle/py-zip-demo:latest` port 8080), Service port 8080, OpenShift Route, no parameters, no deprovision playbook, `state` variable for idempotency, namespace sourced from `NAMESPACE` environment variable

- **pyzip-demo-db-apb**:
    - Description: Deploys a PostGIS-enabled PostgreSQL database seeded with geospatial demo data (parks, airports, zip codes) for use with `pyzip-demo-apb`. The only APB in the repository that uses the `asb_encode_binding` module to expose credentials to the Service Broker. Includes five SQL/DDL seed files. Deprovision fully implemented.
    - Path: `pyzip-demo-db-apb`
    - Technology: Ansible Playbook Bundle (APB)
    - Key Features: PostGIS PostgreSQL (`docker.io/fabianvf/postgresql:postgis`), 1 Gi RWO PVC at `/var/lib/pgsql/data`, ImageStream from `docker.io/fabianvf/postgresql` with `postgis` tag, Rolling deployment strategy, `wait_for` task polling port 5432 before seeding, five SQL seed files (`parkcoord.sql`, `airports.ddl`, `airports.sql`, `zipcodes.ddl`, `zipcodes.sql`) executed via `psql` shell command, `asb_encode_binding` for credential export (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`), `bindable: True`, deprovision removes PVC + DeploymentConfig + Service + ImageStream

---

### Infrastructure Files

- `apb-base/files/usr/bin/entrypoint.sh`: APB container entrypoint — handles `oc login`, mounts secrets from `/etc/apb-secrets`, dispatches to `provision.yml`/`deprovision.yml`/`bind.yml` playbooks, manages bind-credential lifecycle, and handles S2I build compatibility. **Migration consideration**: This entire execution model is replaced by direct `ansible-playbook` invocation from a control node or CI/CD pipeline. The secrets-mounting logic must be replaced with Ansible Vault or AAP credential injection.
- `apb-base/files/usr/bin/oc-login.sh`: Authenticates to OpenShift using either `OPENSHIFT_TOKEN` environment variable (dev/test) or in-cluster ServiceAccount token (production). **Migration consideration**: Replace with `kubernetes.core` collection kubeconfig/token authentication; use `k8s_auth` module or kubeconfig file management.
- `apb-base/files/usr/bin/bind-init`: Keeps the APB container alive while the ASB broker collects bind credentials via `exec`. **Migration consideration**: Entire bind-credential lifecycle is eliminated; credentials are managed via Ansible Vault, AAP credentials, or Kubernetes Secrets directly.
- `apb-base/files/usr/bin/broker-bind-creds`: Reads and outputs bind credentials from `/var/tmp/bind-creds` for the ASB broker to collect. **Migration consideration**: Replaced by direct Kubernetes Secret creation using `kubernetes.core.k8s`.
- `apb-base/files/usr/bin/test-retrieval` / `test-retrieval-init`: APB test result retrieval scripts for the ASB test framework. **Migration consideration**: Replace with standard Ansible test frameworks (Molecule) or CI/CD pipeline test stages.
- `apb-base/files/etc/ansible/ansible.cfg`: Sets `roles_path` to `/etc/ansible/roles:/opt/ansible/roles`. **Migration consideration**: Update to standard project-level `ansible.cfg` with appropriate `roles_path` and `collections_path`.
- `apb-base/files/etc/ansible/hosts`: Static inventory with `localhost ansible_connection=local`. **Migration consideration**: Replace with a proper inventory file or dynamic inventory plugin targeting the OpenShift/Kubernetes cluster.
- `Makefile`: Builds Docker images for `apb-base`, `hello-world-apb`, `jenkins-apb`, `rhscl-mysql-apb` with CentOS 7 / RHEL 7 target support. **Migration consideration**: The Docker build pipeline is eliminated. Replace with standard Ansible project structure; CI/CD pipeline (GitHub Actions, GitLab CI, Tekton) replaces `make build`.
- `README.md`: APB framework documentation covering Dockerfile structure, `apb prepare` tooling, and Docker Hub automated build setup. **Migration consideration**: Replace with Ansible project README covering collection requirements, inventory setup, and playbook execution instructions.

---

### Target Details

- **Operating System**: The APBs target **OpenShift Origin / OpenShift Container Platform** (OCP) running on **CentOS 7 or RHEL 7** (as evidenced by the Makefile `TARGET := centos7` / `TARGET := rhel7` build options and the `apb-base` image lineage). Application workloads run inside containers; the underlying node OS is not directly managed by these playbooks. For the migrated Ansible playbooks, the control node should run **RHEL 8/9 or CentOS Stream 8/9** with Ansible Core 2.12+.
- **Virtual Machine Technology**: Not specified. Workloads are container-based, deployed to OpenShift/Kubernetes. No VM-level provisioning is performed.
- **Cloud Platform**: Not explicitly specified. The `oc-login.sh` script supports both in-cluster (Kubernetes ServiceAccount) and external token-based authentication, making the solution cloud-agnostic. Compatible with on-premises OpenShift, OpenShift Dedicated, ARO (Azure Red Hat OpenShift), ROSA (Red Hat OpenShift on AWS), or any Kubernetes distribution.

---

## Migration Approach

### Key Dependencies to Address

- **`ansible.kubernetes-modules` role (deprecated)**: This Galaxy role provided the `openshift_v1_*` and `k8s_v1_*` Ansible modules used in every APB. It has been superseded by the **`kubernetes.core`** collection (formerly `community.kubernetes`). Replace all task module calls as follows:
  - `openshift_v1_route` → `kubernetes.core.k8s` with `apiVersion: route.openshift.io/v1` / `kind: Route`
  - `openshift_v1_deployment_config` → `kubernetes.core.k8s` with `apiVersion: apps.openshift.io/v1` / `kind: DeploymentConfig`, or preferably migrate to `kind: Deployment` (`apps/v1`) for Kubernetes compatibility
  - `openshift_v1_image_stream` → `kubernetes.core.k8s` with `apiVersion: image.openshift.io/v1` / `kind: ImageStream`
  - `k8s_v1_service` → `kubernetes.core.k8s` with `apiVersion: v1` / `kind: Service`
  - `k8s_v1_persistent_volume_claim` → `kubernetes.core.k8s` with `apiVersion: v1` / `kind: PersistentVolumeClaim`
  - Install via: `ansible-galaxy collection install kubernetes.core`

- **`ansibleplaybookbundle.asb-modules` role (deprecated)**: Provides the `asb_encode_binding` module used in `pyzip-demo-db-apb` to export credentials to the Service Broker. The entire ASB binding mechanism is obsolete. Replace with `kubernetes.core.k8s` to create a Kubernetes `Secret` containing the credentials, and reference it via `secretRef` in dependent deployments.

- **`oc create configmap --from-file` shell commands** (used in `hastebin-apb` and `nginx-oss-apb`): These `shell` tasks with `oc` CLI were workarounds for limitations in the old Ansible modules. Replace with `kubernetes.core.k8s` using inline `data:` in the ConfigMap manifest, with template content rendered via `lookup('template', ...)`.

- **`oc create -f` / `oc delete` shell commands** (used in `jenkins-apb`): Shell-based workarounds for broken Ansible module behaviour. Replace with `kubernetes.core.k8s` using inline manifest definitions or `src:` file references.

- **`docker.io/fabianvf/postgresql:postgis`** (pyzip-demo-db-apb): Unofficial PostGIS image. Evaluate replacing with `postgis/postgis:14-3.3` (official PostGIS Docker Hub image) or the Red Hat `registry.redhat.io/rhel8/postgresql-13` with PostGIS extension installation.

- **`docker.io/dymurray/mediawiki123:latest`** (mediawiki123-apb): Unofficial MediaWiki image. Evaluate replacing with the official `mediawiki:1.39` Docker Hub image or a supported alternative.

- **`docker.io/tvelocity/etherpad-lite:latest`** (etherpad-apb): Unofficial Etherpad image. Replace with `etherpad/etherpad:latest` (official image).

- **`docker.io/alessfg/openshift-nginx`** (nginx-oss-apb): Unofficial OpenShift-compatible NGINX image. Replace with `nginxinc/nginx-unprivileged:stable` (runs as non-root, compatible with OpenShift SCCs).

- **OpenShift `DeploymentConfig` (deprecated in OCP 4.14+)**: All APBs use `DeploymentConfig` which is deprecated in favour of standard Kubernetes `Deployment`. Migrate all workloads to `apps/v1 Deployment` during this migration to ensure forward compatibility.

---

### Security Considerations

- **Hardcoded default credentials** (HIGH RISK): Every APB with database or admin credentials uses insecure defaults that are set directly in `defaults/main.yml` and passed as plaintext environment variables to containers:
  - `etherpad-apb`: `mariadb_root_password=admin`, `mariadb_password=admin`, `etherpad_admin_password` defaults to env var with no secure fallback
  - `pyzip-demo-db-apb`: `database_password=admin`, `database_user=admin`, `database_name=admin` — all default to `admin`
  - `mediawiki123-apb`: `mediawiki_admin_pass` parameter with no default enforcement
  - **Migration approach**: Replace all credential defaults with **Ansible Vault**-encrypted variables. Use `ansible-vault encrypt_string` for individual values or vault files. In AAP, use credential types and inject via `extra_vars`. Never pass credentials as plaintext container environment variables — use Kubernetes `Secret` objects with `secretKeyRef` in pod specs.

- **Plaintext credentials in container environment variables**: All database passwords, admin passwords, and API keys are injected as plaintext `env:` values in DeploymentConfig specs. This means credentials are visible in `oc describe dc` output and stored unencrypted in etcd.
  - **Migration approach**: Create Kubernetes `Secret` objects for all credentials and reference them via `secretKeyRef` in Deployment specs. Use `kubernetes.core.k8s` to manage secrets with `no_log: true` on tasks that handle secret data.

- **`ignore_errors: True` in deprovision tasks** (jenkins-apb): Broad error suppression masks real failures during resource cleanup.
  - **Migration approach**: Replace with `failed_when` conditions that distinguish "resource not found" (acceptable) from genuine API errors. Use `kubernetes.core.k8s_info` to check resource existence before deletion.

- **Insecure TLS in `oc-login.sh`**: Uses `--insecure-skip-tls-verify=true` when authenticating with a token.
  - **Migration approach**: Configure proper CA certificate verification in kubeconfig. Use `kubernetes.core` collection with `ca_cert` parameter or a properly configured kubeconfig file.

- **`OPENSHIFT_TOKEN` in environment variable**: The APB runtime passes the OpenShift API token as a plain environment variable to the container.
  - **Migration approach**: Use kubeconfig files managed by Ansible Vault, or AAP Machine/OpenShift credentials. Never store tokens in playbook variables or inventory.

- **APB secrets mount at `/etc/apb-secrets`**: The `entrypoint.sh` reads secrets from a mounted directory and writes them to `/tmp/secrets` as a flat YAML file passed via `--extra-vars`. This is a transient plaintext file on disk.
  - **Migration approach**: Use Ansible Vault for all secrets. In AAP, use the built-in credential injection mechanism which never writes secrets to disk.

- **Credential count by module**:
  - `etherpad-apb`: 4 credentials (MariaDB root password, MariaDB user password, Etherpad admin user, Etherpad admin password)
  - `hastebin-apb`: 0 credentials
  - `jenkins-apb`: 1 credential pattern (OpenShift OAuth token/secret via ServiceAccount annotation)
  - `mediawiki123-apb`: 2 credentials (admin user, admin password)
  - `nginx-oss-apb`: 0 credentials
  - `pyzip-demo-apb`: 0 credentials
  - `pyzip-demo-db-apb`: 3 credentials (database name, user, password) — also exposed via `asb_encode_binding`

---

### Technical Challenges

- **APB execution model elimination**: The entire APB pattern (Docker image + entrypoint + ASB broker dispatch) must be replaced. The new model is standard `ansible-playbook` execution from a control node, CI/CD runner, or AAP job template. All seven APBs need their playbooks extracted from the container model and restructured as standalone Ansible projects or a single monorepo with per-application roles.
  - **Mitigation**: Create a top-level `site.yml` or per-application playbooks. Use Ansible inventory groups to target specific namespaces/clusters. Parameterise via `group_vars`, `host_vars`, or AAP survey variables.

- **`asb_encode_binding` replacement** (pyzip-demo-db-apb): The `asb_encode_binding` module writes credentials to `/var/tmp/bind-creds` for the ASB broker to collect via container exec. This entire mechanism is non-existent outside the APB/ASB ecosystem.
  - **Mitigation**: Replace with `kubernetes.core.k8s` to create a Kubernetes `Secret` in the target namespace. Update `pyzip-demo-apb` to reference this Secret via `envFrom.secretRef` rather than relying on broker binding.

- **Route-first provisioning order in mediawiki123-apb**: The Route is created before the DeploymentConfig specifically to capture the auto-assigned hostname for the `MEDIAWIKI_SITE_SERVER` environment variable. This requires a `kubernetes.core.k8s_info` lookup after Route creation to retrieve the assigned hostname.
  - **Mitigation**: Use `kubernetes.core.k8s_info` with `wait: true` and `wait_condition` to retrieve the Route status after creation. Register the result and extract `status.ingress[0].host` for use in the Deployment manifest.

- **Image reference inconsistency in mediawiki123-apb**: `apb.yml` metadata lists `docker.io/jmontleon/mediawiki123:latest` as a dependency, but the actual DeploymentConfig task uses `docker.io/dymurray/mediawiki123:latest`. Neither image is an official MediaWiki image.
  - **Mitigation**: Standardise on a single, preferably official, MediaWiki image. Audit both images for security vulnerabilities before migration. Consider `mediawiki:1.39-fpm` from Docker Hub official.

- **Broken deprovision in hastebin-apb**: All deprovision tasks are commented out, meaning the hastebin application cannot be cleanly removed via the APB mechanism.
  - **Mitigation**: Implement a proper deprovision playbook using `kubernetes.core.k8s` with `state: absent` for all created resources (ConfigMap, DeploymentConfig/Deployment, Service, Route).

- **`wait_for` port check in pyzip-demo-db-apb**: The task `wait_for port: 5432 host: "{{ dbservice_name }}"` runs on `localhost` (the APB container) but attempts to reach the database service by DNS name. This works inside the OpenShift cluster network but will fail if the control node is external.
  - **Mitigation**: Replace with `kubernetes.core.k8s_info` polling the Deployment `readyReplicas` status, or use `uri` module to check a health endpoint. Alternatively, use `kubernetes.core.k8s` with `wait: true` on the Deployment resource.

- **`psql` CLI dependency for database seeding** (pyzip-demo-db-apb): The seed task runs `psql` via `shell` module, requiring the `psql` client binary on the execution host. In the APB model this was available inside the container; in standard Ansible it may not be present on the control node.
  - **Mitigation**: Use `kubernetes.core.k8s_exec` to run `psql` inside the running PostgreSQL pod, or use the `community.postgresql` collection's `postgresql_script` module from a host with `psql` installed. Copy SQL files to the pod using `kubernetes.core.k8s_cp` before execution.

- **OpenShift-specific resource types**: `DeploymentConfig`, `Route`, `ImageStream`, and `BuildConfig` are OpenShift-specific and do not exist in vanilla Kubernetes. If the target environment may include non-OpenShift Kubernetes clusters, these must be replaced with standard Kubernetes equivalents (`Deployment`, `Ingress`, etc.).
  - **Mitigation**: Parameterise resource types or create separate playbook variants for OpenShift vs. Kubernetes. Use `kubernetes.core.k8s` which handles both via the API server's available resource types.

- **`oc` CLI shell commands**: `hastebin-apb`, `nginx-oss-apb`, and `jenkins-apb` use `shell` tasks with `oc` CLI commands. These require `oc` to be installed and authenticated on the control node.
  - **Mitigation**: Replace all `oc` shell commands with `kubernetes.core.k8s` module calls. ConfigMap creation from file content can use `lookup('template', ...)` or `lookup('file', ...)` inline in the manifest `data:` block.

- **Unofficial container images with `latest` tags**: All APBs use `latest` or unversioned tags from unofficial Docker Hub images. This creates reproducibility and security risks.
  - **Mitigation**: Pin all images to specific digest-based or semantic version tags. Audit images with `trivy` or `grype` before deployment. Prefer official images or Red Hat certified images from `registry.redhat.io`.

---

### Migration Order

1. **pyzip-demo-apb** — Lowest complexity: no parameters, no credentials, no deprovision, single DeploymentConfig + Service + Route. Ideal first migration to validate the `kubernetes.core.k8s` module setup and kubeconfig authentication pattern.

2. **nginx-oss-apb** — Low-medium complexity: no credentials, clean deprovision, but requires replacing the `oc create configmap --from-file` shell command with inline `kubernetes.core.k8s` ConfigMap creation using `lookup('template', ...)`. Good test of template-to-ConfigMap migration pattern.

3. **hastebin-apb** — Medium complexity: two-container pod, ConfigMap from template (same pattern as nginx), requires implementing the missing deprovision playbook. No credentials.

4. **mediawiki123-apb** — Medium complexity: introduces PVC management, order-dependent Route-first provisioning (requires `k8s_info` result registration), and credential parameters. Resolve image reference inconsistency during this step.

5. **etherpad-apb** — Medium-high complexity: two-tier application (MariaDB + Etherpad), two PVCs, multiple credentials requiring Vault integration, `bindable: True` requiring Secret-based credential export to replace ASB binding.

6. **pyzip-demo-db-apb** — High complexity: PostGIS database with SQL seeding via `psql` shell (requires `k8s_exec` or `community.postgresql` migration), `asb_encode_binding` replacement with Kubernetes Secret, ImageStream management, `wait_for` replacement with `k8s` wait conditions. Must be migrated before or alongside `pyzip-demo-apb` to maintain the app+db pairing.

7. **jenkins-apb** — Highest complexity: most resource types (Service × 2, Route, PVC, ServiceAccount, RoleBinding, ImageStream, BuildConfig, DeploymentConfig), OpenShift OAuth integration, S2I BuildConfig, multiple `oc create/delete` shell workarounds, `ignore_errors` cleanup, and the most parameters. Migrate last after all patterns are established.

---

### Assumptions

1. **Target platform is OpenShift 4.x**: The migration assumes OpenShift 4.x (OCP 4.10+) as the target, where `DeploymentConfig` is still available but deprecated. If the target is vanilla Kubernetes or OpenShift 4.14+ with DC removal, all `DeploymentConfig` resources must be replaced with `apps/v1 Deployment`.

2. **Ansible Service Broker (ASB) is being decommissioned**: The migration assumes the ASB and its service catalog are being retired. The `bindable` APB pattern and `asb_encode_binding` credential exchange mechanism will not exist in the target environment.

3. **`kubernetes.core` collection is the replacement for `ansible.kubernetes-modules`**: It is assumed that `kubernetes.core` (version 2.3+) will be installed on the control node or AAP execution environment. This collection provides `k8s`, `k8s_info`, `k8s_exec`, `k8s_cp`, and `k8s_auth` modules.

4. **Control node has `kubectl`/`oc` CLI available or kubeconfig is sufficient**: Some tasks (database seeding, ConfigMap creation) currently rely on CLI tools. The migration plan assumes these will be replaced with pure Ansible module calls, but if `oc` CLI is retained as a fallback, it must be present on the control node.

5. **Namespace pre-existence**: The APBs assume the target OpenShift namespace/project already exists (sourced from `NAMESPACE` environment variable). The migrated playbooks should either create the namespace or document it as a prerequisite.

6. **`docker.io` images are accessible**: All APBs pull images from Docker Hub (`docker.io`). If the target environment uses a private registry or has Docker Hub pull rate limits, image mirroring to an internal registry (e.g., Quay.io, Nexus, Harbor) must be planned.

7. **SQL seed files are static**: The five SQL/DDL files in `pyzip-demo-db-apb/roles/provision-pyzip-demo-db-apb/files/` (`parkcoord.sql`, `airports.ddl`, `airports.sql`, `zipcodes.ddl`, `zipcodes.sql`) are treated as static seed data. It is assumed these do not need to be regenerated or parameterised.

8. **No existing Ansible Vault infrastructure**: The migration plan assumes Vault/secrets management must be built from scratch. If an existing HashiCorp Vault, AAP credential store, or Kubernetes Secrets management solution is already in place, the credential migration steps should be adapted accordingly.

9. **`mediawiki_admin_pass` is intentionally a required parameter with no default**: The `mediawiki123-apb` `apb.yml` lists `mediawiki_admin_pass` as a parameter but the `defaults/main.yml` does not provide a fallback. This is assumed to be intentional (force the operator to set a password) and should be preserved in the migrated role.

10. **Jenkins OAuth integration requires OpenShift OAuth server**: The `enable_oauth` feature in `jenkins-apb` relies on the OpenShift OAuth server and the `OAuthRedirectReference` annotation mechanism. If the target environment does not have OpenShift OAuth (e.g., vanilla Kubernetes), this feature must be disabled or replaced with an alternative authentication provider (LDAP, GitHub OAuth via Jenkins plugin).

11. **`pyzip-demo-apb` and `pyzip-demo-db-apb` are intended to be deployed together**: The web application (`pyzip-demo-apb`) connects to the database deployed by `pyzip-demo-db-apb`. The current APBs do not explicitly wire them together (no binding call in `pyzip-demo-apb`). It is assumed the database service name (`dbservice`) is a known convention and the web app connects to it by name. The migrated solution should make this dependency explicit.

12. **The `apb-base` directory is a shared base image, not an application APB**: `apb-base` provides the container runtime scripts (`entrypoint.sh`, `oc-login.sh`, `bind-init`, `broker-bind-creds`) and Ansible configuration. It is not an application to be migrated but rather infrastructure that is entirely replaced by the new execution model.

13. **Makefile targets `hello-world-apb` and `rhscl-mysql-apb` are not present in this repository**: The `Makefile` references these directories but they do not exist in the current repository tree. They are assumed to be separate repositories or have been removed, and are out of scope for this migration.
