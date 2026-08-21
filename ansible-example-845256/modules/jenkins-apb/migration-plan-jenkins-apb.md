---
source-path: jenkins-apb
---

Now I have all the information needed to write a comprehensive migration plan. Let me compile the full analysis.

---

# Migration Plan: jenkins-apb

**TLDR**: `jenkins-apb` is an Ansible Playbook Bundle (APB) that provisions and deprovisions a Jenkins CI/CD server on OpenShift, supporting both ephemeral and persistent storage, optional S2I (source-to-image) customization, and OpenShift OAuth integration. The role is built on the now-defunct APB framework and relies entirely on tombstoned `openshift_v1_*` and `k8s_v1_*` modules from the legacy `ansible.kubernetes-modules` role. The entire module layer must be replaced with `kubernetes.core.k8s`, raw `command:` workarounds must be replaced with proper `kubernetes.core.k8s` manifests, `ignore_errors` anti-patterns must be replaced with `block/rescue`, boolean defaults must be normalized, and the APB container packaging must be replaced with a standard Ansible Collection + Execution Environment structure.

---

## Service Type and Configuration

**Service Type**: CI/CD Platform Provisioner (Kubernetes/OpenShift Operator-style role)

**Key Operations**:
- Provision a Jenkins `Service` (port 80 → 8080) with OpenShift infrastructure annotations
- Provision a Jenkins JNLP agent `Service` (port 50000)
- Provision an OpenShift `Route` with TLS edge termination and redirect
- Conditionally provision a `PersistentVolumeClaim` (when `persistent: true`)
- Provision a `ServiceAccount` with OpenShift OAuth redirect annotations
- Provision a `RoleBinding` granting `edit` to the Jenkins ServiceAccount (via `oc create -f` workaround)
- Conditionally provision an `ImageStream` and `BuildConfig` for S2I Jenkins customization (when `source_git_uri`, `source_git_ref`, and `source_context_dir` are defined)
- Provision a `DeploymentConfig` (ephemeral or persistent volume mount, ImageStream trigger)
- Deprovision all of the above resources in reverse order (state: absent)

---

## File Structure

**Task Files:**
```
roles/provision-jenkins-apb/tasks/main.yml
roles/deprovision-jenkins-apb/tasks/main.yml
```

**Variable Files:**
```
roles/provision-jenkins-apb/defaults/main.yml
roles/provision-jenkins-apb/vars/main.yml
roles/deprovision-jenkins-apb/defaults/main.yml
```

**Templates:**
```
roles/provision-jenkins-apb/templates/dc.yaml.j2
roles/provision-jenkins-apb/templates/buildconfig.yaml.j2
roles/provision-jenkins-apb/templates/rolebinding.yaml.j2
```

**Playbooks:**
```
playbooks/provision.yml
playbooks/deprovision.yml
```

**APB Metadata:**
```
apb.yml
```

**Container / Build:**
```
Dockerfile
Makefile
```

---

## Module Explanation

The role performs operations in this order:

### 1. **Provision Playbook** (`playbooks/provision.yml`)
- Loads the legacy `ansible.kubernetes-modules` role first to install Python Kubernetes client libraries and register all `k8s_v1_*` / `openshift_v1_*` modules.
- Then delegates to `provision-jenkins-apb` role.
- **Legacy pattern**: Dependency on `ansible.kubernetes-modules` role — this entire role is tombstoned and must be removed. The `kubernetes.core` collection ships its own Python dependency management.
- **Modern equivalent**: Remove the `ansible.kubernetes-modules` role dependency entirely; declare `kubernetes.core` in `collections/requirements.yml`.

### 2. **Create Jenkins Service** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Uses `k8s_v1_service:` with flattened dot-notation parameters (`spec_ports`, `spec_selector`, `spec_session_affinity`, `spec_type`).
- **Legacy pattern**: `k8s_v1_service` is a tombstoned module from `ansible.kubernetes-modules`. Its parameter schema uses underscored flattening (`spec_ports`, `spec_selector`) rather than nested YAML dicts.
- **Modern equivalent**: `kubernetes.core.k8s:` with a full inline `resource_definition:` block using standard Kubernetes YAML structure. The `state:` parameter maps directly.
- **Parameter drift**: All `spec_*` flat parameters must be rewritten as nested `resource_definition.spec.*` YAML keys.

### 3. **Create JNLP Service** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Same `k8s_v1_service:` tombstoned module pattern as above.
- **Modern equivalent**: `kubernetes.core.k8s:` with inline `resource_definition:`.

