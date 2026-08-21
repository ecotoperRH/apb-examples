# MIGRATION FROM ANSIBLE PLAYBOOK BUNDLES (APB) TO ANSIBLE

## Executive Summary

This repository (`apb-examples`) is a collection of **Ansible Playbook Bundles (APBs)** — a now-deprecated packaging format that wrapped Ansible playbooks inside Docker/OCI container images to integrate with the OpenShift Ansible Service Broker (ASB). Each APB is a self-contained containerized unit that provisions, deprovisions, and optionally binds application services on an OpenShift/Kubernetes cluster.

The migration target is **standard Ansible** (roles, playbooks, and collections) decoupled from the APB container runtime, using the modern `kubernetes.core` collection (formerly `community.kubernetes`) in place of the legacy `ansible.kubernetes-modules` role and the deprecated `openshift_v1_*` / `k8s_v1_*` module aliases.

**Repository contains 7 APB modules** spanning web applications, CI/CD, databases, and a shared base image layer.

**Estimated migration complexity: Medium** — The Ansible logic itself is largely sound and portable; the primary effort is replacing deprecated OpenShift/Kubernetes module APIs, removing the APB container runtime dependency, restructuring credential/binding handling, and completing incomplete deprovision implementations.

**Estimated timeline: 3–5 weeks** for a single engineer, or 1–2 weeks with a small team (one engineer per APB in parallel).

---

## Module Migration Plan

This repository contains 7 Ansible Playbook Bundle (APB) modules plus one shared base image layer, each requiring individual migration planning.

---

### MODULE INVENTORY

- **etherpad-apb**
  - **Description**: Deploys Etherpad Lite (collaborative note-taking web application) backed by a MariaDB database on OpenShift. Provisions two DeploymentConfigs (etherpad + mariadb), two Services, one Route, and two PVCs (1Gi each for MariaDB data and logs). Bindable — exposes database credentials to consuming services. Supports configurable DB name, user, and passwords.
  - **Path**: `etherpad-apb/`
  - **Technology**: Ansible Playbook Bundle (APB)
  - **Key Features**: MariaDB 3306 backend with persistent storage (data + logs PVCs), Etherpad Lite on port 9001, OpenShift Route exposure, bind credential support, `state` variable controls both provision and deprovision, no deprovision playbook present (uses `state: absent` pattern via single provision role)

- **hastebin-apb**
  - **Description**: Deploys Hastebin (pastebin-style web application) with a Memcached backend on OpenShift. Provisions a single DeploymentConfig with two containers (hastebin on port 7777, memcached on port 11211), a Service (80→7777), and a Route. Configuration is injected via a ConfigMap generated from a Jinja2 template (`config.js.j2`). Stateless — no PVC.
  - **Path**: `hastebin-apb/`
  - **Technology**: Ansible Playbook Bundle (APB)
  - **Key Features**: Dual-container DeploymentConfig (hastebin + memcached co-located), ConfigMap-based `config.js` injection via `oc create configmap` shell command, configurable `hastebin_port` (7777), `max_length` (400000), `key_length` (10); deprovision role exists but all tasks are **commented out** (no-op)

- **jenkins-apb**
  - **Description**: Deploys Jenkins CI/CD server on OpenShift using the built-in `jenkins:latest` ImageStreamTag from the `openshift` namespace. Supports optional persistence (PVC), OpenShift OAuth integration, optional S2I (source-to-image) custom Jenkins build from a Git repository, and configurable memory limits. Creates two Services (HTTP + JNLP agent), a TLS-terminated edge Route, a ServiceAccount, and a RoleBinding granting `edit` permissions.
  - **Path**: `jenkins-apb/`
  - **Technology**: Ansible Playbook Bundle (APB)
  - **Key Features**: Optional PVC (1Gi RWO) vs. emptyDir storage, OpenShift OAuth via `OPENSHIFT_ENABLE_OAUTH` env var and `OAuthRedirectReference` annotation, JNLP agent service on port 50000, S2I BuildConfig from configurable Git URI/ref/context, TLS edge Route, ServiceAccount + RoleBinding (`edit`) via raw YAML templates, liveness/readiness probes on `/login:8080`, memory limit enforcement, fully implemented deprovision role

