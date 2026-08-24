---
source-path: mediawiki123-apb
---

Now I have a complete picture of the entire project. Let me compile the full migration plan.

---

# Migration Plan: mediawiki123-apb

**TLDR**: `mediawiki123-apb` is a legacy **Ansible Playbook Bundle (APB)** — a now-deprecated OpenShift Service Catalog packaging format — that provisions a MediaWiki 1.23 instance on OpenShift 3.x. It uses a suite of tombstoned OpenShift/Kubernetes-specific modules (`openshift_v1_route`, `openshift_v1_deployment_config`, `openshift_v1_project`, `k8s_v1_persistent_volume_claim`, `k8s_v1_service`, `k8s_v1_replication_controller`) from the equally-deprecated `ansible.kubernetes-modules` role. The entire APB runtime, container packaging, and module ecosystem must be replaced with the modern `kubernetes.core` collection, standard Ansible roles, and Kubernetes-native manifests (Deployment + Service + PVC + Ingress/Route). Additional modernization needs include: FQCN adoption, `include_vars`/`include_role` → `ansible.builtin.*` equivalents, boolean literals, and a new `meta/argument_specs.yml`.

---

## Service Type and Configuration

**Service Type**: Kubernetes/OpenShift Application Deployment (Container Workload Provisioner)

**Key Operations**:
- **Provision**: Creates an OpenShift Route, a PersistentVolumeClaim (1Gi, ReadWriteOnce), a DeploymentConfig (1 replica of `docker.io/dymurray/mediawiki123:latest`), and a Service (port 8080) in a target namespace
- **Deprovision**: Tears down the Route, PVC, scales DeploymentConfig to 0, removes the ReplicationController, DeploymentConfig, and Service
- **Test/Verify**: Creates a test project namespace, runs the provision role, then performs an HTTP health check against the provisioned route
- **Container packaging**: Three Dockerfiles build the APB image from `ansibleplaybookbundle/apb-base` (latest, nightly, canary variants), embedding the `apb.yml` spec as a base64 label and installing the role via `yum`
- **Parameters managed**: `mediawiki_db_schema`, `mediawiki_site_name`, `mediawiki_site_lang`, `mediawiki_admin_user`, `mediawiki_admin_pass`, `mediawiki_volume_size`, `namespace`

---

## File Structure

**Playbook Files:**
```
playbooks/provision.yml
playbooks/deprovision.yml
playbooks/test.yml
playbooks/vars/test_defaults.yaml
```

**Task Files:**
```
roles/provision-mediawiki123-apb/tasks/main.yml
roles/verify-mediawiki123-apb/tasks/main.yaml
```

**Variable Files:**
```
roles/provision-mediawiki123-apb/defaults/main.yml
```

**APB Metadata / Spec:**
```
apb.yml
mediawiki-apb-role.spec
```

**Container Build Files:**
```
Dockerfile-latest
Dockerfile-nightly
Dockerfile-canary
```

---

## Module Explanation

The role performs operations in this order:

### 1. **Provision entry-point** (`playbooks/provision.yml`)
- Declares `hosts: localhost`, `connection: local`, `gather_facts: false`
- Loads the deprecated `ansible.kubernetes-modules` role with `install_python_requirements: no` — this role shipped Python OpenShift/K8s client libraries and all the `openshift_v1_*` / `k8s_v1_*` modules; it is **entirely tombstoned** and has no modern equivalent as a role
- Delegates all real work to `provision-mediawiki123-apb`
- **Legacy pattern**: `install_python_requirements: no` — boolean string `no` instead of `false`
- **Modern equivalent**: Remove `ansible.kubernetes-modules` role entirely; install `kubernetes.core` collection; use `ansible.builtin.pip` or EE bindep to install `kubernetes` Python package