### 4. **Create Route** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Uses `openshift_v1_route:` with flattened parameters (`spec_tls_insecure_edge_termination_policy`, `spec_tls_termination`, `spec_to_kind`, `spec_to_name`).
- **Legacy pattern**: `openshift_v1_route` is a tombstoned OpenShift-specific module. OpenShift Routes are a CRD and can be managed via `kubernetes.core.k8s`.
- **Modern equivalent**: `kubernetes.core.k8s:` with `apiVersion: route.openshift.io/v1`, `kind: Route`, and a full `resource_definition:` block.
- **Parameter drift**: `spec_tls_*` and `spec_to_*` flat params → nested `spec.tls.*` and `spec.to.*` YAML keys.

### 5. **Create PersistentVolumeClaim** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Uses `k8s_v1_persistent_volume_claim:` with `spec_access_modes` and `spec_resources_requests`.
- Conditional: `when: persistent` — bare variable, needs `| bool` filter.
- **Legacy pattern**: Tombstoned module + bare boolean variable.
- **Modern equivalent**: `kubernetes.core.k8s:` with inline `resource_definition:` + `when: persistent | bool`.

### 6. **Create ServiceAccount** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Uses `k8s_v1_service_account:` with `annotations:` containing a JSON-serialized OAuth redirect reference.
- Has `ignore_errors: True` as a workaround for a known SDK bug (`'V1ServiceAccount' object has no attribute 'status'`).
- **Legacy patterns**:
  - Tombstoned `k8s_v1_service_account` module.
  - `ignore_errors: True` anti-pattern masking a known bug.
  - Boolean `True` (Python-style) instead of `true`.
- **Modern equivalent**: `kubernetes.core.k8s:` with inline `resource_definition:`. The SDK bug is fixed in `kubernetes.core`; `ignore_errors` should be removed. If idempotency is still a concern (resource already exists), wrap in a `block/rescue` that catches only `kubernetes.core.k8s` conflict errors, or use `state: present` which is naturally idempotent.

### 7. **Create RoleBinding via Template + `oc create`** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Two-step workaround: first renders `rolebinding.yaml.j2` to `/tmp/rolebinding.yaml` using `template:`, then runs `oc create -f /tmp/rolebinding.yaml -n {{ namespace }}` via `command:`.
- Has `ignore_errors: True` because `oc create` fails if the resource already exists.
- **Legacy patterns**:
  - `template:` used purely to write a manifest to disk for shell consumption — not for configuration management.
  - `command:` with `oc` CLI — not idempotent, not declarative.
  - `ignore_errors: True` masking non-idempotent `oc create`.
  - `register: rolebinding` + `rolebinding.dest | default(rolebinding.path)` — fragile path resolution.
- **Modern equivalent**: Replace the entire two-step pattern with a single `kubernetes.core.k8s:` task using an inline `resource_definition:` for the RoleBinding. The `rolebinding.yaml.j2` template file becomes unnecessary. `state: present` is idempotent by default.

### 8. **Create ImageStream (conditional)** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Uses `openshift_v1_image_stream:` — tombstoned OpenShift module.
- Conditional: `when: source_git_uri is defined and source_git_ref is defined and source_context_dir is defined`.
- **Modern equivalent**: `kubernetes.core.k8s:` with `apiVersion: image.openshift.io/v1`, `kind: ImageStream`.

### 9. **Create BuildConfig via Template + `oc create` (conditional)** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Same two-step `template:` + `command: oc create` workaround as RoleBinding.
- `ignore_errors: True` on the `oc create` step.
- **Legacy patterns**: Same as RoleBinding workaround above.
- **Modern equivalent**: `kubernetes.core.k8s:` with `template:` parameter pointing to `buildconfig.yaml.j2` (the `kubernetes.core.k8s` module natively supports Jinja2 template files via its `template:` parameter), or inline `resource_definition:` with variables. The `command:` task and `ignore_errors` are eliminated.

### 10. **Create DeploymentConfig via Template** (`roles/provision-jenkins-apb/tasks/main.yml`)
- Two-step: `template:` renders `dc.yaml.j2` to `/tmp/dc.yaml`, then `openshift_v1_deployment_config:` reads it via `src:`.
- **Legacy patterns**:
  - Tombstoned `openshift_v1_deployment_config` module.
  - Indirect `src:` file loading pattern.
  - `DeploymentConfig` is an OpenShift-specific resource (deprecated in OpenShift 4.14+, removed in 4.17+).