- **mediawiki123-apb**
  - **Description**: Deploys MediaWiki 1.23 (wiki application) on OpenShift using the `docker.io/dymurray/mediawiki123:latest` image. Provisions a Route (created first to capture the hostname for `MEDIAWIKI_SITE_SERVER`), a PVC (1Gi RWO), a DeploymentConfig (port 8080), and a Service. All five parameters (DB schema, site name, language, admin user, admin password) are required.
  - **Path**: `mediawiki123-apb/`
  - **Technology**: Ansible Playbook Bundle (APB)
  - **Key Features**: Route-first provisioning pattern (hostname captured as `route.route.spec.host` and fed back as `MEDIAWIKI_SITE_SERVER` env var), 1Gi persistent volume for wiki data, all credentials passed as required parameters with no defaults, deprovision implemented entirely in `post_tasks` (not a role) — scales DC to 0, deletes RC `mediawiki123-1`, DC, Service, PVC, Route in sequence

- **nginx-oss-apb**
  - **Description**: Deploys an Nginx Open Source reverse proxy/load balancer on OpenShift using `docker.io/alessfg/openshift-nginx` (port 8080). Supports optional upstream load balancing with configurable method (round_robin, least_conn, ip_hash, hash). Nginx configuration is injected via a ConfigMap generated from `default.conf.j2`. Creates a DeploymentConfig, Service (80→8080), and Route.
  - **Path**: `nginx-oss-apb/`
  - **Technology**: Ansible Playbook Bundle (APB)
  - **Key Features**: Jinja2-templated `default.conf` with conditional upstream block (lb mode) or static file serving (non-lb mode), four load-balancing algorithms including `hash $request_uri`, ConfigMap mounted at `/etc/nginx/conf.d`, `oc create configmap` shell command for ConfigMap creation, no defaults file (all vars from `apb.yml` parameters), fully implemented deprovision

- **pyzip-demo-apb**
  - **Description**: Deploys a Python ZIP code demo web application (`docker.io/ansibleplaybookbundle/py-zip-demo:latest`) on OpenShift. Minimal APB — creates only a Route, Service (port 8080), and DeploymentConfig. No parameters, no persistent storage, no bind support.
  - **Path**: `pyzip-demo-apb/`
  - **Technology**: Ansible Playbook Bundle (APB)
  - **Key Features**: Parameterless deployment, port 8080 HTTP service, **incomplete implementation** — no deprovision playbook and no deprovision role exist, namespace sourced from `NAMESPACE` env var defaulting to `pyzip-demo`

- **pyzip-demo-db-apb**
  - **Description**: Deploys a PostGIS-enabled PostgreSQL database (`docker.io/fabianvf/postgresql:postgis`) on OpenShift to back the pyzip-demo application. Bindable — encodes and exposes five connection credentials (host, port, user, password, database) via `asb_encode_binding`. Seeds the database with geospatial data (park coordinates, airports, ZIP codes) from bundled SQL/DDL files. Creates a PVC (1Gi RWO), Service (5432), ImageStream, and DeploymentConfig with a persistent volume mount at `/var/lib/pgsql/data`.
  - **Path**: `pyzip-demo-db-apb/`
  - **Technology**: Ansible Playbook Bundle (APB)
  - **Key Features**: PostGIS extension support, database seeding from 5 bundled SQL/DDL files (`parkcoord.sql`, `airports.ddl`, `zipcodes.ddl`, `airports.sql`, `zipcodes.sql`) via `psql` shell command, `asb_encode_binding` for service binding credential export, `wait_for` port 5432 readiness check before seeding, credentials sourced from env vars (`POSTGRESQL_DATABASE`, `POSTGRESQL_PASSWORD`, `POSTGRESQL_USER`) with insecure defaults (`admin`/`admin`/`admin`), deprovision in `post_tasks` (scales DC to 0, deletes PVC, DC, Service, ImageStream)

---

### Infrastructure Files