### 2. **Provision role defaults** (`roles/provision-mediawiki123-apb/defaults/main.yml`)
- Sets `namespace` via `lookup('env','NAMESPACE')` with a default of `'mediawiki123'`
- Sets `mediawiki_volume_size: "1Gi"`
- **No legacy boolean/octal issues** in this file
- **Note**: `namespace` sourced from environment variable is an APB-runtime convention; in a modern role this should be an explicit variable with documentation in `argument_specs.yml`

### 3. **Provision role tasks** (`roles/provision-mediawiki123-apb/tasks/main.yml`)

#### Task 1 — Create Route
- **Legacy module**: `openshift_v1_route` (from `ansible.kubernetes-modules`)
- **Parameters used**: `name`, `namespace`, `spec_port_target_port`, `labels`, `to_name`, `state`
- **Parameter drift**: `spec_port_target_port` and `to_name` are flattened parameter-style names specific to the old dynamic module generator; `kubernetes.core.k8s` uses raw Kubernetes manifest YAML under a `definition:` key — **all parameter names change completely**
- **Modern equivalent**: `kubernetes.core.k8s` with a full Route manifest under `definition:` (or `redhat.openshift.openshift_route` from `redhat.openshift` collection for OpenShift-specific Route objects)
- **Ansible module mapping**: `openshift_v1_route` → `redhat.openshift.openshift_route` or `kubernetes.core.k8s` with `definition:`

#### Task 2 — Create PVC
- **Legacy module**: `k8s_v1_persistent_volume_claim`
- **Parameters used**: `name`, `namespace`, `state`, `access_modes`, `resources_requests`
- **Parameter drift**: `resources_requests` is a flattened form of `spec.resources.requests`; modern `kubernetes.core.k8s` requires a full manifest `definition:` block with `spec.resources.requests.storage`
- **Modern equivalent**: `kubernetes.core.k8s` with inline `definition:` for a `PersistentVolumeClaim` manifest
- **Ansible module mapping**: `k8s_v1_persistent_volume_claim` → `kubernetes.core.k8s`

#### Task 3 — Create DeploymentConfig
- **Legacy module**: `openshift_v1_deployment_config`
- **Parameters used**: `name`, `namespace`, `labels`, `replicas`, `selector`, `spec_template_metadata_labels`, `containers` (with `env`, `image`, `name`, `ports`, `volume_mounts`), `volumes`
- **Parameter drift**: `spec_template_metadata_labels` is a flattened parameter; `containers` is passed as a list directly on the module rather than nested under `spec.template.spec`; this entire parameter structure is incompatible with `kubernetes.core.k8s`
- **Critical architectural note**: `openshift_v1_deployment_config` maps to OpenShift's `DeploymentConfig` resource (OpenShift-specific, deprecated in OpenShift 4.x). The modern equivalent is a standard Kubernetes `Deployment` resource, managed via `kubernetes.core.k8s`
- **Modern equivalent**: `kubernetes.core.k8s` with a full `apps/v1 Deployment` manifest under `definition:`
- **Ansible module mapping**: `openshift_v1_deployment_config` → `kubernetes.core.k8s` (with `Deployment` kind, not `DeploymentConfig`)

#### Task 4 — Create Service
- **Legacy module**: `k8s_v1_service`
- **Parameters used**: `name`, `namespace`, `labels`, `selector`, `ports`
- **Parameter drift**: `ports` list structure is similar to Kubernetes native but was generated by the old dynamic module; must be expressed as a full manifest `definition:` in `kubernetes.core.k8s`
- **Modern equivalent**: `kubernetes.core.k8s` with a full `v1 Service` manifest under `definition:`
- **Ansible module mapping**: `k8s_v1_service` → `kubernetes.core.k8s`

