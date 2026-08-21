---
source-path: jenkins-apb
---

Now I have all the information needed to write a comprehensive migration plan. Let me compile the full analysis.

---

# Migration Plan: jenkins-apb

**TLDR**: `jenkins-apb` is an Ansible Playbook Bundle (APB) that provisions and deprovisions a Jenkins CI/CD server on OpenShift, supporting both ephemeral and persistent storage, optional S2I (source-to-image) customization, and OpenShift OAuth integration. The entire codebase relies on the now-defunct `ansible.kubernetes-modules` role and a suite of tombstoned APB-era modules (`k8s_v1_service`, `openshift_v1_route`, `k8s_v1_persistent_volume_claim`, `openshift_v1_deployment_config`, etc.) that have no direct 1:1 successors — they must all be replaced with `kubernetes.core.k8s`. Additional modernization needs include: bare `command: oc` workarounds replaced with proper Kubernetes API calls, `ignore_errors: true` patterns replaced with `block/rescue`, missing `changed_when` on all `command:` tasks, unquoted boolean defaults, missing FQCN on `template:` tasks, and a full structural migration away from the APB container model toward a standard Ansible role/collection layout.

---

## Service Type and Configuration

**Service Type**: CI/CD Platform Provisioner (OpenShift/Kubernetes Workload Lifecycle Manager)

**Key Operations**:
- Provision a Jenkins `Service` (port 80 → 8080) with OpenShift infrastructure annotations
- Provision a Jenkins JNLP agent `Service` (port 50000)
- Provision an OpenShift `Route` with TLS edge termination and redirect
- Conditionally provision a `PersistentVolumeClaim` (when `persistent: true`)
- Provision a `ServiceAccount` with OAuth redirect reference annotation
- Provision a `RoleBinding` granting `edit` to the Jenkins service account (via `oc create -f` workaround)
- Conditionally provision an `ImageStream` and `BuildConfig` for S2I Jenkins customization (when `source_git_uri`, `source_git_ref`, and `source_context_dir` are defined)
- Provision a `DeploymentConfig` (ephemeral or persistent volume mount, ImageStream trigger)
- Deprovision all of the above resources in reverse (delete path)
- Services managed: Jenkins (HTTP/8080), JNLP agent (TCP/50000)
- Images used: `jenkins:latest` (OpenShift ImageStream), `ansibleplaybookbundle/apb-base` (container base)

---

## File Structure

**Task Files:**
```
roles/provision-jenkins-apb/tasks/main.yml
roles/deprovision-jenkins-apb/tasks/main.yml
```

**Handler Files:**
```
(none — no handlers directory exists in either role)
```

**Variable Files:**
```
roles/provision-jenkins-apb/defaults/main.yml
roles/provision-jenkins-apb/vars/main.yml
roles/deprovision-jenkins-apb/defaults/main.yml
```

**Meta:**
```
(none — no meta/main.yml exists in either role; apb.yml serves as the APB manifest)
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

**APB Manifest / Project Files:**
```
apb.yml
Dockerfile
Makefile
```

---

## Module Explanation

The role performs operations in this order:

### 1. **Provision Playbook Entry Point** (`playbooks/provision.yml`)
- Runs on `localhost` with `connection: local` and `gather_facts: false`
- Loads the legacy `ansible.kubernetes-modules` role (the entire APB Kubernetes module library — **tombstoned**)
- Then runs `provision-jenkins-apb` role
- **Legacy pattern**: Dependency on `ansible.kubernetes-modules` role for all `k8s_v1_*` and `openshift_v1_*` modules
- **Modern equivalent**: All Kubernetes/OpenShift API interactions replaced by `kubernetes.core.k8s` from the `kubernetes.core` collection; the `ansible.kubernetes-modules` role dependency is removed entirely

### 2. **Provision Tasks** (`roles/provision-jenkins-apb/tasks/main.yml`)

**Step 1 — Create Jenkins Service**
- Module: `k8s_v1_service` (tombstoned APB module)
- Uses flat parameter style (`spec_ports`, `spec_selector`, `spec_session_affinity`, `spec_type`) — APB-era flattened parameter API, not standard Kubernetes manifest structure
- **Modern equivalent**: `kubernetes.core.k8s` with an inline `definition:` block using standard Kubernetes Service manifest YAML. **Parameter drift is total** — every `spec_*` flat parameter must be rewritten as nested YAML under `definition.spec`.

**Step 2 — Create JNLP Service**
- Module: `k8s_v1_service` (tombstoned)
- Same flat-parameter pattern as above
- **Modern equivalent**: `kubernetes.core.k8s` with inline `definition:`

**Step 3 — Create Route**
- Module: `openshift_v1_route` (tombstoned APB module)
- Flat parameters: `spec_tls_insecure_edge_termination_policy`, `spec_tls_termination`, `spec_to_kind`, `spec_to_name`
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` using `apiVersion: route.openshift.io/v1`, `kind: Route`. Requires `community.okd` collection or `kubernetes.core.k8s` with the OpenShift API available.

