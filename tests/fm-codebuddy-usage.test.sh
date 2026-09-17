#!/usr/bin/env bash
# Behavior tests for bin/fm-codebuddy-usage.sh - the read-only CodeBuddy usage
# fact source that feeds firstmate's quota snapshot.
#
# What this suite pins:
#
# 1. The `quota` fragment must be a valid schemaVersion 5 provider document, so
#    fm-quota-choose.sh and fm-procevent-quota.sh can consume CodeBuddy like any
#    other provider. It is validated here with fm_quota_json_valid, the one owner
#    of that schema.
# 2. The percent must come from the account library's own numbers
#    (totalRemain / summed plan+bonus allotment), never a fabricated figure, and
#    zero credits must read as exhausted_now.
# 3. An absent `opencli` or an unmeasurable account must be disclosed uncertainty
#    (status:"unknown", exit 0), never a made-up number or a hard failure of the
#    machine path.
# 4. The script never writes: no `opencli codebuddy scan|use|account-remove` may
#    run. The fake opencli records every argv, so this is an observable fact.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codebuddy-usage-tests)
SCRIPT="$ROOT/bin/fm-codebuddy-usage.sh"

# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$ROOT/bin/fm-quota-axi-lib.sh"

# make_fake_opencli <case-dir> - write a fake `opencli` that answers the three
# read subcommands used by the script and logs every invocation's argv. Behavior
# is selected by FM_FAKE_CB_MODE: normal (100/200 credits), zero, nomatch.
make_fake_opencli() {
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/opencli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_OPENCLI_LOG"
sub=
for a in "$@"; do
  case "$a" in accounts|usage|current|scan|use|account-remove) sub=$a ;; esac
done
mode=${FM_FAKE_CB_MODE:-normal}
case "$sub" in
  accounts)
    printf '%s\n' '[{"alias":"a1","nickname":"tester","uin":"1","subscription":"plan-x","planRemain":50,"bonusRemain":50,"totalRemain":100,"nextExpiry":"2030-01-01 00:00:00","expiringCredits":0,"cycleEnd":"2030-01-31 00:00:00","status":"ok","error":""}]'
    ;;
  usage)
    printf '%s\n' '[{"alias":"a1","category":"plan","packageName":"plan-x","total":200,"remain":100,"unit":"credits","usagePct":50,"expiresAt":"2030-01-31 00:00:00","cycleEnd":"2030-01-31 00:00:00","status":"ok"}]'
    ;;
  current)
    case "$mode" in
      nomatch) printf '%s\n' '[{"alias":"zzz","matched":false}]' ;;
      *) printf '%s\n' '[{"alias":"a1","matched":true}]' ;;
    esac
    ;;
esac
SH
  chmod +x "$fakebin/opencli"
  printf '%s\n' "$fakebin"
}

# A zero-credit account library: same alias, totalRemain 0.
make_fake_opencli_zero() {
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/opencli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_OPENCLI_LOG"
sub=
for a in "$@"; do
  case "$a" in accounts|usage|current) sub=$a ;; esac
done
case "$sub" in
  accounts) printf '%s\n' '[{"alias":"a1","nickname":"tester","uin":"1","subscription":"plan-x","planRemain":0,"bonusRemain":0,"totalRemain":0,"nextExpiry":"2030-01-01 00:00:00","expiringCredits":0,"cycleEnd":"2030-01-31 00:00:00","status":"ok","error":""}]' ;;
  usage)    printf '%s\n' '[{"alias":"a1","category":"plan","packageName":"plan-x","total":200,"remain":0,"unit":"credits","usagePct":100,"expiresAt":"2030-01-31 00:00:00","cycleEnd":"2030-01-31 00:00:00","status":"ok"}]' ;;
  current)  printf '%s\n' '[{"alias":"a1","matched":true}]' ;;
esac
SH
  chmod +x "$fakebin/opencli"
  printf '%s\n' "$fakebin"
}

# run_case <case-dir> <path> <log> [mode] -- <args...>
run_case() {
  local case_dir=$1 path=$2 log=$3 mode=${4:-normal}
  shift 4
  : > "$log"
  RUN_OUT=$(env "PATH=$path" "FM_FAKE_OPENCLI_LOG=$log" "FM_FAKE_CB_MODE=$mode" \
    "$SCRIPT" "$@" 2>/dev/null) || RUN_RC=$?
  RUN_RC=${RUN_RC:-0}
}

assert_no_writes() {  # <log> <label>
  if grep -Eq '(^| )(scan|use|account-remove)( |$)' "$1"; then
    fail "$2: a write subcommand was invoked: $(tr '\n' '|' < "$1")"
  fi
}