### 4. **Deprovision playbook** (`playbooks/deprovision.yml`)
- Uses `post_tasks:` directly in the play (no role for deprovision logic — all tasks are inline)
- **Legacy modules used** (all tombstoned):
  - `openshift_v1_route` → `kubernetes.core.k8s` with `state: absent`
  - `k8s_v1_persistent_volume_claim` → `kubernetes.core.k8s` with `state: absent`
  - `openshift_v1_deployment_config` (scale to 0) → `kubernetes.core.k8s` with `definition.spec.replicas: 0`
  - `k8s_v1_replication_controller` → `kubernetes.core.k8s` with `state: absent`
  - `openshift_v1_deployment_config` (delete) → `kubernetes.core.k8s` with `state: absent`
  - `k8s_v1_service` → `kubernetes.core.k8s` with `state: absent`
- **Structural issue**: `vars: namespace: mediawiki123-apb` hardcodes the namespace at the play level, overriding any passed-in value — this should be a variable with a proper default
- **Boolean issue**: `install_python_requirements: false` — this one is already `false` (correct), but the provision playbook uses `no`
- **Modern equivalent**: Refactor into a `deprovision-mediawiki123-apb` role with its own `tasks/main.yml`, using `kubernetes.core.k8s` with `state: absent` for each resource

### 5. **Test playbook** (`playbooks/test.yml`)
- **Legacy patterns**:
  - `include_vars: test_defaults.yaml` — bare `include_vars` without FQCN
  - `include_role: name: provision-mediawiki123-apb` — bare `include_role` without FQCN
  - `include_role: name: verify-mediawiki123-apb` — bare `include_role` without FQCN
  - `openshift_v1_project` — tombstoned module for creating an OpenShift Project
  - `install_python_requirements: no` — boolean string
- **Modern equivalent**:
  - `ansible.builtin.include_vars`
  - `ansible.builtin.include_role`
  - `kubernetes.core.k8s` with `kind: Namespace` (or `redhat.openshift.openshift_project` if targeting OpenShift)
  - `install_python_requirements: false`

### 6. **Verify role tasks** (`roles/verify-mediawiki123-apb/tasks/main.yaml`)
- **Task**: HTTP health check using `uri` module
- **Legacy pattern**: `uri:` without FQCN
- **Issue**: `route.route.spec.host` — this variable is registered from the `openshift_v1_route` task in the provision role; after migration to `kubernetes.core.k8s`, the registered variable structure changes. The route host will be at `route.result.spec.host` (or similar, depending on the `kubernetes.core.k8s` return structure)
- **`failed_when` usage**: Correct pattern, no change needed semantically
- **Modern equivalent**: `ansible.builtin.uri` with updated `route` variable path