**Step 4 — Create PersistentVolumeClaim** (conditional: `when: persistent`)
- Module: `k8s_v1_persistent_volume_claim` (tombstoned)
- Flat parameters: `spec_access_modes`, `spec_resources_requests`
- `when: persistent` — bare variable boolean, needs `| bool` filter
- **Modern equivalent**: `kubernetes.core.k8s` with inline `definition:` for a PVC manifest

**Step 5 — Create ServiceAccount**
- Module: `k8s_v1_service_account` (tombstoned)
- Has `ignore_errors: True` as a documented workaround for an `AttributeError` bug in the old module
- `True` (Python-style boolean) should be `true` (YAML boolean)
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` for a ServiceAccount manifest; the bug no longer exists, so `ignore_errors` can be removed. Wrap in `block/rescue` if defensive error handling is still desired.

**Step 6 — Create RoleBinding from Ansible Template**
- Module: `template:` (short name, missing FQCN)
- Renders `rolebinding.yaml.j2` to `/tmp/rolebinding.yaml`
- Result registered as `rolebinding`
- **Modern equivalent**: This entire step is eliminated. The RoleBinding manifest is passed directly as `definition:` to `kubernetes.core.k8s`, removing the need for a temp-file intermediary.

**Step 7 — Create RoleBinding via `oc` CLI**
- Module: `command:` — `oc create -f /tmp/rolebinding.yaml -n {{ namespace }}`
- `ignore_errors: True` workaround because `oc create` fails if the resource already exists (not idempotent)
- Missing `changed_when:` — always reports changed
- **Modern equivalent**: `kubernetes.core.k8s` with `state: present` is idempotent by default; `ignore_errors` and the `oc` CLI dependency are eliminated entirely.

**Step 8 — Create ImageStream** (conditional: `source_git_uri/ref/context_dir` defined)
- Module: `openshift_v1_image_stream` (tombstoned)
- `when:` condition uses `is defined` chained with `and` — valid but verbose
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` for `apiVersion: image.openshift.io/v1`, `kind: ImageStream`

**Step 9 — Template BuildConfig** (conditional)
- Module: `template:` (short name, missing FQCN)
- Renders `buildconfig.yaml.j2` to `/tmp/buildconfig.yaml`
- **Modern equivalent**: Eliminated — BuildConfig manifest passed directly as `definition:` to `kubernetes.core.k8s`

**Step 10 — Create BuildConfig via `oc` CLI** (conditional)
- Module: `command:` — `oc create -f /tmp/buildconfig.yaml -n {{ namespace }}`
- `ignore_errors: True` (non-idempotent workaround)
- Missing `changed_when:`
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` for `apiVersion: build.openshift.io/v1`, `kind: BuildConfig`

**Step 11 — Create DeploymentConfig from Template**
- Module: `template:` (short name, missing FQCN)
- Renders `dc.yaml.j2` to `/tmp/dc.yaml`
- **Modern equivalent**: Eliminated — DeploymentConfig manifest passed directly as `definition:` to `kubernetes.core.k8s`

**Step 12 — Create DeploymentConfig**
- Module: `openshift_v1_deployment_config` (tombstoned)
- Uses `src:` parameter pointing to the temp file rendered in Step 11 — this is the APB workaround for complex manifests
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` using the full DeploymentConfig YAML inline (or loaded via `lookup('template', ...)`)

### 3. **Deprovision Tasks** (`roles/deprovision-jenkins-apb/tasks/main.yml`)

All tasks mirror the provision role but with `state: absent`. The same tombstoned modules are used:

| Task | Legacy Module | Modern Equivalent |
|---|---|---|
| Delete Jenkins Service | `k8s_v1_service` | `kubernetes.core.k8s` + `state: absent` |
| Delete JNLP Service | `k8s_v1_service` | `kubernetes.core.k8s` + `state: absent` |
| Delete Route | `openshift_v1_route` | `kubernetes.core.k8s` + `state: absent` |
| Delete PVC | `k8s_v1_persistent_volume_claim` | `kubernetes.core.k8s` + `state: absent` |
| Delete ServiceAccount | `k8s_v1_service_account` + `ignore_errors: True` | `kubernetes.core.k8s` + `state: absent` |
| Delete RoleBinding | `command: oc delete rolebinding ...` + `ignore_errors: True` | `kubernetes.core.k8s` + `state: absent` |
| Delete ImageStream | `openshift_v1_image_stream` | `kubernetes.core.k8s` + `state: absent` |
| Delete BuildConfig | `openshift_v1_build_config` | `kubernetes.core.k8s` + `state: absent` |
| Delete DeploymentConfig | `openshift_v1_deployment_config` | `kubernetes.core.k8s` + `state: absent` |

- `ignore_errors: True` on Delete ServiceAccount and Delete RoleBinding should be replaced with `block/rescue` or simply removed (since `kubernetes.core.k8s` with `state: absent` is idempotent and does not fail if the resource is missing).

### 4. **Templates** (`roles/provision-jenkins-apb/templates/`)

**`dc.yaml.j2`** — DeploymentConfig manifest:
- Uses bare `{{ persistent }}` in a Jinja2 `{% if persistent %}` conditional — works but should be `{% if persistent | bool %}`
- Uses bare `{{ source_git_uri is defined }}` conditional — valid Jinja2 test
- `enable_oauth` value is rendered as `"{{ enable_oauth }}"` — a string in the env var; this is intentional for the container env but the variable itself is a boolean in defaults, so the template correctly stringifies it
- `apiVersion: v1` for `DeploymentConfig` — this is the legacy OpenShift v1 API; modern OpenShift uses `apiVersion: apps.openshift.io/v1`

**`buildconfig.yaml.j2`** — BuildConfig manifest:
- `apiVersion: v1` — legacy; modern is `apiVersion: build.openshift.io/v1`
- No bare variable issues; all variables are properly quoted

