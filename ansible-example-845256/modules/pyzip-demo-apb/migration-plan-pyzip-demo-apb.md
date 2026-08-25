---
source-path: pyzip-demo-apb
---

I now have all the information needed. Let me compile the complete migration plan.

---

# Migration Plan: pyzip-demo-apb

**TLDR**: `pyzip-demo-apb` is a legacy **Ansible Playbook Bundle (APB)** that provisions a Python Zip Demo web application onto an OpenShift cluster. It creates an OpenShift Route, a Kubernetes Service, and an OpenShift DeploymentConfig using tombstoned APB-era modules (`openshift_v1_route`, `k8s_v1_service`, `openshift_v1_deployment_config`) sourced from the now-defunct `ansible.kubernetes-modules` role. The entire APB packaging model (Docker-based, `apb.yml` spec, `apb-base` image) must be replaced with a modern Ansible role/collection structure targeting `kubernetes.core` and `redhat.openshift` collection modules, with Kubernetes-native manifests managed via `kubernetes.core.k8s`.

---

## Service Type and Configuration

**Service Type**: Kubernetes/OpenShift Application Provisioner (Web Application Deployment)

**Key Operations**:
- Creates an OpenShift `Route` resource exposing port `web` (8080) for the `pyzip-demo` application
- Creates a Kubernetes `Service` resource on port 8080/TCP with label selectors `app: pyzip-demo-apb` / `service: pyzip-demo`
- Creates an OpenShift `DeploymentConfig` resource running `docker.io/ansibleplaybookbundle/py-zip-demo:latest` with 1 replica, a `ConfigChange` trigger, and standard restart/DNS policies
- All three resources are deployed into a configurable `namespace` (defaulting to the `NAMESPACE` environment variable or `pyzip-demo`)
- Resource `state` is parameterized (`present`/`absent`) to support both provision and deprovision workflows
- The APB is packaged as a Docker image (`ansibleplaybookbundle/pyzip-demo-apb`) built from `apb-base`, with the spec embedded as a base64 label

---

## File Structure

**Task Files:**
```
roles/provision-pyzip-demo-apb/tasks/main.yml
```

**Variable Files:**
```
roles/provision-pyzip-demo-apb/defaults/main.yml
```

**Playbook Files:**
```
playbooks/provision.yml
```

**APB Spec / Metadata:**
```
apb.yml
```

**Container Build:**
```
Dockerfile
```

**Documentation:**
```
README.md
```

> **Note**: There are no `handlers/`, `templates/`, `files/`, `vars/`, or `meta/` directories in the role. These must be created as part of the modernization.

---

## Module Explanation

The role performs operations in this order:

### 1. **Playbook Entry Point** (`playbooks/provision.yml`)

- Runs on `localhost` with `connection: local` and `gather_facts: false`
- Loads the `ansible.kubernetes-modules` role first with `install_python_requirements: no` — this role was the APB-era shim that provided the `openshift_v1_*` and `k8s_v1_*` modules as dynamic Python libraries. **This role is entirely obsolete and has no modern equivalent as a role dependency.**
- Then loads `provision-pyzip-demo-apb` with `playbook_debug: false`
- **Legacy pattern**: Dependency on `ansible.kubernetes-modules` role → **must be removed**; replaced by declaring `kubernetes.core` and `redhat.openshift` in `collections/requirements.yml`
- **Legacy pattern**: `playbook_debug: false` role variable → replace with standard `verbosity` controls or remove
- Ansible module mapping: `ansible.kubernetes-modules` (role) → `kubernetes.core` + `redhat.openshift` (collections)

### 2. **Provision Tasks** (`roles/provision-pyzip-demo-apb/tasks/main.yml`)

#### Task 1 — Create OpenShift Route
- Uses `openshift_v1_route:` — a tombstoned APB-era dynamic module
- Parameters: `name`, `namespace`, `spec_port_target_port`, `labels`, `to_name`, `state`
- The `spec_port_target_port` parameter is APB-era flattened notation (dot-path encoded as underscores) — **no direct equivalent parameter exists in modern modules**
- **Modern equivalent**: `redhat.openshift.openshift_route` or `kubernetes.core.k8s` with an inline Route manifest
- Ansible module mapping: `openshift_v1_route` → `kubernetes.core.k8s` (with full Route manifest) or `redhat.openshift.openshift_route`

#### Task 2 — Create Kubernetes Service
- Uses `k8s_v1_service:` — a tombstoned APB-era dynamic module
- Parameters: `name`, `namespace`, `labels`, `selector`, `ports` (list with `name`, `port`, `protocol`, `target_port`), `state`
- **Modern equivalent**: `kubernetes.core.k8s` with an inline Service manifest
- Ansible module mapping: `k8s_v1_service` → `kubernetes.core.k8s`