### 7. **Test defaults** (`playbooks/vars/test_defaults.yaml`)
- Plain variable file, no legacy patterns
- Contains plaintext `mediawiki_admin_pass: admin` — **security concern**: should use `ansible-vault` or an external secrets manager in production

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `openshift_v1_route:` | `kubernetes.core.k8s:` with `definition:` (Route manifest) or `redhat.openshift.openshift_route:` | `roles/provision-mediawiki123-apb/tasks/main.yml`, `playbooks/deprovision.yml` | **Tombstoned module** — full parameter drift; all params must be rewritten as K8s manifest YAML |
| `k8s_v1_persistent_volume_claim:` | `kubernetes.core.k8s:` with `definition:` (PVC manifest) | `roles/provision-mediawiki123-apb/tasks/main.yml`, `playbooks/deprovision.yml` | **Tombstoned module** — `resources_requests` → `spec.resources.requests.storage` |
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with `definition:` (`apps/v1 Deployment`) | `roles/provision-mediawiki123-apb/tasks/main.yml`, `playbooks/deprovision.yml` | **Tombstoned + architectural change**: `DeploymentConfig` (OpenShift 3.x) → `Deployment` (K8s standard); all flattened params → nested manifest |
| `k8s_v1_service:` | `kubernetes.core.k8s:` with `definition:` (Service manifest) | `roles/provision-mediawiki123-apb/tasks/main.yml`, `playbooks/deprovision.yml` | **Tombstoned module** — full parameter drift |
| `k8s_v1_replication_controller:` | `kubernetes.core.k8s:` with `state: absent` | `playbooks/deprovision.yml` | **Tombstoned module**; with `Deployment` replacing `DeploymentConfig`, ReplicaSets replace ReplicationControllers — cleanup logic must be updated |
| `openshift_v1_project:` | `kubernetes.core.k8s:` with `kind: Namespace` or `redhat.openshift.openshift_project:` | `playbooks/test.yml` | **Tombstoned module** |
| `role: ansible.kubernetes-modules` | Remove entirely; add `kubernetes.core` to `collections/requirements.yml` | `playbooks/provision.yml`, `playbooks/deprovision.yml`, `playbooks/test.yml` | The entire `ansible.kubernetes-modules` role is deprecated/tombstoned; Python deps handled via EE or `ansible.builtin.pip` |
| `install_python_requirements: no` | `install_python_requirements: false` | `playbooks/provision.yml`, `playbooks/test.yml` | Boolean string `no` → `false` |
| `install_python_requirements: false` | Already correct | `playbooks/deprovision.yml` | No change needed |
| `include_vars: test_defaults.yaml` | `ansible.builtin.include_vars: file: test_defaults.yaml` | `playbooks/test.yml` | FQCN + explicit `file:` parameter |
| `include_role: name: ...` | `ansible.builtin.include_role: name: ...` | `playbooks/test.yml` | FQCN |
| `uri:` | `ansible.builtin.uri:` | `roles/verify-mediawiki123-apb/tasks/main.yaml` | FQCN |
| `route.route.spec.host` | `route.result.spec.host` (or `route.result.status.ingress[0].host`) | `roles/verify-mediawiki123-apb/tasks/main.yaml` | Registered variable structure changes when migrating from `openshift_v1_route` to `kubernetes.core.k8s` |
| APB packaging (`apb.yml`, `Dockerfile-*`, `mediawiki-apb-role.spec`) | Standard Ansible role + `meta/main.yml` + `meta/argument_specs.yml` + `execution-environment.yml` | `apb.yml`, all Dockerfiles, `.spec` file | APB/Service Catalog is deprecated; replace with standard role distribution via Ansible Galaxy or Automation Hub |
| Hardcoded `namespace: mediawiki123-apb` in deprovision play `vars:` | Variable with default in `defaults/main.yml` | `playbooks/deprovision.yml` | Namespace should not be hardcoded |
| `spec_port_target_port: web` (flattened param) | `definition.spec.ports[0].targetPort: web` | `roles/provision-mediawiki123-apb/tasks/main.yml` | Parameter drift from old dynamic module generator |
| `to_name: mediawiki123` (flattened param) | `definition.spec.to.name: mediawiki123` | `roles/provision-mediawiki123-apb/tasks/main.yml` | Parameter drift |
| `resources_requests: storage: ...` (flattened param) | `definition.spec.resources.requests.storage: ...` | `roles/provision-mediawiki123-apb/tasks/main.yml` | Parameter drift |
| `spec_template_metadata_labels:` (flattened param) | `definition.spec.template.metadata.labels:` | `roles/provision-mediawiki123-apb/tasks/main.yml` | Parameter drift |
| `containers:` at module top level | `definition.spec.template.spec.containers:` | `roles/provision-mediawiki123-apb/tasks/main.yml` | Parameter drift — containers must be nested under the manifest spec |
| `volumes:` at module top level | `definition.spec.template.spec.volumes:` | `roles/provision-mediawiki123-apb/tasks/main.yml` | Parameter drift |
| `post_tasks:` for all deprovision logic | Dedicated `deprovision-mediawiki123-apb` role | `playbooks/deprovision.yml` | Structural: inline tasks → role for reusability and testability |
| `gather_facts: false` | `gather_facts: false` | All playbooks | Already correct; no change needed |
| `connection: local` | `connection: local` | All playbooks | Already correct; acceptable for K8s API interactions |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):