**`rolebinding.yaml.j2`** — RoleBinding manifest:
- `apiVersion: v1` — legacy; modern is `apiVersion: rbac.authorization.k8s.io/v1`
- `kind: RoleBinding` with `roleRef.name: edit` — modern RoleBinding requires `roleRef.apiGroup: rbac.authorization.k8s.io` and `roleRef.kind: ClusterRole`
- `subjects[0]` is missing `namespace:` field — required in modern RBAC
- Bare variable `{{ jenkins_service_name }}` in subjects without quotes — should be `"{{ jenkins_service_name }}"`

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `k8s_v1_service:` | `kubernetes.core.k8s:` with `definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | **Tombstoned module** — total parameter drift; all `spec_*` flat params → nested YAML manifest |
| `k8s_v1_persistent_volume_claim:` | `kubernetes.core.k8s:` with `definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | **Tombstoned module** — `spec_access_modes`, `spec_resources_requests` → nested manifest |
| `k8s_v1_service_account:` | `kubernetes.core.k8s:` with `definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | **Tombstoned module** — `ignore_errors` workaround eliminated |
| `openshift_v1_route:` | `kubernetes.core.k8s:` with `definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | **Tombstoned module** — `apiVersion: route.openshift.io/v1` |
| `openshift_v1_image_stream:` | `kubernetes.core.k8s:` with `definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | **Tombstoned module** — `apiVersion: image.openshift.io/v1` |
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with `definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | **Tombstoned module** — `src:` param eliminated; manifest inlined or via `lookup('template', ...)` |
| `openshift_v1_build_config:` | `kubernetes.core.k8s:` with `definition:` | `roles/deprovision-jenkins-apb/tasks/main.yml` | **Tombstoned module** |
| `openshift_v1_role_binding:` (implicit, via `oc` CLI) | `kubernetes.core.k8s:` with `definition:` | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Replace `command: oc create/delete` workaround |
| `template:` | `ansible.builtin.template:` | `roles/provision-jenkins-apb/tasks/main.yml` | FQCN missing; entire pattern eliminated in favor of inline `definition:` |
| `command: oc create -f ...` | `kubernetes.core.k8s:` | `roles/provision-jenkins-apb/tasks/main.yml` | Non-idempotent CLI workaround; `ignore_errors: True` required; eliminated |
| `command: oc delete rolebinding ...` | `kubernetes.core.k8s:` with `state: absent` | `roles/deprovision-jenkins-apb/tasks/main.yml` | Non-idempotent CLI workaround; eliminated |
| `ignore_errors: True` (ServiceAccount, RoleBinding, BuildConfig) | `block: / rescue:` or removal | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | `kubernetes.core.k8s` is idempotent; `ignore_errors` workarounds no longer needed |
| `ignore_errors: True` (Python-style `True`) | `ignore_errors: true` (YAML boolean) | Both task files | Boolean casing — `True`/`False` → `true`/`false` |
| `persistent: False` in defaults | `persistent: false` | `roles/provision-jenkins-apb/defaults/main.yml`, `roles/deprovision-jenkins-apb/defaults/main.yml` | Python-style boolean → YAML boolean |
| `enable_oauth: True` in defaults | `enable_oauth: true` | `roles/provision-jenkins-apb/defaults/main.yml` | Python-style boolean → YAML boolean |
| `when: persistent` (bare boolean variable) | `when: persistent \| bool` | `roles/provision-jenkins-apb/tasks/main.yml` | Explicit bool filter for safety |
| `command:` tasks missing `changed_when:` | Add `changed_when: false` or result-based condition | `roles/provision-jenkins-apb/tasks/main.yml`, `roles/deprovision-jenkins-apb/tasks/main.yml` | Idempotency — all `command:` tasks always report changed |
| `role: ansible.kubernetes-modules` dependency | Remove entirely | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Replaced by `kubernetes.core` collection |
| `playbook_debug: True` role var | `playbook_debug: true` | `playbooks/provision.yml` | Python-style boolean → YAML boolean |
| `playbook_debug: false` | Already correct | `playbooks/deprovision.yml` | No change needed |
| `apiVersion: v1` for DeploymentConfig | `apiVersion: apps.openshift.io/v1` | `roles/provision-jenkins-apb/templates/dc.yaml.j2` | Legacy OpenShift API version |
| `apiVersion: v1` for BuildConfig | `apiVersion: build.openshift.io/v1` | `roles/provision-jenkins-apb/templates/buildconfig.yaml.j2` | Legacy OpenShift API version |
| `apiVersion: v1` for RoleBinding | `apiVersion: rbac.authorization.k8s.io/v1` | `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2` | Legacy API version |
| `roleRef:` missing `apiGroup:` and `kind:` | Add `apiGroup: rbac.authorization.k8s.io` and `kind: ClusterRole` | `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2` | Required fields in modern RBAC |
| `subjects[0]` missing `namespace:` | Add `namespace: "{{ namespace }}"` | `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2` | Required for namespaced ServiceAccount subjects |
| Bare `{{ jenkins_service_name }}` in subjects | `"{{ jenkins_service_name }}"` (quoted) | `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2` | Bare variable in YAML value |
| `{% if persistent %}` in template | `{% if persistent \| bool %}` | `roles/provision-jenkins-apb/templates/dc.yaml.j2` | Explicit bool filter |
| APB container model (`Dockerfile`, `apb.yml`) | Ansible Collection / EE model | `Dockerfile`, `apb.yml` | APB framework is EOL; migrate to Execution Environment |
| `gather_facts: false` | `gather_facts: false` | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Already correct; keep as-is |
| `connection: local` | `connection: local` | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Correct for k8s operations; keep as-is |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: community.okd
    version: ">=2.3.0"
  - name: ansible.utils
    version: ">=2.10.0"
