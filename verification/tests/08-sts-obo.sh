#!/bin/bash
TEST_NAME=08-sts-obo; . "$(dirname "$0")/lib.sh"
STS=http://localhost:17777; pgrep -f "port-forward.*enterprise-agentgateway 17777" >/dev/null || { kubectl port-forward -n agentgateway-system svc/enterprise-agentgateway 17777:7777 >/dev/null 2>&1 & sleep 3; }
TE=urn:ietf:params:oauth:grant-type:token-exchange; JWTT=urn:ietf:params:oauth:token-type:jwt
A1=$(kubectl create token agent-runtime -n authtest --duration=1h); A2=$(kubectl create token agent-two -n authtest --duration=1h)
log "actor1 sub: $(jwtclaims $A1 | jq -r .sub) ; actor2 sub: $(jwtclaims $A2 | jq -r .sub)"
xchg() { curl -s -X POST $STS/oauth2/token -d grant_type=$TE "$@"; }
# --- Impersonation: subject only (local-minted user JWT, no may_act)
U=$(mint '{"sub":"alice","role":"admin","scope":"mcp:invoke"}')
R=$(xchg -d "subject_token=$U" -d subject_token_type=$JWTT -d audience=mcp-tool-server); T=$(echo "$R" | jq -r .access_token)
if [ "$T" != null ] && [ -n "$T" ]; then PASS=$((PASS+1)); log "PASS impersonation: exchanged token issued; claims=$(jwtclaims $T | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL impersonation: $R"; fi
log "-- impersonation response meta: $(echo "$R" | jq -c '{issued_token_type, token_type, expires_in, scope}')"
# --- Delegation: subject (with may_act) + actor
U=$(mint '{"sub":"alice","role":"admin","scope":"mcp:invoke","may_act":{"sub":"system:serviceaccount:authtest:agent-runtime"}}')
R=$(xchg -d "subject_token=$U" -d subject_token_type=$JWTT -d "actor_token=$A1" -d actor_token_type=$JWTT -d audience=mcp-tool-server); T1=$(echo "$R" | jq -r .access_token)
if [ "$T1" != null ] && [ -n "$T1" ]; then PASS=$((PASS+1)); log "PASS delegation hop1: claims=$(jwtclaims $T1 | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL delegation hop1: $R"; fi
# --- Delegation with wrong actor (may_act mismatch)
R=$(xchg -d "subject_token=$U" -d subject_token_type=$JWTT -d "actor_token=$A2" -d actor_token_type=$JWTT); if echo "$R" | jq -e '.error' >/dev/null; then PASS=$((PASS+1)); log "PASS may_act mismatch rejected: $(echo "$R" | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL may_act mismatch accepted: $(jwtclaims $(echo "$R" | jq -r .access_token))"; fi
# --- Delegation without may_act in subject
U0=$(mint '{"sub":"alice"}'); R=$(xchg -d "subject_token=$U0" -d subject_token_type=$JWTT -d "actor_token=$A1" -d actor_token_type=$JWTT); log "-- actor but no may_act: $(echo "$R" | jq -c '{error, error_description, has_token: (.access_token!=null)}')"
# --- Nested hop2: subject = hop1 token, actor = agent-two ; may_act list variant
UL=$(mint '{"sub":"alice","may_act":{"sub":["system:serviceaccount:authtest:agent-runtime","system:serviceaccount:authtest:agent-two"]}}')
R=$(xchg -d "subject_token=$UL" -d subject_token_type=$JWTT -d "actor_token=$A1" -d actor_token_type=$JWTT); H1=$(echo "$R" | jq -r .access_token)
R2=$(xchg -d "subject_token=$H1" -d subject_token_type=$JWTT -d "actor_token=$A2" -d actor_token_type=$JWTT); H2=$(echo "$R2" | jq -r .access_token)
if [ "$H2" != null ] && [ -n "$H2" ]; then PASS=$((PASS+1)); log "PASS nested hop2 (may_act list): act=$(jwtclaims $H2 | jq -c .act)"; else FAIL=$((FAIL+1)); log "FAIL hop2: $R2"; fi
R3=$(xchg -d "subject_token=$T1" -d subject_token_type=$JWTT -d "actor_token=$A2" -d actor_token_type=$JWTT); log "-- hop2 with scalar may_act (expect reject): $(echo "$R3" | jq -c '{error, error_description}')"
# --- Keycloak-issued subject (remote validator) with may_act claim from mapper
KT=$(curl -s -X POST $GW/keycloak/realms/authtest/protocol/openid-connect/token -d client_id=agw -d client_secret=agw-secret -d grant_type=password -d username=alice -d password=alice-pw | jq -r .access_token)
R=$(xchg -d "subject_token=$KT" -d subject_token_type=$JWTT -d "actor_token=$A1" -d actor_token_type=$JWTT); T=$(echo "$R" | jq -r .access_token)
if [ "$T" != null ] && [ -n "$T" ]; then PASS=$((PASS+1)); log "PASS keycloak subject delegation: claims=$(jwtclaims $T | jq -c '{iss,sub,aud,act,scope,role,tier}')"; else FAIL=$((FAIL+1)); log "FAIL keycloak subject: $R"; fi
log "-- STS jwks kid(s): $(curl -s $STS/.well-known/jwks.json | jq -c '[.keys[].kid]')"
summary