#### Task 3 — Create OpenShift DeploymentConfig
- Uses `openshift_v1_deployment_config:` — a tombstoned APB-era dynamic module
- Parameters use APB-era flattened underscore notation: `spec_template_metadata_labels`, `dns_policy`, `restart_policy`, `termination_grace_period_seconds`, `test`, `triggers`
- Container spec is partially defined (missing `resources:`, `readinessProbe:`)
- `image_pull_policy: IfNotPresent` is a valid field but expressed in APB underscore style
- **Note**: `openshift_v1_deployment_config` maps to an OpenShift-specific resource (`DeploymentConfig`). Modern OpenShift recommends migrating `DeploymentConfig` → `Deployment` (standard Kubernetes), but a faithful migration preserves `DeploymentConfig` via `kubernetes.core.k8s` with `apiVersion: apps.openshift.io/v1`
- Ansible module mapping: `openshift_v1_deployment_config` → `kubernetes.core.k8s` (with full DeploymentConfig manifest)

### 3. **Defaults** (`roles/provision-pyzip-demo-apb/defaults/main.yml`)

- `namespace`: Resolved from `NAMESPACE` env var with fallback to `'pyzip-demo'` — valid pattern, keep as-is
- `state`: Hardcoded to `present` — valid, keep as-is
- **Legacy pattern**: No `meta/argument_specs.yml` exists — must be created
- **Legacy pattern**: Boolean `False` in `apb.yml` (`bindable: False`) uses Python-style capitalized boolean — irrelevant to Ansible YAML but noted for documentation accuracy

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `openshift_v1_route:` | `kubernetes.core.k8s:` with Route manifest | `tasks/main.yml` | Tombstoned APB module; full parameter drift — all underscore-flattened params must become nested YAML manifest |
| `k8s_v1_service:` | `kubernetes.core.k8s:` with Service manifest | `tasks/main.yml` | Tombstoned APB module; parameter drift — `ports:` list structure is reused but wrapped in manifest |
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with DeploymentConfig manifest | `tasks/main.yml` | Tombstoned APB module; severe parameter drift — `spec_template_metadata_labels`, `dns_policy`, `restart_policy` etc. must become nested manifest keys |
| `spec_port_target_port: web` (flattened) | `spec.port.targetPort: web` inside Route manifest | `tasks/main.yml` | APB underscore-path encoding → proper nested YAML |
| `spec_template_metadata_labels:` (flattened) | `spec.template.metadata.labels:` inside DC manifest | `tasks/main.yml` | APB underscore-path encoding → proper nested YAML |
| `image_pull_policy: IfNotPresent` (flattened) | `imagePullPolicy: IfNotPresent` inside container spec | `tasks/main.yml` | APB underscore-path encoding → camelCase manifest key |
| `container_port: 8080` (flattened) | `containerPort: 8080` inside container ports spec | `tasks/main.yml` | APB underscore-path encoding → camelCase manifest key |
| `to_name: pyzip-demo` (flattened) | `spec.to.name: pyzip-demo` inside Route manifest | `tasks/main.yml` | APB underscore-path encoding → proper nested YAML |
| `role: ansible.kubernetes-modules` | Remove entirely; add `collections/requirements.yml` | `playbooks/provision.yml` | Obsolete APB shim role; replaced by collection declarations |
| `playbook_debug: false` | Remove or replace with `ansible_verbosity` | `playbooks/provision.yml` | APB-specific debug variable, no modern equivalent |
| `state: "{{ state }}"` bare variable | `state: "{{ state }}"` — acceptable, but add `| default('present')` | `tasks/main.yml` | Defensive defaulting; already set in defaults but good practice |
| `FROM ansibleplaybookbundle/apb-base` | Remove Dockerfile or replace with EE (`execution-environment.yml`) | `Dockerfile` | APB container model → Ansible Execution Environment |
| `LABEL "com.redhat.apb.spec"=...` | Remove; spec moves to `meta/argument_specs.yml` + `README.md` | `Dockerfile` | APB-specific label encoding |
| `apb.yml` spec file | Replace with `meta/main.yml` + `meta/argument_specs.yml` | `apb.yml` | APB spec format → standard Ansible role metadata |
| `bindable: False` (Python bool) | `bindable: false` (YAML bool) | `apb.yml` | Python-style capitalized boolean → lowercase YAML boolean |
| `free: True` (Python bool) | `free: true` (YAML bool) | `apb.yml` | Python-style capitalized boolean → lowercase YAML boolean |
| No `changed_when:` on resource tasks | Add `changed_when:` or rely on module's built-in diff | `tasks/main.yml` | `kubernetes.core.k8s` reports changed natively; no manual `changed_when` needed |
| No `meta/main.yml` | Create `meta/main.yml` with collection dependencies | _(new file)_ | Required for role metadata and Galaxy publishing |
| No `meta/argument_specs.yml` | Create with `namespace` and `state` specs | _(new file)_ | Role input validation |
| No `collections/requirements.yml` | Create with `kubernetes.core` and `redhat.openshift` | _(new file)_ | Collection dependency declaration |
| No `execution-environment.yml` | Create EE definition replacing Dockerfile | _(new file)_ | Modern packaging replaces APB Docker model |
| `community.kubernetes.*` (if used transitively) | `kubernetes.core.*` | transitive | Collection namespace migration |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: redhat.openshift
    version: ">=2.3.0"
  - name: ansible.utils
    version: ">=2.9.0"