```

> **Note**: `community.okd` provides OpenShift-specific resource support (Routes, ImageStreams, BuildConfigs, DeploymentConfigs) via `kubernetes.core.k8s` when the OpenShift API is available. Alternatively, all resources can be managed purely through `kubernetes.core.k8s` if the target cluster has the OpenShift APIs registered.

**Role dependencies**: 
- `ansible.kubernetes-modules` — **REMOVE**. This is the legacy APB Kubernetes module role that provided all `k8s_v1_*` and `openshift_v1_*` modules. It is entirely replaced by the `kubernetes.core` collection.

**External packages / binaries**:
- `oc` (OpenShift CLI) — currently required by `command: oc create/delete` workarounds. **Eliminated** in the modern role; no CLI dependency needed.
- `openshift` Python library (pip) — required by `kubernetes.core.k8s`
- `kubernetes` Python library (pip) — required by `kubernetes.core.k8s`

**Services managed**:
- Jenkins HTTP service (ClusterIP, port 80 → 8080)
- Jenkins JNLP agent service (ClusterIP, port 50000)
- OpenShift Route (TLS edge, HTTPS → Jenkins service)
- Jenkins DeploymentConfig / Pod lifecycle

---

## Template Modernization

**`roles/provision-jenkins-apb/templates/dc.yaml.j2`**:
- Change `apiVersion: v1` → `apiVersion: apps.openshift.io/v1` for DeploymentConfig
- Change `{% if persistent %}` → `{% if persistent | bool %}` for explicit boolean evaluation
- The `"{{ enable_oauth }}"` env var value is intentionally a string (container env vars are always strings) — no change needed, but add a comment for clarity
- The `{% if source_git_uri is defined %}` conditional is valid modern Jinja2 — no change needed
- Consider migrating from `DeploymentConfig` (OpenShift-specific) to a standard Kubernetes `Deployment` with an `ImageStream` trigger annotation for broader compatibility

**`roles/provision-jenkins-apb/templates/buildconfig.yaml.j2`**:
- Change `apiVersion: v1` → `apiVersion: build.openshift.io/v1`
- No Jinja2 issues; all variables are properly quoted

**`roles/provision-jenkins-apb/templates/rolebinding.yaml.j2`**:
- Change `apiVersion: v1` → `apiVersion: rbac.authorization.k8s.io/v1`
- Add `roleRef.apiGroup: rbac.authorization.k8s.io`
- Add `roleRef.kind: ClusterRole` (the `edit` role is a ClusterRole)
- Add `namespace: "{{ namespace }}"` to the subject entry
- Quote the bare variable: `name: {{ jenkins_service_name }}` → `name: "{{ jenkins_service_name }}"`
- **Consider eliminating this template entirely** — the RoleBinding can be defined as an inline `definition:` dict in the task, removing the temp-file render-then-apply pattern

---

## Argument Specification

The following variables should be documented in `meta/argument_specs.yml` (to be created):

| Variable | Type | Default | Required | Description |
|---|---|---|---|---|
| `namespace` | `str` | _(none)_ | **yes** | Target OpenShift/Kubernetes namespace |
| `persistent` | `bool` | `false` | no | Enable persistent storage via PVC |
| `volume_capacity` | `str` | `"1Gi"` | no | PVC storage size (used when `persistent: true`) |
| `enable_oauth` | `bool` | `true` | no | Enable OpenShift OAuth login for Jenkins |
| `memory_limit` | `str` | `"512Mi"` | no | Memory limit for the Jenkins container |
| `jenkins_service_name` | `str` | `"jenkins"` | no | Name for Jenkins Service, SA, Route, DC, PVC |
| `jnlp_service_name` | `str` | `"jenkins-jnlp"` | no | Name for the JNLP agent Service |
| `jenkins_image_stream_tag` | `str` | `"jenkins:latest"` | no | ImageStreamTag to deploy |
| `source_git_uri` | `str` | _(none)_ | no | Git URI for S2I Jenkins customization |
| `source_git_ref` | `str` | _(none)_ | no | Git branch/ref for S2I build |
| `source_context_dir` | `str` | _(none)_ | no | Context directory within the Git repo for S2I |
| `state` | `str` | `"present"` | no | Desired state: `present` or `absent` |

> **Note**: `source_git_uri`, `source_git_ref`, and `source_context_dir` are all-or-nothing — if any one is defined, all three must be defined. This co-dependency should be enforced in `argument_specs.yml` using `mutually_exclusive` or documented as a constraint.

---

## Checks for the Migration

**Files to verify** (all created/modified files in the modern role):

```
collections/requirements.yml                          ← NEW: collection dependencies
meta/argument_specs.yml                               ← NEW: role argument validation
roles/provision-jenkins-apb/tasks/main.yml            ← REWRITE: all tombstoned modules replaced
roles/provision-jenkins-apb/defaults/main.yml         ← MODIFY: Python booleans → YAML booleans
roles/provision-jenkins-apb/vars/main.yml             ← KEEP: no changes needed
roles/provision-jenkins-apb/templates/dc.yaml.j2      ← MODIFY: apiVersion, bool filter
roles/provision-jenkins-apb/templates/buildconfig.yaml.j2  ← MODIFY: apiVersion
roles/provision-jenkins-apb/templates/rolebinding.yaml.j2  ← MODIFY or ELIMINATE: apiVersion, RBAC fields
roles/deprovision-jenkins-apb/tasks/main.yml          ← REWRITE: all tombstoned modules replaced
roles/deprovision-jenkins-apb/defaults/main.yml       ← MODIFY: Python booleans → YAML booleans
playbooks/provision.yml                               ← MODIFY: remove ansible.kubernetes-modules role dep
playbooks/deprovision.yml                             ← MODIFY: remove ansible.kubernetes-modules role dep
execution-environment.yml                             ← NEW: EE definition
bindep.txt                                            ← NEW: system package dependencies
```

**Services to check**:
- Jenkins HTTP endpoint: `curl http://<route-host>/login` — expect HTTP 200
- Jenkins JNLP port: `nc -zv <jenkins-service-clusterip> 50000` — expect connection accepted
- OpenShift Route: `oc get route {{ jenkins_service_name }} -n {{ namespace }}` — expect `edge` TLS termination
- DeploymentConfig rollout: `oc rollout status dc/{{ jenkins_service_name }} -n {{ namespace }}`
- PVC (when persistent): `oc get pvc {{ jenkins_service_name }} -n {{ namespace }}` — expect `Bound`

