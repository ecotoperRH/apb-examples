#!/usr/bin/env bash
# entrypoint.sh — Container entrypoint for APB lifecycle orchestration.
# Handles S2I detection, dynamic /etc/passwd entry, oc login,
# secret injection, playbook dispatch, bind-creds, and test-result lifecycle.

set -x

# Work-Around: OpenShift s2i (source-to-image) requires no ENTRYPOINT in
# builder base images. If called within an s2i assemble process, skip APB
# runtime steps and exec the s2i command directly.
if [[ $@ == *"s2i/assemble"* ]]; then
  echo "---> Performing S2I build... Skipping server startup"
  exec "$@"
  exit $?
fi

ACTION=$1
shift
playbooks=/opt/apb/actions
CREDS="/var/tmp/bind-creds"
TEST_RESULT="/var/tmp/test-result"

# Dynamic /etc/passwd entry for arbitrary UID support (required by OpenShift)
if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-apb}:x:$(id -u):0:${USER_NAME:-apb} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

oc-login.sh

set +x

SECRETS_DIR=/etc/apb-secrets
mounted_secrets=$(ls "${SECRETS_DIR}" 2>/dev/null || true)

extra_args=""
if [[ -n "${mounted_secrets}" ]]; then
  echo '---' > /tmp/secrets

  for key in ${mounted_secrets}; do
    for file in $(ls "${SECRETS_DIR}/${key}/..data"); do
      echo "${file}: $(cat "${SECRETS_DIR}/${key}/..data/${file}")" >> /tmp/secrets
    done
  done
  extra_args='--extra-vars no_log=true --extra-vars @/tmp/secrets'
fi

set -x

if [[ -e "${playbooks}/${ACTION}.yaml" ]]; then
  ANSIBLE_ROLES_PATH=/etc/ansible/roles:/opt/ansible/roles \
    ansible-playbook -i /etc/ansible/hosts "${playbooks}/${ACTION}.yaml" "${@}" ${extra_args}
elif [[ -e "${playbooks}/${ACTION}.yml" ]]; then
  ANSIBLE_ROLES_PATH=/etc/ansible/roles:/opt/ansible/roles \
    ansible-playbook -i /etc/ansible/hosts "${playbooks}/${ACTION}.yml" "${@}" ${extra_args}
else
  echo "'${ACTION}' NOT IMPLEMENTED"
  exit 0
fi

EXIT_CODE=$?

set +ex
if [[ -f /tmp/secrets ]]; then
  rm -f /tmp/secrets
fi
set -ex

if [ -f "${TEST_RESULT}" ]; then
  test-retrieval-init
fi

# If we are provisioning an APB, but it's not bindable then the bind-creds
# will never be created. Therefore, if bind-creds exists, we are running
# either provision or bind and the APB is bindable.
#
# bind-init keeps the container running until the broker gathers the bind
# credentials by exec'ing into the container.
if [ -f "${CREDS}" ]; then
  bind-init
fi

exit ${EXIT_CODE}