- **`apb-base/files/usr/bin/entrypoint.sh`**: The APB container runtime entrypoint. Handles `oc login` (token or service account), mounts secrets from `/etc/apb-secrets`, dispatches `ansible-playbook` for the requested action (provision/deprovision/bind), and invokes `bind-init` to hold the container alive for credential retrieval. **Not needed in standard Ansible** — this entire runtime shim is replaced by direct `ansible-playbook` invocation.
- **`apb-base/files/usr/bin/oc-login.sh`**: Authenticates to OpenShift using either `OPENSHIFT_TOKEN` + `OPENSHIFT_TARGET` env vars or the in-cluster service account token/CA. **Replaced** by `kubernetes.core` collection's kubeconfig/token authentication.
- **`apb-base/files/etc/ansible/ansible.cfg`**: Sets `roles_path = /etc/ansible/roles:/opt/ansible/roles`. Migrate to a standard project-level `ansible.cfg`.
- **`apb-base/files/etc/ansible/hosts`**: Static inventory with `localhost ansible_connection=local`. Migrate to a proper inventory file or dynamic inventory for the target environment.
- **`apb-base/files/usr/bin/bind-init`**, **`broker-bind-creds`**, **`test-retrieval`**, **`test-retrieval-init`**: APB broker-specific credential exchange and test utilities. **No equivalent needed** in standard Ansible — binding is replaced by Ansible variable passing or Vault-stored secrets.
- **`Makefile`**: Builds Docker images for a subset of APBs (`apb-base`, `hello-world-apb`, `jenkins-apb`, `rhscl-mysql-apb`) for `centos7` or `rhel7` targets. References APBs not present in this repository (`hello-world-apb`, `rhscl-mysql-apb`). **Not needed** post-migration; replace with a CI pipeline (e.g., GitHub Actions, Tekton) that runs `ansible-playbook` directly.
- **`README.md`**: APB framework documentation covering Dockerfile structure, `apb prepare` tooling, and broker integration. Superseded by standard Ansible documentation post-migration.
- **`pyzip-demo-db-apb/roles/provision-pyzip-demo-db-apb/files/`**: Contains 5 geospatial seed data files: `parkcoord.sql`, `airports.ddl`, `airports.sql`, `zipcodes.ddl`, `zipcodes.sql`. These static data files are directly portable to the migrated Ansible role's `files/` directory.

---

### Target Details

- **Operating System**: Not explicitly specified in the APB manifests. All workloads run as OCI containers on OpenShift/Kubernetes nodes. The APB base image (`ansibleplaybookbundle/apb-base`) is CentOS 7 / RHEL 7 based (per Makefile `TARGET := centos7` / `rhel7`). Container images reference `docker.io/mariadb:latest`, `docker.io/fabianvf/postgresql:postgis`, `docker.io/dymurray/mediawiki123:latest`, `docker.io/tvelocity/etherpad-lite:latest`, `docker.io/dymurray/hastebin:latest`, `docker.io/alessfg/openshift-nginx`, and `docker.io/ansibleplaybookbundle/py-zip-demo:latest`. Target OS for the Ansible control node defaults to **Red Hat Enterprise Linux 9** if not otherwise specified.
- **Virtual Machine Technology**: Not specified. Workloads are container-native (OpenShift DeploymentConfigs). No VM-level provisioning is performed.
- **Cloud Platform**: **OpenShift / Kubernetes** (on-premises or OpenShift Online). All resource types are OpenShift-specific (`openshift_v1_deployment_config`, `openshift_v1_route`, `openshift_v1_image_stream`, `openshift_v1_build_config`). No cloud-provider-specific configurations (AWS/Azure/GCP) are present.

---

## Migration Approach

### Key Dependencies to Address

