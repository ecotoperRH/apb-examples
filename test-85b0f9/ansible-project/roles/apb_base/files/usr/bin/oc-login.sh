#!/usr/bin/env bash
# oc-login.sh — Authenticate to an OpenShift/Kubernetes cluster.
# Supports token-based login (OPENSHIFT_TARGET + OPENSHIFT_TOKEN env vars)
# or in-cluster service account authentication.

set -euo pipefail

if [[ -n "${OPENSHIFT_TARGET:-}" ]] && [[ -n "${OPENSHIFT_TOKEN:-}" ]]; then
  echo "Got OPENSHIFT token."
  LOGIN_PARAMS="--token=${OPENSHIFT_TOKEN}"
  # Use CA bundle if provided; otherwise fall back to insecure (not recommended)
  if [[ -n "${OPENSHIFT_CA_BUNDLE:-}" ]]; then
    LOGIN_PARAMS="${LOGIN_PARAMS} --certificate-authority=${OPENSHIFT_CA_BUNDLE}"
  else
    echo "WARNING: No CA bundle provided; using --insecure-skip-tls-verify=true" >&2
    LOGIN_PARAMS="${LOGIN_PARAMS} --insecure-skip-tls-verify=true"
  fi
else
  echo "Attempting to login with a service account..."
  OPENSHIFT_TARGET="${OPENSHIFT_TARGET:-https://kubernetes.default}"
  SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
  SA_CA_FILE="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  if [[ ! -f "${SA_TOKEN_FILE}" ]]; then
    echo "ERROR: Service account token not found at ${SA_TOKEN_FILE}" >&2
    exit 1
  fi
  LOGIN_PARAMS="--certificate-authority=${SA_CA_FILE} --token=$(cat "${SA_TOKEN_FILE}")"
fi

oc login "${OPENSHIFT_TARGET}" ${LOGIN_PARAMS} || {
  echo "ERROR: oc login failed." >&2
  exit 1
}