**Templates to validate**:
- `roles/provision-jenkins-apb/templates/dc.yaml.j2` — validate rendered YAML with `kubectl apply --dry-run=client`
- `roles/provision-jenkins-apb/templates/buildconfig.yaml.j2` — validate rendered YAML with `oc apply --dry-run=client`
- `roles/provision-jenkins-apb/templates/rolebinding.yaml.j2` — validate rendered YAML with `kubectl apply --dry-run=client`

---

## Pre-flight Checks

```bash
# 1. Verify kubernetes.core collection is installed
ansible-galaxy collection list | grep kubernetes.core

# 2. Verify community.okd collection is installed (for OpenShift resource types)
ansible-galaxy collection list | grep community.okd

# 3. Verify Python dependencies for kubernetes.core.k8s
python3 -c "import kubernetes; import openshift; print('OK')"

# 4. Verify cluster connectivity
kubectl cluster-info

# 5. Verify target namespace exists
kubectl get namespace {{ namespace }}

# 6. Verify OpenShift-specific APIs are available (Route, ImageStream, BuildConfig, DeploymentConfig)
kubectl api-resources | grep -E "routes|imagestreams|buildconfigs|deploymentconfigs"

# 7. Dry-run the provision playbook
ansible-playbook playbooks/provision.yml -e namespace=test-jenkins --check

# 8. Lint the modernized role
ansible-lint roles/provision-jenkins-apb/
ansible-lint roles/deprovision-jenkins-apb/

# 9. Validate argument specs
ansible-playbook playbooks/provision.yml -e namespace=test-jenkins -e persistent=true \
  -e source_git_uri=https://github.com/example/jenkins-config \
  -e source_git_ref=main \
  -e source_context_dir=.

# 10. Post-provision: verify all resources created
kubectl get svc,route,sa,rolebinding,dc,pvc -l name=jenkins -n {{ namespace }}

# 11. Post-deprovision: verify all resources removed
kubectl get svc,route,sa,rolebinding,dc,pvc -l name=jenkins -n {{ namespace }}
# Expected: "No resources found"
```

---

## Additional Migration Notes

### APB Framework EOL
The entire APB (Ansible Playbook Bundle) framework — including `apb.yml`, the `ansibleplaybookbundle/apb-base` Docker image, the `ansible.kubernetes-modules` role, and the APB service catalog integration — is **end-of-life** and no longer maintained. The migration path is:

1. **Remove** `apb.yml`, `Dockerfile` (APB-specific), and the `Makefile` APB targets
2. **Replace** with a standard Ansible Collection structure or a standalone role with `meta/main.yml`
3. **Replace** the APB container execution model with an **Ansible Execution Environment (EE)** using `execution-environment.yml` and `bindep.txt`
4. **Replace** the APB service catalog parameter schema (`apb.yml` `plans/parameters`) with `meta/argument_specs.yml`

### `openshift_v1_deployment_config` + `src:` Parameter Drift
The legacy `openshift_v1_deployment_config` module accepted a `src:` parameter pointing to a rendered YAML file. `kubernetes.core.k8s` does **not** have a `src:` parameter in the same sense — it uses either `definition:` (inline dict) or `src:` pointing to a static file. The recommended modern pattern is:

```yaml
- name: Create DeploymentConfig
  kubernetes.core.k8s:
    state: "{{ state }}"
    namespace: "{{ namespace }}"
    definition: "{{ lookup('ansible.builtin.template', 'dc.yaml.j2') | from_yaml }}"
```

This eliminates the temp-file intermediary entirely.

### `ignore_errors` → `block/rescue` Migration
The three `ignore_errors: True` workarounds in the provision role should be evaluated individually:
- **ServiceAccount**: The underlying bug (`Attribute