```yaml
collections:
  - name: kubernetes.core
    version: ">=3.0.0"
  - name: redhat.openshift
    version: ">=2.3.0"   # Only if targeting OpenShift; provides openshift_route, openshift_project
  - name: ansible.builtin
    # Ships with ansible-core, no explicit requirement needed
```

**Python package dependencies** (for `bindep.txt` / EE `requirements.txt`):
```
kubernetes>=24.2.0
openshift>=0.13.2   # If using redhat.openshift collection
PyYAML>=5.4.1
```

**Role dependencies**: 
- `ansible.kubernetes-modules` — **REMOVE**: this role is tombstoned and must be eliminated entirely

**External container images referenced**:
- `docker.io/dymurray/mediawiki123:latest` (provision role — primary image)
- `docker.io/jmontleon/mediawiki123:latest` (referenced in `apb.yml` metadata `dependencies` — inconsistency with tasks; should be reconciled to a single canonical image)
- `ansibleplaybookbundle/apb-base:latest` / `:nightly` (Dockerfile base — **deprecated APB base image**, remove in migration)

**Services managed**:
- MediaWiki application pod (via Kubernetes Deployment, port 8080)
- Kubernetes Service `mediawiki123` (ClusterIP, port 8080)
- PersistentVolumeClaim `mediawiki123-pvc` (1Gi, ReadWriteOnce, mounted at `/persistent`)
- OpenShift Route `mediawiki123` (HTTP, targeting port `web`/8080) — or Kubernetes Ingress if migrating away from OpenShift

---

## Template Modernization

There are **no Jinja2 `.j2` template files** in this role. All Kubernetes resource definitions are expressed inline as module parameters (the old flattened-parameter style). 

**Migration recommendation**: When rewriting tasks to use `kubernetes.core.k8s` with `definition:` blocks, consider extracting the manifest YAML into separate template files (e.g., `templates/deployment.yml.j2`, `templates/service.yml.j2`, `templates/pvc.yml.j2`, `templates/route.yml.j2`) for maintainability. These templates would use standard Jinja2 variable interpolation:

- **`templates/deployment.yml.j2`** (new file): Inline `{{ mediawiki_db_schema }}`, `{{ mediawiki_site_name }}`, `{{ mediawiki_site_lang }}`, `{{ mediawiki_admin_user }}`, `{{ mediawiki_admin_pass }}`, `{{ route_host }}` — all variables are already properly quoted in the source; ensure they remain quoted strings in the template
- **`templates/pvc.yml.j2`** (new file): `{{ mediawiki_volume_size }}` — already a quoted string, no change needed
- **`templates/route.yml.j2`** (new file): `{{ namespace }}` — already quoted
- **`templates/service.yml.j2`** (new file): Static manifest, no variable interpolation needed

---

## Argument Specification

The following variables should be documented in `meta/argument_specs.yml` for the modernized `provision-mediawiki123-apb` role:

| Variable | Type | Required | Default | Source | Description |
|---|---|---|---|---|---|
| `namespace` | `str` | No | `lookup('env','NAMESPACE') \| default('mediawiki123', true)` | `defaults/main.yml` | Kubernetes namespace to deploy into |
| `mediawiki_volume_size` | `str` | No | `"1Gi"` | `defaults/main.yml` | PVC storage size (Kubernetes quantity format) |
| `mediawiki_db_schema` | `str` | Yes | `"mediawiki"` | `apb.yml` plan params | MediaWiki database schema name |
| `mediawiki_site_name` | `str` | Yes | `"MediaWiki"` | `apb.yml` plan params | MediaWiki site display name |
| `mediawiki_site_lang` | `str` | Yes | `"en"` | `apb.yml` plan params | MediaWiki site language code |
| `mediawiki_admin_user` | `str` | Yes | `"admin"` | `apb.yml` plan params | MediaWiki administrator username |
| `mediawiki_admin_pass` | `str` | Yes | _(none)_ | `apb.yml` plan params | MediaWiki administrator password — **mark as `no_log: true`** |

