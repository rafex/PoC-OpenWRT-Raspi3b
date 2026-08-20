#!/usr/bin/env bash
# ============================================================================
# test_generate_config.sh — Integration tests for config + router infrastructure
# ============================================================================
set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ ${1}"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ ${1}"; }

echo "=== Integration Tests ==="
echo ""

# Test 1: generate.sh syntax
bash -n scripts/templates/generate.sh 2>&1 && pass "generate.sh syntax" || fail "generate.sh syntax"

# Test 2: secrets.sh syntax
bash -n scripts/commons/secrets.sh 2>&1 && pass "secrets.sh syntax" || fail "secrets.sh syntax"

# Test 3: router-base.sh syntax
bash -n scripts/commons/router-base.sh 2>&1 && pass "router-base.sh syntax" || fail "router-base.sh syntax"

# Test 4-8: install scripts syntax
for script in generate-age-key create-environments reinit-secrets edit-secrets setup-env-wrapper; do
    if bash -n "scripts/install/${script}.sh" 2>&1; then
        pass "${script}.sh syntax"
    else
        fail "${script}.sh syntax"
    fi
done

# Test 9: ensure-secrets.sh syntax
bash -n scripts/install/ensure-secrets.sh 2>&1 && pass "ensure-secrets.sh syntax" || fail "ensure-secrets.sh syntax"

# Test 10: ensure-secrets stdout is reserved for the temporary file path
if grep -q 'log_step "Verificando secrets para entorno: \${env}" >&2' scripts/install/ensure-secrets.sh \
    && grep -q 'report_empty_fields "\${secrets_tmp}" >&2' scripts/install/ensure-secrets.sh; then
    pass "ensure-secrets stdout contract"
else
    fail "ensure-secrets stdout contract"
fi

# Test 11: all router scripts pass bash -n
router_ok=true
for f in scripts/router/*.sh; do
    bash -n "$f" 2>&1 || router_ok=false
done
$router_ok && pass "all router scripts syntax" || fail "all router scripts syntax"

# Test 12: router_load_env present in all router scripts
missing_env=""
for f in scripts/router/*.sh; do
    grep -q 'router_load_env' "$f" || missing_env="$missing_env $(basename "$f")"
done
if [ -z "$missing_env" ]; then
    pass "all router scripts use router_load_env"
else
    fail "router_load_env missing in:$missing_env"
fi

# Test 13: no isolated accept-new (all have UserKnownHostsFile)
bad_ssh=$(grep -rn 'StrictHostKeyChecking=accept-new' scripts/router/*.sh 2>/dev/null | grep -v 'UserKnownHostsFile' || true)
if [ -z "$bad_ssh" ]; then
    pass "all accept-new coupled with UserKnownHostsFile"
else
    fail "isolated accept-new found"
fi

# Test 14: no _CLI_IP references remain
if grep -rq '\b_CLI_IP\b' scripts/router/*.sh 2>/dev/null; then
    fail "_CLI_IP references still present"
else
    pass "no _CLI_IP references remain"
fi

# Test 15: no ENV_FILE in router scripts
if grep -rq 'ENV_FILE=' scripts/router/*.sh 2>/dev/null; then
    fail "ENV_FILE references still present in router/"
else
    pass "no ENV_FILE references in router/"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
