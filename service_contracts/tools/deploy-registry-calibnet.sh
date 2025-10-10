#!/bin/bash
# deploy-registry-calibnet deploys the Service Provider Registry contract to calibration net
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the calibnet.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#

echo "Deploying Service Provider Registry Contract"

export CHAIN=314159

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

# Optional: Check if PASSWORD is set (some users might use empty password)
if [ -z "$PASSWORD" ]; then
  echo "Warning: PASSWORD is not set, using empty password"
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"

# Get current balance and nonce (cast will use ETH_RPC_URL)
BALANCE=$(cast balance "$ADDR")
echo "Deployer balance: $BALANCE"

NONCE="$(cast nonce "$ADDR")"
echo "Starting nonce: $NONCE"

# Deploy ServiceProviderRegistry implementation
echo ""
echo "=== STEP 1: Deploying ServiceProviderRegistry Implementation ==="
REGISTRY_IMPLEMENTATION_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/ServiceProviderRegistry.sol:ServiceProviderRegistry --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
  echo "Error: Failed to extract ServiceProviderRegistry implementation address"
  exit 1
fi
echo "✓ ServiceProviderRegistry implementation deployed at: $REGISTRY_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Deploy ServiceProviderRegistry proxy
echo ""
echo "=== STEP 2: Deploying ServiceProviderRegistry Proxy ==="
# Initialize with no parameters for basic initialization
INIT_DATA=$(cast calldata "initialize()")
echo "Initialization calldata: $INIT_DATA"

REGISTRY_PROXY_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $REGISTRY_IMPLEMENTATION_ADDRESS $INIT_DATA --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: Failed to extract ServiceProviderRegistry proxy address"
  exit 1
fi
echo "✓ ServiceProviderRegistry proxy deployed at: $REGISTRY_PROXY_ADDRESS"

# Verify deployment by calling version() on the proxy
echo ""
echo "=== STEP 3: Verifying Deployment ==="
VERSION=$(cast call $REGISTRY_PROXY_ADDRESS "version()(string)")
if [ -z "$VERSION" ]; then
  echo "Warning: Could not verify contract version"
else
  echo "✓ Contract version: $VERSION"
fi

# Get registration fee
FEE=$(cast call $REGISTRY_PROXY_ADDRESS "REGISTRATION_FEE()(uint256)")
if [ -z "$FEE" ]; then
    echo "Warning: Could not retrieve registration fee"
    FEE_IN_FIL="unknown"
else
    echo "✓ Registration fee: $FEE attoFIL"
    FEE_IN_FIL="$FEE attoFIL"
fi

# Get burn actor address
BURN_ACTOR=$(cast call $REGISTRY_PROXY_ADDRESS "BURN_ACTOR()(address)")
if [ -z "$BURN_ACTOR" ]; then
  echo "Warning: Could not retrieve burn actor address"
else
  echo "✓ Burn actor address: $BURN_ACTOR"
fi

# Get contract version (this should be used instead of hardcoded version)
CONTRACT_VERSION=$(cast call --rpc-url "$RPC_URL" $REGISTRY_PROXY_ADDRESS "VERSION()(string)")
if [ -z "$CONTRACT_VERSION" ]; then
    echo "Warning: Could not retrieve contract version"
    CONTRACT_VERSION="Unknown"
fi

# Get contract version (this should be used instead of hardcoded version)
CONTRACT_VERSION=$(cast call --rpc-url "$RPC_URL" $REGISTRY_PROXY_ADDRESS "VERSION()(string)")
if [ -z "$CONTRACT_VERSION" ]; then
    echo "Warning: Could not retrieve contract version"
    CONTRACT_VERSION="Unknown"
fi

# Summary of deployed contracts
echo ""
echo "=========================================="
echo "=== DEPLOYMENT SUMMARY ==="
echo "=========================================="
echo "ServiceProviderRegistry Implementation: $REGISTRY_IMPLEMENTATION_ADDRESS"
echo "ServiceProviderRegistry Proxy: $REGISTRY_PROXY_ADDRESS"
echo "=========================================="
echo ""
echo "Contract Details:"
echo "  - Version: $CONTRACT_VERSION"
echo "  - Registration Fee: $FEE_IN_FIL (burned)"
echo "  - Burn Actor: $BURN_ACTOR"
echo "  - Chain: Calibration testnet (314159)"
echo ""
echo "Next steps:"
echo "1. Save the proxy address: export REGISTRY_ADDRESS=$REGISTRY_PROXY_ADDRESS"
echo "2. Verify the deployment by calling getProviderCount() - should return 0"
echo "3. Test registration with: cast send --value <registration_fee>attoFIL ..."
echo "4. Transfer ownership if needed using transferOwnership()"
echo "5. The registry is ready for provider registrations"
echo ""
echo "To interact with the registry:"
echo "  View functions:"
echo "    cast call $REGISTRY_PROXY_ADDRESS \"getProviderCount()(uint256)\""
echo "    cast call $REGISTRY_PROXY_ADDRESS \"getAllActiveProviders()(uint256[])\""
echo "  State changes (requires registration fee):"
echo "    Register as provider (requires proper encoding of PDPData)"
echo ""

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source tools/verify-contracts.sh
  verify_contracts_batch "$REGISTRY_IMPLEMENTATION_ADDRESS,src/ServiceProviderRegistry.sol:ServiceProviderRegistry"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
echo "=========================================="
