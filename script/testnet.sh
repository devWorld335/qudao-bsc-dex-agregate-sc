#!/usr/bin/env bash
# Qudao on BSC testnet. Keys come from .secrets/testnet.env (throwaway testnet keys, never printed).
#   contracts/script/testnet.sh status            balances of the testnet accounts
#   contracts/script/testnet.sh deploy            fund admin + keeper from the deployer, deploy everything
#   contracts/script/testnet.sh setup [token]     set a flap.sh testnet token as the stand-in QDAO (router, burner, The Well)
#   contracts/script/testnet.sh open [pool] [bnb] open a position with tBNB (default WBNB/USDT 0.05%, 0.02 BNB)
#   contracts/script/testnet.sh push [pool]       move a pool's price to test the keeper
# Set RPC=… to point at a fork instead (e.g. http://127.0.0.1:8546).
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a
. .secrets/testnet.env
set +a
RPC="${RPC:-https://bsc-testnet-rpc.publicnode.com}"
NAME="${NAME:-bsc_testnet}"
DEP="contracts/deployments/$NAME.json"
STAND_IN_QDAO="0x3c225f09960be316e648b43a36621f04fc577777" # ACV, a flap.sh testnet tax token still on its curve
WBNB_USDT="0x2dbB5a4c235164B9f772179A43faca2c71a8abDB"

bal() { cast balance "$1" --ether --rpc-url "$RPC"; }
need() { # need <address> <min tBNB>
  local b; b=$(bal "$1")
  python3 -c "import sys; sys.exit(0 if float('$b') >= float('$2') else 1)" || { echo "$1 has $b tBNB, needs at least $2"; exit 1; }
}

case "${1:-status}" in
  status)
    for r in DEPLOYER ADMIN KEEPER TEAM; do a="TESTNET_${r}_ADDRESS"; printf "%-9s %s  %s tBNB\n" "$r" "${!a}" "$(bal "${!a}")"; done
    [ -f "$DEP" ] && echo "deployed: factory $(jq -r .factory "$DEP") (block $(jq -r .block "$DEP"))" || echo "not deployed yet ($DEP)"
    ;;
  deploy)
    [ -f "$DEP" ] && { echo "$DEP already exists: delete it first to redeploy"; exit 1; }
    need "$TESTNET_DEPLOYER_ADDRESS" 0.1
    [ "$(cast chain-id --rpc-url "$RPC")" = 97 ] || { echo "RPC is not BSC testnet"; exit 1; }
    # admin (guardian, launcher, timelock proposer) and keeper need gas
    for r in ADMIN KEEPER; do
      a="TESTNET_${r}_ADDRESS"
      python3 -c "import sys; sys.exit(0 if float('$(bal "${!a}")') >= 0.02 else 1)" ||
        cast send "${!a}" --value 0.03ether --private-key "$TESTNET_DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
    done
    (cd contracts && QUDAO_CHAIN=bsc_testnet QUDAO_ADMIN_SAFE="$TESTNET_ADMIN_ADDRESS" QUDAO_TEAM_SAFE="$TESTNET_TEAM_ADDRESS" \
      QUDAO_KEEPER="$TESTNET_KEEPER_ADDRESS" QUDAO_ALLOW_PLACEHOLDERS=true QUDAO_DEPLOYMENT_NAME="$NAME" \
      forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$TESTNET_DEPLOYER_KEY" 2>&1 |
      grep -E "ONCHAIN EXECUTION|Error|error|revert" || true)
    [ -f "$DEP" ] && jq . "$DEP"
    ;;
  setup)
    Q="${2:-$STAND_IN_QDAO}"
    for c in revenueRouter buybackBurner; do
      cast send "$(jq -r ".$c" "$DEP")" "setQdao(address)" "$Q" --private-key "$TESTNET_ADMIN_KEY" --rpc-url "$RPC" | grep -E "^status"
    done
    cast send "$(jq -r .well "$DEP")" "setToken(address)" "$Q" --private-key "$TESTNET_ADMIN_KEY" --rpc-url "$RPC" | grep -E "^status"
    ;;
  open)
    POOL="${2:-$WBNB_USDT}"
    WEI=$(python3 -c "print(int(float('${3:-0.02}') * 10**18))")
    (cd contracts && QUDAO_DEPLOYMENT_FILE="deployments/$NAME.json" POOL="$POOL" BNB="$WEI" HALF_WIDTH="${HALF_WIDTH:-100}" \
      forge script script/TestnetScenario.s.sol --sig "open()" --rpc-url "$RPC" --broadcast --slow --private-key "$TESTNET_DEPLOYER_KEY" 2>&1 |
      grep -E "vault|tokenId|tick|received|Error|revert" || true)
    ;;
  push)
    (cd contracts && QUDAO_DEPLOYMENT_FILE="deployments/$NAME.json" POOL="${2:-$WBNB_USDT}" CHUNK="${CHUNK:-1000000000000000}" PUSH_TICKS="${PUSH_TICKS:-300}" \
      forge script script/TestnetScenario.s.sol --sig "push()" --rpc-url "$RPC" --broadcast --slow --private-key "$TESTNET_DEPLOYER_KEY" 2>&1 |
      grep -E "tick|Error|revert" || true)
    ;;
  *) sed -n 2,9p "$0"; exit 1 ;;
esac