# --- 1. normal: valid fragment with the computed percent --------------------

CASE="$TMP_ROOT/normal"
mkdir -p "$CASE"
fakebin=$(make_fake_opencli "$CASE")
log="$CASE/opencli.log"
RUN_RC=0
run_case "$CASE" "$fakebin:$PATH" "$log" normal quota
expect_code 0 "$RUN_RC" "quota should exit 0 on a measurable account"
printf '%s\n' "$RUN_OUT" | fm_quota_json_valid || fail "quota fragment is not a valid schemaVersion 5 document"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].provider')" = codebuddy ] || fail "provider must be codebuddy"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].scope')" = all_products ] || fail "scope must be all_products"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining')" = 50 ] \
  || fail "percent must be totalRemain 100 over allotment 200 (got $(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining'))"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].runway.status')" = through_reset ] \
  || fail "nonzero credits must read through_reset"
assert_no_writes "$log" "quota normal"
pass "quota emits a valid codebuddy fragment with the account's own numbers and performs no write"

# --- 2. zero credits: exhausted_now -----------------------------------------

CASE="$TMP_ROOT/zero"
mkdir -p "$CASE"
fakebin_zero=$(make_fake_opencli_zero "$CASE")
log="$CASE/opencli.log"
RUN_RC=0
run_case "$CASE" "$fakebin_zero:$PATH" "$log" normal quota
expect_code 0 "$RUN_RC" "quota should exit 0 on a zero-credit account"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining')" = 0 ] \
  || fail "zero credits must report 0"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].runway.status')" = exhausted_now ] \
  || fail "zero credits must read exhausted_now"
printf '%s\n' "$RUN_OUT" | fm_quota_json_valid || fail "zero-credit fragment must still validate"
pass "zero credits read as exhausted_now and the fragment still validates"

# --- 3. opencli absent: disclosed uncertainty, not a failure -----------------

CASE="$TMP_ROOT/no-opencli"
mkdir -p "$CASE"
log="$CASE/opencli.log"
sans=$(fm_test_base_path_sans "$PATH" opencli)
RUN_RC=0
run_case "$CASE" "$sans" "$log" normal quota
expect_code 0 "$RUN_RC" "quota must exit 0 when opencli is absent (machine path, disclosed uncertainty)"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.status')" = unknown ] \
  || fail "absent opencli must be status:unknown"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.effectiveAvailability | length')" = 0 ] \
  || fail "unknown provider must carry no availability entry"
printf '%s\n' "$RUN_OUT" | fm_quota_json_valid || fail "unknown fragment must still validate"
pass "absent opencli is a valid status:unknown fragment, never a fabricated number"

# --- 4. current account not in the library: unknown -------------------------

CASE="$TMP_ROOT/nomatch"
mkdir -p "$CASE"
fakebin_nm=$(make_fake_opencli "$CASE")
log="$CASE/opencli.log"
RUN_RC=0
run_case "$CASE" "$fakebin_nm:$PATH" "$log" nomatch quota
expect_code 0 "$RUN_RC" "quota should exit 0 when the current account is unmeasurable"
[ "$(printf '%s\n' "$RUN_OUT" | jq -r '.providers[0].quotaSemantics.status')" = unknown ] \
  || fail "an unmatched current account must be status:unknown"
pass "an unmatched current account is disclosed uncertainty, not a guess"

# --- 5. show renders the library and marks the current account --------------

CASE="$TMP_ROOT/show"
mkdir -p "$CASE"
fakebin_show=$(make_fake_opencli "$CASE")
log="$CASE/opencli.log"
RUN_RC=0
run_case "$CASE" "$fakebin_show:$PATH" "$log" normal show
expect_code 0 "$RUN_RC" "show should exit 0 with opencli present"
assert_contains "$RUN_OUT" "current: a1" "show must print the inferred current account"
assert_contains "$RUN_OUT" "* a1" "show must mark the current account"
assert_no_writes "$log" "show"
pass "show renders the account library, marks the current account, and performs no write"

# --- 6. usage error handling ------------------------------------------------

RUN_RC=0
"$SCRIPT" -h >/dev/null 2>&1 || RUN_RC=$?
expect_code 2 "$RUN_RC" "help must exit 2 like the other firstmate helpers"
RUN_RC=0
"$SCRIPT" bogus >/dev/null 2>&1 || RUN_RC=$?
expect_code 2 "$RUN_RC" "an unknown argument must be a usage error"
pass "usage errors exit 2"
