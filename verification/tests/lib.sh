# shared helpers for auth-pattern tests
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=authtest
export GW_IP=${GW_IP:-$(kubectl get gateway authtest-gw -n authtest -o jsonpath='{.status.addresses[0].value}')}
export GW=http://$GW_IP:8080
PASS=0; FAIL=0
RESULTS=$S/results/${TEST_NAME:-untitled}.txt
: > "$RESULTS"
log() { echo "$*" | tee -a "$RESULTS"; }
# expect <desc> <expected_code> curl-args...
expect() { local d="$1" want="$2"; shift 2; local got; got=$(curl -s -o /tmp/authtest.body -w '%{http_code}' --max-time 20 "$@"); if [ "$got" = "$want" ]; then PASS=$((PASS+1)); log "PASS [$got] $d"; else FAIL=$((FAIL+1)); log "FAIL [got $got want $want] $d :: $(head -c 300 /tmp/authtest.body | tr '\n' ' ')"; fi; }
# expect_body <desc> <grep-pattern> curl-args...
expect_body() { local d="$1" pat="$2"; shift 2; local body; body=$(curl -s --max-time 20 "$@"); if echo "$body" | grep -qE "$pat"; then PASS=$((PASS+1)); log "PASS [body~/$pat/] $d"; else FAIL=$((FAIL+1)); log "FAIL [body !~ /$pat/] $d :: $(echo "$body" | head -c 300 | tr '\n' ' ')"; fi; }
mint() { python3 $S/keys/mint.py "$@"; }
jwtclaims() { python3 -c 'import sys,base64,json; t=sys.argv[1].split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(t+"="*(-len(t)%4)))))' "$1"; }
wait_policy() { # wait_policy <kind> <name> [ns]
  local k=$1 n=$2 ns=${3:-$NS}; for i in $(seq 1 30); do st=$(kubectl get $k $n -n $ns -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' 2>/dev/null); [ "$st" = "True" ] && return 0; sleep 2; done; log "WARN policy $k/$n not Accepted: $(kubectl get $k $n -n $ns -o jsonpath='{.status.conditions}' 2>/dev/null | head -c 400)"; }
settle() { sleep ${1:-4}; }
summary() { log "== $TEST_NAME: PASS=$PASS FAIL=$FAIL"; }