```

**Role dependencies**:
- `ansible.kubernetes-modules` — **REMOVE**; this was the APB-era Kubernetes module shim and is entirely replaced by the `kubernetes.core` collection

**External packages** (Python, for EE / `bindep.txt`):
- `kubernetes` Python SDK (`pip install kubernetes`)
- `openshift` Python SDK (`pip install openshift`) — or the unified `python-kubernetes` package
- `PyYAML`

**Services managed**:
- No system services (systemd/init) are managed
- OpenShift/Kubernetes API resources managed:
  - `route.route.openshift.io/v1` — `pyzip-demo` Route
  - `v1/Service` — `pyzip-demo` Service (port 8080/TCP)
  - `apps.openshift.io/v1/DeploymentConfig` — `pyzip-demo` DeploymentConfig (1 replica, image `py-zip-demo:latest`)

**Container image dependency**:
- `docker.io/ansibleplaybookbundle/py-zip-demo:latest` — the application image deployed inside the DeploymentConfig

---

## Template Modernization

There are **no Jinja2 `.j2` template files** in this role. All Kubernetes/OpenShift resource definitions are expressed directly as module parameters in `tasks/main.yml`.

**Recommended modernization**: Convert the three resource definitions into Jinja2 templates (e.g., `templates/route.yml.j2`, `templates/service.yml.j2`, `templates/deploymentconfig.yml.j2`) and use `kubernetes.core.k8s` with `template:` parameter. This improves readability, enables manifest validation with `kubectl --dry-run`, and separates data from logic.

Example for the Service template (`templates/service.yml.j2`):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: pyzip-demo
  namespace: {{ namespace }}
  labels:
    app: pyzip-demo-apb
    service: pyzip-demo
spec:
  selector:
    app: pyzip-demo-apb
    service: pyzip-demo
  ports:
    - name: web
      port: 8080
      protocol: TCP
      targetPort: 8080
```

---

## Argument Specification

The following variables should be declared in `meta/argument_specs.yml`:

| Variable | Type | Default | Required | Description |
|---|---|---|---|---|
| `namespace` | `str` | `"{{ lookup('env','NAMESPACE') \| default('pyzip-demo', true) }}"` | No | Kubernetes/OpenShift namespace to deploy resources into |
| `state` | `str` | `present` | No | Desired state of all managed resources; `present` or `absent` |

**Proposed `meta/argument_specs.yml`**:
```yaml
argument_specs:
  main:
    short_description: Provision the pyzip-demo application on OpenShift
    description:
      - Creates an OpenShift Route, Kubernetes Service, and OpenShift DeploymentConfig
        for the py-zip-demo Python web application.
    options:
      namespace:
        type: str
        required: false
        default: pyzip-demo
        description: Kubernetes/OpenShift namespace to deploy resources into.
      state:
        type: str
        required: false
        default: present
        choices:
          - present
          - absent
        description: Desired state of all managed Kubernetes/OpenShift resources.
```

---

## New File Structure (Post-Migration)

The modernized role should have the following layout:

```
collections/requirements.yml
playbooks/provision.yml
playbooks/deprovision.yml
roles/provision-pyzip-demo-apb/tasks/main.yml
roles/provision-pyzip-demo-apb/defaults/main.yml
roles/provision-pyzip-demo-apb/meta/main.yml
roles/provision-pyzip-demo-apb/meta/argument_specs.yml
roles/provision-pyzip-demo-apb/templates/route.yml.j2
roles/provision-pyzip-demo-apb/templates/service.yml.j2
roles/provision-pyzip-demo-apb/templates/deploymentconfig.yml.j2
execution-environment.yml
bindep.txt
README.md
```

