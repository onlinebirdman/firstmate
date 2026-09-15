#!/usr/bin/env bash
# fm-codebuddy-usage.sh - read-only CodeBuddy usage fact source.
#
# Summary
#   Reports CodeBuddy (codebuddy / cbc) credit usage from the `opencli codebuddy`
#   account library, in two shapes: a human `show` view and a machine `quota`
#   fragment that matches the quota-axi schemaVersion 5 provider contract.
#
# Responsibilities
#   - `show [--json]` renders the account library's plan/bonus credits and the
#     current CLI account, or emits the raw collected JSON.
#   - `quota` prints `{schemaVersion:5, providers:[{provider:"codebuddy", ...}]}`
#     so firstmate's quota consumers can treat CodeBuddy like any other provider.
#   - The percent is derived from the account library's own numbers
#     (totalRemain / summed plan+bonus allotment x 100); nothing is invented.
#
# Boundaries (what this file does NOT do)
#   - It renders no routing verdict and selects nothing: it takes no harness,
#     model, or candidate, and never decides dispatch eligibility.
#   - It never writes: `opencli codebuddy scan|use|account-remove` are never
#     invoked, and ~/.codebuddy/settings.json is never modified.
#   - It does not own quota-axi; CodeBuddy is a surface quota-axi does not model.
#
# Exposed API
#   fm-codebuddy-usage.sh show [--json]
#   fm-codebuddy-usage.sh quota
#   fm-codebuddy-usage.sh --help
#
# Constraints and notes
#   - The argv issued to `opencli` is fixed in this file and never composed from
#     caller input; stdin is closed and every call is hard-bounded.
#   - `opencli` writes a Node TLS warning to stderr, so only stdout is parsed.
#   - `quota` never fabricates a number: an absent `opencli`, a failed call, or an
#     unmeasurable account yields a valid `status:"unknown"` provider fragment and
#     still exits 0, so consumers read disclosed uncertainty rather than an error.
#   - `show` exits 1 when `opencli` is not on PATH, because there is nothing to
#     render; `quota` is the safe machine path and exits 0 with unknown.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

die_usage() {
  printf 'fm-codebuddy-usage: %s\n' "$1" >&2
  printf 'usage: fm-codebuddy-usage.sh show [--json] | quota\n' >&2
  exit 2
}

# A non-positive bound is not a bound, the same floor rule the vendor probe uses.
TIMEOUT=${FM_CODEBUDDY_USAGE_TIMEOUT:-20}
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=20 ;;
esac

CMD=
AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    show) CMD=show; shift ;;
    quota) CMD=quota; shift ;;
    --json) AS_JSON=1; shift ;;
    -*) die_usage "unknown option: $1" ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$CMD" ] || usage

command -v jq >/dev/null 2>&1 || { printf 'fm-codebuddy-usage: jq not found\n' >&2; exit 1; }

# Bounded execution is owned by bin/fm-timeout-lib.sh, matching the vendor probe.
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$FM_ROOT/bin/fm-timeout-lib.sh"

# opencli_sub <args...> - run one fixed `opencli codebuddy` read command and echo
# its stdout. Nonzero means the command failed or the bound was hit; raw output is
# never echoed on failure.
opencli_sub() {
  local output
  output=$(fm_run_timed "$TIMEOUT" opencli codebuddy "$@" -f json 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$output"
}

# collect - echo a single JSON object {current, accounts, plans} or fail.
# `current` is the alias the CLI token points at; null when it cannot be proven.
collect() {
  local accounts plans current
  accounts=$(opencli_sub accounts) || return 1
  plans=$(opencli_sub usage) || return 1
  current=$(opencli_sub current 2>/dev/null || true)
  printf '%s\n' "$accounts" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s\n' "$plans" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  jq -cn --argjson accounts "$accounts" --argjson plans "$plans" --argjson current "${current:-null}" '
    (if ($current | type) == "array" then ($current[0] // {}) else {} end) as $c |
    {
      current: (($c.alias // null) | if . == "" then null else . end),
      currentMatched: ($c.matched // false),
      accounts: $accounts,
      plans: $plans
    }
  '
}

# render_show <collected-json> - human view: one line per account, current marked.
render_show() {
  local collected=$1
  printf '%s\n' "$collected" | jq -r '
    .current as $cur |
    "codebuddy accounts:",
    ( .accounts[]? |
      ( if .alias == $cur then "  * " else "    " end ) +
      (.alias // "?") + "  " +
      ((.nickname // "-") | tostring) + "  " +
      ((.subscription // "-") | tostring) + "  " +
      "plan=" + ((.planRemain // 0) | tostring) + " " +
      "bonus=" + ((.bonusRemain // 0) | tostring) + " " +
      "total=" + ((.totalRemain // 0) | tostring) + " " +
      "nextExpiry=" + ((.nextExpiry // "-") | tostring) +
      ( if (.status // "ok") == "ok" then "" else "  status=" + (.status|tostring) + " error=" + ((.error // "-")|tostring) end )
    ),
    ("current: " + ($cur // "unknown"))
  '
}

# quota_fragment <collected-json> - schemaVersion 5 provider fragment.
# Derives effectivePercentRemaining for the current account from its own
# totalRemain over the summed plan+bonus allotment. An unmeasurable account is a
# valid status:"unknown" provider, never a fabricated number.
quota_fragment() {
  local collected=${1:-null}
  printf '%s\n' "$collected" | jq -c '
    def known_fragment($pct; $runway; $resets):
      {schemaVersion: 5, providers: [{
        provider: "codebuddy",
        quotaSemantics: {
          status: "known",
          effectiveAvailability: (
            [{scope: "all_products", status: "known", effectivePercentRemaining: $pct,
              runway: {status: $runway}, resetsAt: $resets, limitedBy: "credits"}]
          )
        }
      }]};
    def unknown_fragment:
      {schemaVersion: 5, providers: [{provider: "codebuddy",
        quotaSemantics: {status: "unknown", effectiveAvailability: []}}]};
    if (.accounts | type) != "array" or (.plans | type) != "array" then unknown_fragment
    else
      .current as $cur |
      ([.accounts[]? | select(.alias == $cur)] | first) as $acct |
      if ($acct // null) == null then unknown_fragment
      else
        ([.plans[]? | select(.alias == $cur and (.total // 0) > 0) | (.total // 0)] | add // 0) as $allot |
        (($acct.totalRemain // 0) | tonumber) as $remain |
        if $allot <= 0 then unknown_fragment
        else
          ([((($remain / $allot) * 100) | if . > 100 then 100 elif . < 0 then 0 else . end) * 100 | round / 100] | first) as $pct |
          if $remain <= 0 then
            known_fragment(0; "exhausted_now"; ($acct.cycleEnd // ""))
          else
            known_fragment($pct; "through_reset"; ($acct.cycleEnd // ""))
          end
        end
      end
    end
  '
}

case "$CMD" in
  show)
    command -v opencli >/dev/null 2>&1 || { printf 'fm-codebuddy-usage: opencli not found on PATH\n' >&2; exit 1; }
    collected=$(collect) || { printf 'fm-codebuddy-usage: opencli codebuddy read failed\n' >&2; exit 1; }
    if [ "$AS_JSON" -eq 1 ]; then
      printf '%s\n' "$collected" | jq .
    else
      render_show "$collected"
    fi
    ;;
  quota)
    collected=
    if command -v opencli >/dev/null 2>&1; then
      collected=$(collect 2>/dev/null) || collected=
    fi
    if [ -n "$collected" ]; then
      quota_fragment "$collected"
    else
      printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"codebuddy","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}'
    fi
    ;;
  *) usage ;;
esac