- **`ansible.kubernetes-modules` role (legacy)**: Used in every APB's `provision.yml` as `role: ansible.kubernetes-modules`. This role provided the `k8s_v1_*` and `openshift_v1_*` module shims. **Replace with**: `kubernetes.core` collection (`kubernetes.core.k8s` module) installed via `ansible-galaxy collection install kubernetes.core`. All `k8s_v1_persistent_volume_claim`, `k8s_v1_service`, `openshift_v1_deployment_config`, `openshift_v1_route`, `openshift_v1_image_stream`, `openshift_v1_build_config` tasks must be rewritten using `kubernetes.core.k8s` with inline resource manifests.
- **`ansibleplaybookbundle.asb-modules` role**: Used in `pyzip-demo-db-apb` for the `asb_encode_binding` module that writes bind credentials for the broker. **Replace with**: Write credentials to Ansible Vault, a Kubernetes Secret, or a HashiCorp Vault instance. The `asb_encode_binding` task should be replaced by `kubernetes.core.k8s` creating a Kubernetes Secret containing the connection parameters.
- **`openshift_v1_deployment_config` (DeploymentConfig)**: OpenShift-specific resource type deprecated in OpenShift 4.x and removed in OpenShift 4.14+. **Replace with**: Standard Kubernetes `Deployment` resources (`kubernetes.core.k8s` with `kind: Deployment`). This affects all 7 APBs.
- **`openshift_v1_route` (Route)**: OpenShift-specific ingress resource. **Replace with**: Kubernetes `Ingress` resource for generic Kubernetes targets, or retain `Route` if targeting OpenShift 4.x using the `redhat.openshift` collection.
- **`openshift_v1_image_stream` / `openshift_v1_build_config`**: OpenShift-specific S2I resources used in `jenkins-apb` and `pyzip-demo-db-apb`. **Replace with**: Standard container image references in `Deployment` specs; S2I BuildConfig can be replaced by a CI/CD pipeline (Tekton, GitHub Actions) that builds and pushes images.
- **`oc` CLI shell commands**: Several APBs use `shell: oc create configmap ...` (`hastebin-apb`, `nginx-oss-apb`) and `shell: oc create -f` / `shell: oc delete rolebinding` (`jenkins-apb`). **Replace with**: `kubernetes.core.k8s` module with inline ConfigMap/RoleBinding manifests, eliminating the `oc` binary dependency.
- **`psql` CLI shell command** (`pyzip-demo-db-apb`): Database seeding uses `shell: PGPASSWORD=... psql -f {{ item }}`. **Replace with**: `community.postgresql.postgresql_script` module or retain the shell task with proper `no_log: true` to protect the password.
- **`wait_for` module** (`pyzip-demo-db-apb`): Waits for port 5432 on the service hostname. This works inside the cluster network but not from an external control node. **Replace with**: `kubernetes.core.k8s_info` polling on the Deployment's `readyReplicas` condition, or a `uri` module health check via the OpenShift Route.
- **Docker image references**: All images use `docker.io` registry with `latest` tags (`docker.io/mariadb:latest`, `docker.io/tvelocity/etherpad-lite:latest`, etc.). **Replace with**: Pinned digest or versioned tags in a private registry to ensure reproducibility and security.

---

### Security Considerations

- **Hardcoded default credentials (HIGH RISK)**: Every APB uses insecure default passwords that are trivially guessable:
  - `etherpad-apb`: `mariadb_root_password=admin`, `mariadb_password=admin`, `etherpad_admin_password=admin`
  - `hastebin-apb`: No credentials, but no authentication on the service
  - `jenkins-apb`: OAuth delegated to OpenShift; no hardcoded passwords
  - `mediawiki123-apb`: `mediawiki_admin_pass` is a required parameter with no default, but no complexity enforcement
  - `nginx-oss-apb`: No credentials
  - `pyzip-demo-apb`: No credentials
  - `pyzip-demo-db-apb`: `database_password=admin`, `database_user=admin`, `database_name=admin`
  - **Migration approach**: Replace all default credential values with Ansible Vault-encrypted variables. Use `ansible-vault encrypt_string` for inline secrets or a dedicated `vault.yml` per environment. Enforce strong password generation using `ansible.builtin.password` lookup.