- **Modern equivalent**: Replace `DeploymentConfig` with a standard Kubernetes `Deployment` (`apps/v1`). Use `kubernetes.core.k8s:` with `template: dc.yaml.j2` (native template support) or inline `resource_definition:`. Update `dc.yaml.j2` to use `apiVersion: apps/v1`, `kind: Deployment`, and replace `triggers:` with an `initContainer` or image reference strategy appropriate for modern OpenShift/Kubernetes.

### 11. **Deprovision Tasks** (`roles/deprovision-jenkins-apb/tasks/main.yml`)
- Mirrors all provision tasks with `state: absent`.
- Uses the same tombstoned modules: `k8s_v1_service`, `openshift_v1_route`, `k8s_v1_persistent_volume_claim`, `k8s_v1_service_account`, `openshift_v1_image_stream`, `openshift_v1_build_config`, `openshift_v1_deployment_config`.
- `command: oc delete rolebinding {{ jenkins_service_name }}_edit` with `ignore_errors: True`.
- **Modern equivalent**: All replaced with `kubernetes.core.k8s:` using `state: absent`. The `oc delete` command replaced with a `kubernetes.core.k8s:` task for the RoleBinding.

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `k8s_v1_service:` | `kubernetes.core.k8s:` with `resource_definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Tombstoned module; full parameter schema rewrite required — flat `spec_*` params → nested YAML |
| `k8s_v1_persistent_volume_claim:` | `kubernetes.core.k8s:` with `resource_definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Tombstoned module; `spec_access_modes` / `spec_resources_requests` → nested `spec.accessModes` / `spec.resources.requests` |
| `k8s_v1_service_account:` | `kubernetes.core.k8s:` with `resource_definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Tombstoned module; SDK bug that required `ignore_errors` is fixed in `kubernetes.core` |
| `openshift_v1_route:` | `kubernetes.core.k8s:` with `apiVersion: route.openshift.io/v1` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Tombstoned OpenShift module; flat `spec_tls_*` / `spec_to_*` → nested `spec.tls.*` / `spec.to.*` |
| `openshift_v1_image_stream:` | `kubernetes.core.k8s:` with `apiVersion: image.openshift.io/v1` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Tombstoned OpenShift module |
| `openshift_v1_build_config:` | `kubernetes.core.k8s:` with `apiVersion: build.openshift.io/v1` | `roles/deprovision-jenkins-apb/tasks/main.yml` | Tombstoned OpenShift module |
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with `apiVersion: apps/v1`, `kind: Deployment` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Tombstoned module; `DeploymentConfig` deprecated in OCP 4.14, removed in 4.17 — migrate to `Deployment` |
| `template:` + `command: oc create -f` | `kubernetes.core.k8s:` with `template:` or `resource_definition:` | `roles/provision-jenkins-apb/tasks/main.yml` | Non-idempotent CLI workaround; `kubernetes.core.k8s` natively supports Jinja2 templates via `template:` parameter |
| `command: oc delete rolebinding` | `kubernetes.core.k8s:` with `state: absent` | `roles/deprovision-jenkins-apb/tasks/main.yml` | Non-idempotent CLI workaround |
| `ignore_errors: True` (ServiceAccount) | Remove; use `block/rescue` if truly needed | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | SDK bug fixed in `kubernetes.core`; `state: present` is idempotent |
| `ignore_errors: True` (RoleBinding `oc create`) | Remove; `kubernetes.core.k8s` `state: present` is idempotent | `roles/provision-jenkins-apb/tasks/main.yml` | Non-idempotent `oc create` replaced by idempotent `kubernetes.core.k8s` |
| `ignore_errors: True` (BuildConfig `oc create`) | Remove; `kubernetes.core.k8s` `state: present` is idempotent | `roles/provision-jenkins-apb/tasks/main.yml` | Same as above |
| `ignore_errors: True` (deprovision `oc delete`) | Remove; `kubernetes.core.k8s` `state: absent` is idempotent | `roles/deprovision-jenkins-apb/tasks/main.yml` | `state: absent` does not fail if resource is missing |
| `template:` writing to `/tmp/*.yaml` for `src:` consumption | `kubernetes.core.k8s:` with `template:` parameter | `roles/provision-jenkins-apb/tasks/main.yml` | Eliminates temp file side-effects and fragile `dest \| default(path)` logic |
| `register: rolebinding` + `rolebinding.dest \| default(rolebinding.path)` | Eliminated entirely | `roles/provision-jenkins-apb/tasks/main.yml` | Fragile path resolution no longer needed |
| `when: persistent` (bare variable) | `when: persistent \| bool` | `roles/provision-jenkins-apb/tasks/main.yml` | Jinja2 bare boolean variable — add `\| bool` filter for type safety |
| `when: source_git_uri is defined and ...` | Keep as-is (valid modern syntax) | `roles/provision-jenkins-apb/tasks/main.yml` | No change needed; already correct |
| `persistent: False` (Python-style bool) | `persistent: false` | `roles/provision-jenkins-apb/defaults/main.yml`, `roles/deprovision-jenkins-apb/defaults/main.yml` | YAML boolean normalization |
| `enable_oauth: True` (Python-style bool) | `enable_oauth: true` | `roles/provision-jenkins-apb/defaults/main.yml` | YAML boolean normalization |
| `install_python_requirements: no` | `install_python_requirements: false` | `playbooks/provision.yml` | YAML boolean normalization |
| `playbook_debug: True` / `playbook_debug: false` | `playbook_debug: true` / `playbook_debug: false` | `playbooks/provision.yml`, `playbooks/deprovision.yml` | YAML boolean normalization (mixed case inconsistency) |
| `role: ansible.kubernetes-modules` dependency | Remove entirely | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Tombstoned role; replaced by `kubernetes.core` collection |
| `k8s_v1_service:` (no FQCN) | `kubernetes.core.k8s:` (FQCN) | All task files | All module references need FQCN |
| `template:` (no FQCN) | `ansible.builtin.template:` | `roles/provision-jenkins-apb/tasks/main.yml` | FQCN for builtin modules |
| `command:` (no FQCN) | Remove entirely (replaced by `kubernetes.core.k8s`) | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | `command:` tasks also lack `changed_when:` — idempotency issue |
| `command:` missing `changed_when:` | Remove (or add `changed_when: false` if kept) | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | All `command:` tasks are flagged as always-changed |
| APB `apb.yml` metadata format | `meta/argument_specs.yml` + `meta/main.yml` | `apb.yml` | APB framework is EOL; parameters migrate to role argument specs |
| `Dockerfile` (APB base image) | `execution-environment.yml` + `bindep.txt` | `Dockerfile` | APB container model → Ansible Execution Environment |
| `DeploymentConfig` kind in `dc.yaml.j2` | `Deployment` (`apps/v1`) in updated template | `roles/provision-jenkins-apb/templates/dc.yaml.j2` | `DeploymentConfig` is OpenShift-specific and deprecated |
| `triggers:` in `dc.yaml.j2` | Remove or replace with `image:` field in `Deployment` spec | `roles/provision-jenkins-apb/templates/dc.yaml.j2` | `triggers` is a `DeploymentConfig`-only feature |
| `{{ enable_oauth }}` bare in `dc.yaml.j2` | `{{ enable_oauth \| string \| lower }}` or `"{{ enable_oauth }}"` | `roles/provision-jenkins-apb/templates/dc.yaml.j2` | Bare boolean in template env var value — must be string for container env |
| `{% if persistent %}` in `dc.yaml.j2` | Keep (valid Jinja2 conditional) | `roles/provision-jenkins-apb/templates/dc.yaml.j2` | No change needed |
| `{{ jenkins_service_name }}` unquoted in `rolebinding.yaml.j2` subjects | `"{{ jenkins_service_name }}"` (quoted) | `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2` | Bare variable in YAML value — should be quoted |
| `gather_facts: false` | `gather_facts: false` | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Already lowercase; no change needed |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: ansible.builtin
    # ships with ansible-core, no explicit version needed
```

**Role dependencies**:
- `ansible.kubernetes-modules` — **REMOVE**. This role is tombstoned and was the sole provider of all `k8s_v1_*` and `openshift_v1_*` modules. Its removal is the central migration action.

**External packages** (for `bindep.txt` in Execution Environment):
```
python3-openshift [platform:rpm]
python3-kubernetes [platform:rpm]
# or via pip:
# openshift>=0.13.1
# kubernetes>=12.0.0
```

**Services managed**:
- Jenkins CI/CD server (OpenShift `DeploymentConfig` → modern `Deployment`)
- Jenkins JNLP agent listener
- OpenShift Route (TLS edge-terminated ingress)
- Optional: PersistentVolumeClaim for Jenkins home directory
- Optional: ImageStream + BuildConfig for S2I Jenkins customization

---

## Template Modernization

### `roles/provision-jenkins-apb/templates/dc.yaml.j2`
- **`kind: DeploymentConfig`** → Change to `kind: Deployment`, `apiVersion: apps/v1`. Add `selector.matchLabels:` under `spec:`. Move `template:` under `spec:`.
- **`triggers:` block** → Remove entirely. `DeploymentConfig` triggers are not supported in `Deployment`. Replace with a direct `image:` reference in the container spec (e.g., `image: image-registry.openshift-image-registry.svc:5000/{{ namespace }}/{{ jenkins_service_name }}:latest` when S2I is used, or the full ImageStreamTag reference via an `initContainer` or external image resolution).
- **`value: "{{ enable_oauth }}"`** → Change to `value: "{{ enable_oauth | string | lower }}"` to ensure the boolean is rendered as the string `"true"` or `"false"` (not Python `True`/`False`) in the container environment variable.
- **`{% if source_git_uri is defined %}`** → Valid; no change needed.
- **`{% if persistent %}`** → Add `| bool` filter for safety: `{% if persistent | bool %}`.
- **`capabilities: {}`** → This is a deprecated/no-op field in modern Kubernetes pod specs; consider removing.
- **`image: ' '`** → This is an OpenShift-specific placeholder used with `ImageChange` triggers. With a standard `Deployment`, replace with the actual image reference.

### `roles/provision-jenkins-apb/templates/buildconfig.yaml.j2`
- **`apiVersion: v1`** → Change to `apiVersion: build.openshift.io/v1` (correct API group for BuildConfig in modern OpenShift).
- **`{{ source_context_dir }}`**, **`{{ source_git_uri }}`**, **`{{ source_git_ref }}`** → These are already quoted in YAML string context; no bare variable issues.
- No other modernization needed; BuildConfig is still valid on OpenShift 4.x.

### `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2`
- **`apiVersion: v1`** → Change to `apiVersion: rbac.authorization.k8s.io/v1` (correct API group for RoleBinding).
- **`roleRef:`** → Add required `apiGroup: rbac.authorization.k8s.io` field (mandatory in `rbac.authorization.k8s.io/v1`).
- **`subjects[0]:`** → Add required `namespace: "{{ namespace }}"` field and `apiGroup: ""` field for ServiceAccount subjects.
- **`name: {{ jenkins_service_name }}`** (unquoted bare variable) → Change to `name: "{{ jenkins_service_name }}"`.
- **Note**: This template becomes unnecessary if the RoleBinding is managed inline via `kubernetes.core.k8s:` with `resource_definition:` — which is the recommended approach.

---

## Argument Specification

The following variables from `apb.yml` and `defaults/main.yml` should be documented in `roles/provision-jenkins-apb/meta/argument_specs.yml`:

| Variable | Type | Default | Required | Description |
|---|---|---|---|---|
| `namespace` | `str` | — | **yes** | Target OpenShift/Kubernetes namespace for all resources |
| `persistent` | `bool` | `false` | no | Whether to provision a PersistentVolumeClaim for Jenkins data |
| `enable_oauth` | `bool` | `true` | no | Enable OpenShift OAuth login integration for Jenkins |
| `memory_limit` | `str` | `"512Mi"` | no | Kubernetes memory limit for the Jenkins container |
| `volume_capacity` | `str` | `"1Gi"` | no | Storage size for the PersistentVolumeClaim (only used when `persistent: true`) |
| `jenkins_service_name` | `str` | `"jenkins"` | no | Name for the Jenkins Service, ServiceAccount, Route, and DeploymentConfig/Deployment |
| `jnlp_service_name` | `str` | `"jenkins-jnlp"` | no | Name for the Jenkins JNLP agent Service |
| `jenkins_image_stream_tag` | `str` | `"jenkins:latest"` | no | ImageStreamTag reference for the Jenkins image |
| `source_git_uri` | `str` | — | no | Git repository URI for S2I Jenkins customization (all three `source_*` vars required together) |
| `source_git_ref` | `str` | — | no | Git branch/ref for S2I Jenkins customization |
| `source_context_dir` | `str` | — | no | Context directory within the Git repo for S2I build |
| `state` | `str` | `"present"` | no | Kubernetes resource state: `present` or `absent` |

**`meta/argument_specs.yml` example structure**:
```yaml
argument_specs:
  main:
    short_description: Provision Jenkins on OpenShift
    description: >
      Deploys a Jenkins CI/CD server on OpenShift with optional persistent
      storage, OAuth integration, and S2I build customization.
    options:
      namespace:
        type: str
        required: true
        description: Target OpenShift namespace
      persistent:
        type: bool
        required: false
        default: false
        description: Enable persistent storage via PVC
      # ... (all variables above)
```

---

## New Files to Create

The following files do not exist in the legacy role and must be created as part of modernization:

```
collections/requirements.yml
roles/provision-jenkins-apb/meta/main.yml
roles/provision-jenkins-apb/meta/argument_specs.yml
roles/deprovision-jenkins-apb/meta/main.yml
execution-environment.yml
bindep.txt
```

**`collections/requirements.yml`**:
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
```

**`execution-environment.yml`** (replaces `Dockerfile`):
```yaml
version: 1
build_arg_defaults:
  EE_BASE_IMAGE: 'registry.redhat.io/ansible-automation-platform/ee-minimal-rhel8:latest'
dependencies:
  galaxy: collections/requirements.yml
  python: requirements.txt
  system: bindep.txt
```

**`bindep.txt`**:
```
python3-devel [platform:rpm]
```

**`requirements.txt`** (Python deps for `kubernetes.core`):
```
kubernetes>=12.0.0
openshift>=0.13.1
```

---

## Checks for the Migration

**Files to verify** (all created/modified files in the modern role):
```
playbooks/provision.yml
playbooks/deprovision.yml
roles/provision-jenkins-apb/tasks/main.yml
roles/provision-jenkins-apb/defaults/main.yml
roles/provision-jenkins-apb/vars/main.yml
roles/provision-jenkins-apb/meta/main.yml
roles/provision-jenkins-apb/meta/argument_specs.yml
roles/provision-jenkins-apb/templates/dc.yaml.j2
roles/provision-jenkins-apb/templates/buildconfig.yaml.j2
roles/provision-jenkins-apb/templates/rolebinding.yaml.j2
roles/deprovision-jenkins-apb/tasks/main.yml
roles/deprovision-jenkins-apb/defaults/main.yml
roles/deprovision-jenkins-apb/meta/main.yml
collections/requirements.yml
execution-environment.yml
bindep.txt
requirements.txt
```

**Services to check**:
- Jenkins `Deployment` rollout: `oc rollout status deployment/jenkins -n <namespace>`
- Jenkins `Service` (port 80): `oc get svc jenkins -n <namespace>`
- Jenkins JNLP `Service` (port 50000): `oc get svc jenkins-jnlp -n <namespace>`
- Jenkins `Route`: `oc get route jenkins -n <namespace>`
- Jenkins `ServiceAccount`: `oc get sa jenkins -n <namespace>`
- Jenkins `RoleBinding`: `oc get rolebinding jenkins_edit -n <namespace>`
- PVC (if persistent): `oc get pvc jenkins -n <namespace>`
- ImageStream (if S2I): `oc get is jenkins -n <namespace>`
- BuildConfig (if S2I): `oc get bc jenkins -n <namespace>`

**Templates to validate**:
- `roles/provision-jenkins-apb/templates/dc.yaml.j2` — Validate `Deployment` YAML renders correctly for both `persistent: true` and `persistent: false` cases, and for both S2I and non-S2I cases.
- `roles/provision-jenkins-apb/templates/buildconfig.yaml.j2` — Validate `apiVersion: build.openshift.io/v1` and all three `source_*` variables are substituted correctly.
- `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2` — Validate `apiVersion: rbac.authorization.k8s.io/v1`, `roleRef.apiGroup`, and `subjects[].namespace` are present (or eliminate in favor of inline `resource_definition:`).

---

## Pre-flight Checks

```bash
# 1. Verify kubernetes.core collection is installed
ansible-galaxy collection list | grep kubernetes.core

# 2. Verify Python Kubernetes client is available in the execution environment
python3 -c "import kubernetes; print(kubernetes.__version__)"
python3 -c "import openshift; print(openshift.__version__)"

# 3. Verify OpenShift cluster connectivity and authentication
oc whoami
oc cluster-info

# 4. Verify target namespace exists and has required permissions
oc auth can-i create deployment -n <namespace>
oc auth can-i create service -n <namespace>
oc auth can-i create route -n <namespace>
oc auth can-i create serviceaccount -n <namespace>
oc auth can-i create rolebinding -n <namespace>
oc auth can-i create pvc -n <namespace>

# 5. Validate that the jenkins ImageStream exists in the openshift namespace
oc get is jenkins -n openshift

# 6. Dry-run the provision playbook (ansible