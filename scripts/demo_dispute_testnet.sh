#!/usr/bin/env bash
#
# End-to-end dispute demo on testnet: freeze an escrow, raise a dispute, have the
# arbitrator panel approve a split, and arbitrate it to resolution.
#
# This is the counterpart to scripts/demo_testnet.sh, which only walks the happy
# path (create → fund → release → rate → aggregate). The flow exercised here is
# the one documented in docs/DISPUTES.md:
#
#   escrow.open_dispute → dispute.raise → dispute.approve → dispute.arbitrate
#     → escrow.resolve (cross-called by arbitrate) → escrow status Completed
#
# It asserts the outcome rather than only printing it, so a regression in the
# dispute path (a changed argument name, a broken cross-call, a share check that
# no longer lines up with the funds held) fails the run.
#
# Usage:
#   scripts/deploy_testnet.sh          # once, to deploy + initialize
#   scripts/demo_dispute_testnet.sh    # then run this
#
# Environment variables:
#   NETWORK            – stellar network (default: testnet)
#   IDENTITY           – funded identity used as the client (default: deployer);
#                        it must also be a member of the arbitrator panel, which
#                        is how scripts/deploy_testnet.sh initializes the
#                        dispute contract (panel = [admin], threshold = 1).
#   FREELANCER_IDENTITY – identity name generated for the freelancer
#                        (default: freelancer)
#   ARBITRATOR         – panel member that approves the split (default: the
#                        `admin` recorded in deployments/testnet.json)
#   TOKEN_CONTRACT_ID  – SAC to pay with. Defaults to the testnet XLM SAC so the
#                        demo runs without needing Circle testnet USDC.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOYMENTS="$REPO_ROOT/deployments/testnet.json"

NETWORK="${NETWORK:-testnet}"
IDENTITY="${IDENTITY:-deployer}"
FREELANCER_IDENTITY="${FREELANCER_IDENTITY:-freelancer}"

[ -f "$DEPLOYMENTS" ] || {
  echo "error: $DEPLOYMENTS not found. Run scripts/deploy_testnet.sh first." >&2
  exit 1
}

json() { grep -oE "\"$1\": *\"[^\"]*\"" "$DEPLOYMENTS" | sed -E 's/.*: *"([^"]*)"/\1/'; }

ESCROW="$(json escrow_contract_id)"
DISPUTE="$(json dispute_contract_id)"
CONTRACT_USDC="$(json usdc_contract_id)"
ADMIN="$(json admin)"

CLIENT="$(stellar keys address "$IDENTITY")"
ARBITRATOR="${ARBITRATOR:-$ADMIN}"

if ! stellar keys address "$FREELANCER_IDENTITY" >/dev/null 2>&1; then
  echo "==> Generating + funding freelancer identity '$FREELANCER_IDENTITY'"
  stellar keys generate "$FREELANCER_IDENTITY" --network "$NETWORK" --fund
fi
FREELANCER="$(stellar keys address "$FREELANCER_IDENTITY")"

TOKEN="${TOKEN_CONTRACT_ID:-$CONTRACT_USDC}"
if [ -z "$TOKEN" ]; then
  TOKEN="$(stellar contract id asset --asset native --network "$NETWORK")"
  echo "==> No USDC configured; using testnet XLM SAC: $TOKEN"
fi

EXPIRY=$(( $(date +%s) + 3600 ))
# 1 XLM / 0.1 XLM in stroops, as a Vec<Milestone> JSON argument.
# Amount (i128) is encoded as a string; deadline (u64) as a number.
MILESTONES='[{"amount":"10000000","deadline":0,"released":false,"released_amount":"0"},{"amount":"1000000","deadline":0,"released":false,"released_amount":"0"}]'

# The split the panel will approve. `escrow.resolve` requires the two shares to
# sum *exactly* to the funds still held, so these must add up to the total of the
# milestone list above (11 000 000 stroops) — nothing is released in this demo.
TOTAL=11000000
CLIENT_SHARE=3000000
FREELANCER_SHARE=8000000
[ $((CLIENT_SHARE + FREELANCER_SHARE)) -eq "$TOTAL" ] || {
  echo "error: the dispute split must sum to the funds held ($TOTAL stroops)" >&2
  exit 1
}

invoke() { stellar contract invoke --id "$1" --source "$IDENTITY" --network "$NETWORK" -- "${@:2}"; }

echo "==> create"
ESCROW_ID="$(invoke "$ESCROW" create \
  --client "$CLIENT" \
  --freelancer "$FREELANCER" \
  --token "$TOKEN" \
  --milestones "$MILESTONES" \
  --expiry "$EXPIRY" | tail -1)"
echo "    escrow id: $ESCROW_ID"

echo "==> fund"
invoke "$ESCROW" fund --escrow_id "$ESCROW_ID"

# Step 1 of docs/DISPUTES.md: either party freezes the escrow.
echo "==> open_dispute (escrow Active → Disputed)"
invoke "$ESCROW" open_dispute --escrow_id "$ESCROW_ID" --initiator "$CLIENT"

# Step 2: raise the dispute. `raise` cross-checks that the escrow is Disputed and
# that raised_by is a party, then returns the on-chain dispute id.
echo "==> dispute.raise"
DISPUTE_ID="$(invoke "$DISPUTE" raise \
  --escrow_id "$ESCROW_ID" \
  --escrow_contract "$ESCROW" \
  --raised_by "$CLIENT" \
  --reason "Milestone one was never delivered" | tail -1)"
echo "    dispute id: $DISPUTE_ID"

# Step 3: the panel approves a specific split. The contract's threshold is 1 for
# the default deployment, so one approval is enough — every panel member would
# call `approve` with the same shares for an N-of-N panel.
echo "==> dispute.approve (panel member: $ARBITRATOR)"
invoke "$DISPUTE" approve \
  --dispute_id "$DISPUTE_ID" \
  --arbitrator "$ARBITRATOR" \
  --client_share "$CLIENT_SHARE" \
  --freelancer_share "$FREELANCER_SHARE"

# Step 4: arbitrate. Counts approvals for exactly this split, then cross-calls
# escrow.resolve, which pays out and moves the escrow to Completed.
echo "==> dispute.arbitrate (split: client $CLIENT_SHARE / freelancer $FREELANCER_SHARE)"
invoke "$DISPUTE" arbitrate \
  --dispute_id "$DISPUTE_ID" \
  --client_share "$CLIENT_SHARE" \
  --freelancer_share "$FREELANCER_SHARE"

echo "==> escrow.get (expect status Completed)"
ESCROW_STATE="$(invoke "$ESCROW" get --escrow_id "$ESCROW_ID")"
echo "$ESCROW_STATE"
if ! grep -q "Completed" <<<"$ESCROW_STATE"; then
  echo "error: arbitration left the escrow in an unexpected state (expected Completed)" >&2
  exit 1
fi

echo "==> dispute.get (expect status Resolved)"
DISPUTE_STATE="$(invoke "$DISPUTE" get --dispute_id "$DISPUTE_ID")"
echo "$DISPUTE_STATE"
if ! grep -q "Resolved" <<<"$DISPUTE_STATE"; then
  echo "error: the dispute did not reach Resolved" >&2
  exit 1
fi

echo "==> Done. Dispute $DISPUTE_ID resolved; funds split client=$CLIENT_SHARE freelancer=$FREELANCER_SHARE."