**Proposed `meta/argument_specs.yml`**:
```yaml
argument_specs:
  main:
    short_description: Provision a MediaWiki 1.23 instance on Kubernetes/OpenShift
    description:
      - Deploys a MediaWiki 1.23 application using a Kubernetes Deployment,
        Service, PersistentVolumeClaim, and Route/Ingress.
    options:
      namespace:
        type: str
        required: false
        default: "mediawiki123"
        description: Kubernetes namespace to deploy MediaWiki into.
      mediawiki_volume_size:
        type: str
        required: false
        default: "1Gi"
        description: Storage size for the MediaWiki persistent volume claim.
      mediawiki_db_schema:
        type: str
        required: true
        description: MediaWiki database schema name.
      mediawiki_site_name:
        type: str
        required: true
        description: Display name for the MediaWiki site.
      mediawiki_site_lang:
        type: str
        required: true
        description: Language code for the MediaWiki site (e.g., 'en').
      mediawiki_admin_user:
        type: str
        required: true
        description: Username for the MediaWiki administrator account.
      mediawiki_admin_pass:
        type: str
        required: true
        no_log: true
        description: Password for the MediaWiki administrator account.
```

---

## Execution Environment Metadata

Since this role targets Kubernetes/OpenShift APIs, an Execution Environment definition is required:

**`execution-environment.yml`** (new file):
```yaml
version: 3
dependencies:
  galaxy:
    collections:
      - name: kubernetes.core
        version: ">=3.0.0"
      - name: redhat.openshift
        version: ">=2.3.0"
  python:
    - kubernetes>=24.2.0
    - openshift>=0.13.2
  system: bindep.txt
images:
  base_image:
    name: registry.redhat.io/ansible-automation-platform/ee-minimal-rhel8:latest
```

**`bindep.txt`** (new file):
```
python3-devel [platform:rpm]
gcc [platform:rpm]
```

---

## Checks for the Migration

**Files to verify** (complete list of files in the modernized role):
```
playbooks/provision.yml
playbooks/deprovision.yml
playbooks/test.yml
playbooks/vars/test_defaults.yaml
roles/provision-mediawiki123-apb/tasks/main.yml
roles/provision-mediawiki123-apb/defaults/main.yml
roles/provision-mediawiki123-apb/meta/main.yml          ← new
roles/provision-mediawiki123-apb/meta/argument_specs.yml ← new
roles/deprovision-mediawiki123-apb/tasks/main.yml       ← new (refactored from post_tasks)
roles/deprovision-mediawiki123-apb/defaults/main.yml    ← new
roles/verify-mediawiki123-apb/tasks/main.yaml
collections/requirements.yml                            ← new
execution-environment.yml                               ← new
bindep.txt                                              ← new
```
> **Remove**: `apb.yml`, `Dockerfile-latest`, `Dockerfile-nightly`, `Dockerfile-canary`, `mediawiki-apb-role.spec` — all APB-specific artifacts with no equivalent in a standard Ansible role distribution

**Services to check**:
- Kubernetes `Deployment` `mediawiki123` in target namespace — verify `AVAILABLE` replicas = 1
- Kubernetes `Service` `mediawiki123` in target namespace — verify `ClusterIP` assigned and port 8080 mapped
- Kubernetes `PersistentVolumeClaim` `mediawiki123-pvc` in target namespace — verify `STATUS = Bound`
- OpenShift `Route` `mediawiki123` (or Kubernetes `Ingress`) — verify host is assigned and reachable

**Templates to validate**:
- No existing `.j2` files to validate
- New template files (if created): `templates/deployment.yml.j2`, `templates/pvc.yml.j2`, `templates/route.yml.j2`, `templates/service.yml.j2` — validate with `ansible-lint` and `kubectl apply --dry-run=client`

---

## Pre-flight Checks