- **Credentials passed as plaintext environment variables**: All database passwords (`MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, `POSTGRESQL_PASSWORD`, `ETHERPAD_ADMIN_PASSWORD`) are injected directly into container `env:` blocks as plaintext values. **Migration approach**: Replace with Kubernetes Secrets referenced via `secretKeyRef` in the container env spec. Create secrets using `kubernetes.core.k8s` with `no_log: true`.

- **`no_log` missing on credential tasks**: The `pyzip-demo-db-apb` database seeding shell command embeds `{{ database_password }}` directly in the shell string without `no_log: true`, exposing the password in Ansible output logs. **Migration approach**: Add `no_log: true` to all tasks handling credentials.

- **TLS/HTTPS**: `jenkins-apb` creates a TLS edge-terminated Route (TLS termination at the OpenShift router). All other APBs create plain HTTP Routes with no TLS. **Migration approach**: Enforce TLS on all Routes/Ingresses. Use cert-manager or OpenShift's built-in certificate management for automated certificate provisioning.

- **`--insecure-skip-tls-verify=true`** in `oc-login.sh`: The APB base image skips TLS verification when connecting to OpenShift with a token. **Migration approach**: Provide a proper kubeconfig with CA certificate validation enabled. Never use `insecure-skip-tls-verify` in production.

- **ServiceAccount with `edit` RoleBinding** (`jenkins-apb`): Jenkins is granted `edit` role on its namespace, allowing it to create/modify most resources. **Migration approach**: Review whether `edit` is the minimum required permission; consider a custom Role with only the specific verbs/resources Jenkins needs.

- **`latest` image tags**: All 7 APBs pull `latest` container images, creating unpredictable deployments and potential supply-chain risks. **Migration approach**: Pin all images to specific SHA256 digests or semantic version tags. Implement image scanning in CI.

- **Bind credentials exposure** (`etherpad-apb`, `pyzip-demo-db-apb`): The APB broker credential exchange mechanism (`asb_encode_binding`, `bind-init`) writes credentials to `/var/tmp/bind-creds` inside the container and holds the container running for the broker to `exec` in and retrieve them. This is an insecure pattern. **Migration approach**: Replace with Kubernetes Secrets created by the provisioning playbook, consumed by dependent workloads via `secretKeyRef`.

- **Credential count by module**:
  - `etherpad-apb`: 4 credentials (mariadb root password, mariadb user password, etherpad admin user, etherpad admin password)
  - `hastebin-apb`: 0 credentials
  - `jenkins-apb`: 0 hardcoded credentials (OAuth-delegated)
  - `mediawiki123-apb`: 2 credentials (admin user, admin password — required parameters)
  - `nginx-oss-apb`: 0 credentials
  - `pyzip-demo-apb`: 0 credentials
  - `pyzip-demo-db-apb`: 3 credentials (database name, user, password)

---

### Technical Challenges

- **DeploymentConfig → Deployment migration**: All 7 APBs use `openshift_v1_deployment_config`, which is an OpenShift-specific resource deprecated since OpenShift 4.x. Migrating to standard `Deployment` requires rewriting trigger logic (ImageChange triggers become `imagePullPolicy: Always` + image digest pinning) and Recreate/Rolling strategy mappings. The `jenkins-apb` DC template (`dc.yaml.j2`) is particularly complex with conditional persistent/emptyDir volumes, OAuth annotations, and ImageStreamTag references.

- **Deprecated `k8s_v1_*` / `openshift_v1_*` module API**: The entire `ansible.kubernetes-modules` role is unmaintained and incompatible with modern Ansible and Kubernetes API versions. Every single task across all 7 APBs must be rewritten using `kubernetes.core.k8s`. The module parameter naming conventions differ significantly (e.g., `resources_requests.storage` → nested `spec.resources.requests.storage` in the resource manifest).

- **Incomplete deprovision implementations**:
  - `hastebin-apb`: Deprovision role exists but **all tasks are commented out** — no cleanup occurs on deprovision.
  - `pyzip-demo-apb`: **No deprovision playbook or role exists at all** — the APB is incomplete.
  - `etherpad-apb`: No separate deprovision playbook; relies on `state: absent` being passed to the provision role, but there is no `deprovision.yml` playbook to invoke this.
  - These must all be implemented from scratch in the migrated roles.

- **ConfigMap creation via `oc` shell commands**: `hastebin-apb` and `nginx-oss-apb` use `shell: oc create configmap ... --from-file=...` to inject Jinja2-rendered templates as ConfigMaps. This is idempotency-breaking (the command fails if the ConfigMap already exists) and requires the `oc` binary. **Mitigation**: Replace with `kubernetes.core.k8s` tasks that render the template inline using `template` lookup and embed the result in the ConfigMap `data:` field.

- **In-cluster network dependency** (`pyzip-demo-db-apb`): The `wait_for port: 5432 host: "{{ dbservice_name }}"` task and the `psql` seeding shell commands assume the Ansible control node is running inside the same Kubernetes network as the database service. In a standard Ansible execution environment outside the cluster, these will fail. **Mitigation**: Use `kubernetes.core.k8s_info` to poll pod readiness, and execute the seeding via a Kubernetes Job resource or `kubernetes.core.k8s_exec`.

- **Route hostname capture pattern** (`mediawiki123-apb`): The Route is created first, then its `.spec.host` is captured and fed back as the `MEDIAWIKI_SITE_SERVER` environment variable in the DeploymentConfig. This circular dependency (Route hostname needed before DC creation) must be carefully preserved in the migrated playbook, using `kubernetes.core.k8s_info` to retrieve the Route after creation.

- **S2I BuildConfig migration** (`jenkins-apb`): The optional S2I build path creates an ImageStream and BuildConfig to compile a custom Jenkins image from a Git source. This OpenShift-specific feature has no direct Kubernetes equivalent. **Mitigation**: Replace with a standard CI pipeline (Tekton Pipeline, GitHub Actions with `docker build`) that builds and pushes to an image registry, then reference the resulting image tag in the Deployment.

- **`OAuthRedirectReference` annotation** (`jenkins-apb`): Jenkins OAuth integration uses an OpenShift-specific `serviceaccounts.openshift.io/oauth-redirectreference.jenkins` annotation on the ServiceAccount. This is only valid on OpenShift 4.x. **Mitigation**: If targeting OpenShift, retain this annotation using the `redhat.openshift` collection. If targeting vanilla Kubernetes, replace with a standard OAuth2 proxy sidecar (e.g., `oauth2-proxy`).

- **`apb.yml` parameter schema → Ansible variables**: Each APB's `apb.yml` defines a parameter schema with types, defaults, validation (maxlength, enum), and display metadata consumed by the OpenShift Service Catalog UI. This schema has no direct Ansible equivalent. **Mitigation**: Translate parameters to role `defaults/main.yml` variables with inline comments documenting constraints. Consider using `ansible.builtin.assert` tasks to enforce validation rules (maxlength, enum values) at runtime.

- **`asb_encode_binding` module** (`pyzip-demo-db-apb`, `etherpad-apb`): This module is part of the `ansibleplaybookbundle.asb-modules` collection and writes credentials to the broker's credential file. It has no meaning outside the APB/broker context. **Mitigation**: Replace with `kubernetes.core.k8s` creating a Kubernetes Secret, and document the secret name/namespace for consuming applications.

---

### Migration Order

1. **`pyzip-demo-apb`** — Lowest complexity: no parameters, no credentials, no persistent storage, no bind support. Ideal first migration to establish the `kubernetes.core.k8s` pattern and validate the target cluster connectivity. Also requires implementing the missing deprovision playbook.

2. **`nginx-oss-apb`** — Low-to-medium complexity: no credentials, straightforward ConfigMap + Deployment + Service + Ingress pattern. Good second migration to establish the ConfigMap-from-template pattern that replaces `oc create configmap` shell commands.

3. **`hastebin-apb`** — Medium complexity: introduces dual-container pod pattern and ConfigMap injection. Requires implementing the currently no-op deprovision role. No credentials to manage.

4. **`mediawiki123-apb`** — Medium complexity: introduces the Route-first hostname-capture pattern and required credential parameters. Requires Vault integration for `mediawiki_admin_pass`. Deprovision logic exists in `post_tasks` and must be moved to a proper role.

5. **`etherpad-apb`** — Medium-high complexity: first bindable APB migration, introduces multi-tier deployment (app + database), two PVCs, and credential management for 4 secrets. Requires implementing a proper deprovision playbook.

6. **`pyzip-demo-db-apb`** — High complexity: bindable APB with PostGIS database, in-cluster seeding via `psql`, `asb_encode_binding` replacement, and `wait_for` in-cluster network dependency. Requires the most significant rearchitecting of the credential binding pattern.

7. **`jenkins-apb`** — Highest complexity: most feature-rich APB with OAuth integration, S2I BuildConfig, ServiceAccount/RoleBinding, conditional persistent storage, JNLP agent service, and complex Jinja2 DC template. Migrate last after all patterns are established.

---

### Assumptions

1. **Target platform**: It is assumed the migration target is **OpenShift 4.x** (not vanilla Kubernetes), given the pervasive use of OpenShift-specific resources (Routes, DeploymentConfigs, ImageStreams, BuildConfigs, OAuth). If the target is vanilla Kubernetes, Routes must become Ingresses, DeploymentConfigs become Deployments, and all OpenShift-specific features (S2I, OAuth) require alternative implementations.

2. **`ansible.kubernetes-modules` replacement**: It is assumed the `kubernetes.core` collection (v2.x+) will be used as the replacement for all `k8s_v1_*` and `openshift_v1_*` module calls. If targeting OpenShift specifically, the `redhat.openshift` collection may also be needed for Route and OAuth resources.

3. **Execution environment**: The migrated playbooks will be executed from an Ansible control node **outside** the OpenShift cluster, authenticating via kubeconfig or `KUBECONFIG` environment variable. The current in-cluster execution model (APB container running inside OpenShift) is being abandoned.

4. **`pyzip-demo-db-apb` database seeding**: It is assumed that database seeding (the `psql` shell commands) will be migrated to a Kubernetes Job resource executed inside the cluster, since the seeding requires network access to the PostgreSQL service which is only available within the cluster network.

5. **Bind credential replacement**: The `asb_encode_binding` pattern (APB broker credential exchange) will be replaced by Kubernetes Secrets. It is assumed consuming applications will be updated to read credentials from the Secret rather than from the broker binding mechanism.

6. **Image registry**: It is assumed that the `docker.io` image references will be reviewed and either pinned to specific versions or mirrored to an internal registry. The `docker.io/dymurray/*` and `docker.io/fabianvf/*` images are community/personal images with no SLA and may be unavailable or outdated.

7. **`etherpad-apb` deprovision**: The `etherpad-apb` has no `deprovision.yml` playbook. It is assumed the `state` variable pattern (passing `state: absent` to the provision role) was the intended deprovision mechanism, and a proper `deprovision.yml` will be created that sets `state: absent` and calls the provision role.

8. **`hastebin-apb` deprovision**: The commented-out deprovision tasks suggest the deprovision role was scaffolded but never implemented. It is assumed the intent was to delete the Route, Service, DeploymentConfig, and ConfigMap. These tasks will be implemented from scratch.

9. **`pyzip-demo-apb` completeness**: The absence of a deprovision playbook and role is treated as an incomplete implementation, not an intentional design choice. A deprovision playbook will be created.

10. **Makefile scope**: The `Makefile` references `hello-world-apb` and `rhscl-mysql-apb` directories that do not exist in this repository. These are assumed to be external repositories and are out of scope for this migration.

11. **OpenShift Service Catalog**: The APB parameter schema in `apb.yml` (types, display names, cost metadata) was consumed by the OpenShift Service Catalog UI, which is also deprecated. It is assumed there is no requirement to replicate the Service Catalog UI experience; parameters will become standard Ansible role variables.

12. **Security posture**: All default credentials (`admin`/`admin`) are assumed to be development/demo values only and will be replaced with Vault-managed secrets before any production deployment. The migration plan treats all hardcoded defaults as security findings requiring remediation.

13. **`jenkins-apb` S2I**: The optional S2I Git build path (`source_git_uri`, `source_git_ref`, `source_context_dir` parameters) is assumed to be a non-critical feature used for custom Jenkins image builds. If not required in the target environment, this code path can be removed; otherwise it requires a CI pipeline replacement.

14. **`mediawiki123-apb` database**: The MediaWiki deployment uses `docker.io/dymurray/mediawiki123:latest` which appears to bundle its own SQLite or pre-configured database. No external database service is provisioned. This assumption should be validated against the image's actual configuration before migration.