> `apb.yml` and `Dockerfile` are **retired** — their content migrates to `meta/main.yml`, `meta/argument_specs.yml`, and `execution-environment.yml`.

---

## Checks for the Migration

**Files to verify** (all created/modified files in the modern role):
```
collections/requirements.yml
playbooks/provision.yml
playbooks/deprovision.yml
roles/provision-pyzip-demo-apb/tasks/main.yml
roles/provision-pyzip-demo-apb/defaults/main.yml
roles/provision-pyzip-demo-apb/meta/main.yml
roles/provision-pyzip-demo-apb/meta/argument_specs.yml
roles/provision-pyzip-demo-apb/templates/route.yml.j2
roles/provision-pyzip-demo-apb/templates/service.yml.j2
roles/provision-pyzip-demo-apb/templates/deploymentconfig.yml.j2
execution-environment.yml
bindep.txt
```

**Services to check**:
- OpenShift Route `pyzip-demo` in target namespace — verify `HOST/PORT` is assigned
- Kubernetes Service `pyzip-demo` — verify `ClusterIP` assigned and endpoint resolves
- OpenShift DeploymentConfig `pyzip-demo` — verify `READY` replicas = 1

**Templates to validate**:
- `templates/route.yml.j2` — validate with `oc apply --dry-run=client`
- `templates/service.yml.j2` — validate with `kubectl apply --dry-run=client`
- `templates/deploymentconfig.yml.j2` — validate with `oc apply --dry-run=client`

---

## Pre-flight Checks

```bash
# 1. Verify collection dependencies are installed
ansible-galaxy collection install -r collections/requirements.yml

# 2. Verify Python SDK dependencies
pip show kubernetes openshift

# 3. Verify kubeconfig / OpenShift login is active
oc whoami
kubectl cluster-info

# 4. Lint the modernized role
ansible-lint roles/provision-pyzip-demo-apb/

# 5. Dry-run the provision playbook
ansible-playbook playbooks/provision.yml \
  -e namespace=pyzip-demo-test \
  -e state=present \
  --check --diff

# 6. Validate Route manifest template renders correctly
ansible -m template \
  -a "src=roles/provision-pyzip-demo-apb/templates/route.yml.j2 dest=/tmp/route.yml" \
  -e namespace=pyzip-demo localhost

oc apply --dry-run=client -f /tmp/route.yml

# 7. After provision, verify all resources are Running
oc get route,svc,dc -n pyzip-demo -l app=pyzip-demo-apb

# 8. Verify pod is Running
oc get pods -n pyzip-demo -l service=pyzip-demo

# 9. Test deprovision (state=absent) cleans up all resources
ansible-playbook playbooks/deprovision.yml \
  -e namespace=pyzip-demo-test \
  -e state=absent \
  --check --diff
```

---

## Critical Migration Notes

### ⚠️ APB Model is Entirely Obsolete
The Ansible Playbook Bundle (APB) framework — including `apb-base` Docker images, `apb.yml` spec files, the `ansible.kubernetes-modules` role, and the OpenShift Service Catalog integration — was **deprecated and removed** from Red Hat's supported portfolio. There is no upgrade path; this is a full rewrite to standard Ansible role + collection patterns.

### ⚠️ Severe Module Parameter Drift
All three task modules (`openshift_v1_route`, `k8s_v1_service`, `openshift_v1_deployment_config`) used APB's auto-generated Python bindings that encoded nested Kubernetes API paths as flat underscore-separated parameter names (e.g., `spec_template_metadata_labels`). The modern `kubernetes.core.k8s` module accepts **raw Kubernetes manifest YAML** under a `definition:` or `template:` key. Every single parameter must be remapped to its proper nested manifest position — there is no 1:1 parameter compatibility.

### ⚠️ DeploymentConfig vs. Deployment
OpenShift `DeploymentConfig` (`apps.openshift.io/v1`) is itself deprecated in OpenShift 4.x in favor of standard Kubernetes `Deployment` (`apps/v1`). A faithful migration preserves `DeploymentConfig` for compatibility, but the recommended path is to migrate to `Deployment` and replace the `ConfigChange` trigger with standard Kubernetes rolling update strategy.

### ⚠️ No deprovision Playbook Exists
The `README.md` documents a `deprovision` operation (run with `state=absent`), but no `playbooks/deprovision.yml` exists in the repository. The modern role should create this playbook explicitly, passing `state: absent` to the role.