```bash
# 1. Verify kubernetes.core collection is installed
ansible-galaxy collection list | grep kubernetes.core

# 2. Verify redhat.openshift collection is installed (if targeting OpenShift)
ansible-galaxy collection list | grep redhat.openshift

# 3. Verify Python kubernetes client is available
python3 -c "import kubernetes; print(kubernetes.__version__)"

# 4. Verify cluster connectivity
kubectl cluster-info
# or for OpenShift:
oc whoami && oc status

# 5. Verify target namespace exists (or will be created)
kubectl get namespace mediawiki123 || echo "Namespace will be created by role"

# 6. Verify StorageClass supports ReadWriteOnce PVCs
kubectl get storageclass

# 7. Dry-run the provision playbook
ansible-playbook playbooks/provision.yml --check -e "namespace=mediawiki123-test"

# 8. After provisioning: verify Deployment rollout
kubectl rollout status deployment/mediawiki123 -n mediawiki123

# 9. After provisioning: verify PVC is bound
kubectl get pvc mediawiki123-pvc -n mediawiki123

# 10. After provisioning: verify Route/Ingress host is assigned
kubectl get route mediawiki123 -n mediawiki123 -o jsonpath='{.spec.host}'
# or for Ingress:
kubectl get ingress mediawiki123 -n mediawiki123 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 11. HTTP health check (mirrors verify role)
ROUTE_HOST=$(kubectl get route mediawiki123 -n mediawiki123 -o jsonpath='{.spec.host}')
curl -o /dev/null -s -w "%{http_code}" http://${ROUTE_HOST}
# Expected: 200

# 12. Lint the modernized role
ansible-lint roles/provision-mediawiki123-apb/
ansible-lint roles/deprovision-mediawiki123-apb/

# 13. Validate argument specs
ansible-playbook --syntax-check playbooks/provision.yml
```

---

## Critical Migration Notes

1. **APB is fully deprecated**: The Ansible Playbook Bundle format, OpenShift Service Catalog, and `ansibleplaybookbundle/apb-base` images were deprecated with OpenShift 4.x. The entire APB packaging layer (`apb.yml`, Dockerfiles, `.spec` RPM) must be discarded. The role logic is preserved; only the delivery mechanism changes.

2. **`ansible.kubernetes-modules` role is tombstoned**: This role was the APB-era mechanism for shipping OpenShift Python client libraries and dynamic modules. It has no modern equivalent. Replace with `kubernetes.core` collection installed via `collections/requirements.yml` and the `kubernetes` Python package installed in the Execution Environment.

3. **`DeploymentConfig` → `Deployment` architectural change**: OpenShift `DeploymentConfig` is deprecated in OpenShift 4.14+ and removed in 4.15+. The migration must use a standard Kubernetes `apps/v1 Deployment`. The deprovision logic that deletes `k8s_v1_replication_controller` (which was created by `DeploymentConfig` rollouts) must be updated — `Deployment` creates `ReplicaSet` objects instead, which are garbage-collected automatically when the `Deployment` is deleted.

4. **Image inconsistency**: `apb.yml` references `docker.io/jmontleon/mediawiki123:latest` in metadata but `roles/provision-mediawiki123-apb/tasks/main.yml` uses `docker.io/dymurray/mediawiki123:latest`. Reconcile to a single canonical, maintained image before migration.

5. **Registered variable path change**: The `route` variable registered from `openshift_v1_route` exposes `route.route.spec.host`. After migrating to `kubernetes.core.k8s`, the registered result is at `route.result.spec.host` (for OpenShift Route) or `route.result.status.ingress[0].host` (for Kubernetes Ingress). The verify role's `uri` task URL must be updated accordingly.

6. **Plaintext password in test vars**: `playbooks/vars/test_defaults.yaml` contains `mediawiki_admin_pass: admin`. For any non-ephemeral environment, this must be replaced with an Ansible Vault-encrypted value or an external secrets lookup.