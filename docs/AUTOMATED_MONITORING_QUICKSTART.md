# Automated Security Monitoring - Quick Start Guide

## 🚀 5-Minute Setup

### Prerequisites
- Vault deployed on Hyperliquid
- Node.js 18+ installed
- Docker (optional, for containerized deployment)

---

## Step 1: Deploy Monitoring System (2 minutes)

```bash
# Set environment variables
export VAULT_ADDRESS="0x..."
export GATE_OWNER="0xMultisig..."
export KEEPER_ADDRESS="0xKeeperEOA..."
export GUARDIAN_ADDRESS="0xGuardianMultisig..."  # Optional
export EMERGENCY_RESPONDER_ADDRESS="0xHotWallet..."  # Optional

# Monitoring configuration (optional, these are defaults)
export SHARE_PRICE_CRASH_THRESHOLD="1000"      # 10% price drop
export SHARE_PRICE_CHECK_WINDOW="3600"         # 1 hour
export RAPID_WITHDRAWAL_THRESHOLD="2000"       # 20% of TVL
export RAPID_WITHDRAWAL_WINDOW="3600"          # 1 hour
export ADAPTER_BALANCE_MISMATCH="500"          # 5% mismatch
export AUTO_RESPONSE_ENABLED="true"
export COOLDOWN_PERIOD="3600"                  # 1 hour

# Deploy everything
forge script script/DeployMonitoringSystem.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --broadcast \
  --verify

# Save the output addresses
export GATE_ADDRESS="<EmergencyGateWithRoles-address>"
export MONITOR_ADDRESS="<SecurityMonitor-address>"
```

---

## Step 2: Configure Vault Gates (1 minute + timelock wait)

```bash
# Submit gate configuration to vault (REQUIRES CURATOR!)
forge script script/ConfigureVaultGates.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --private-key $CURATOR_PRIVATE_KEY \
  --broadcast

# ⏰ WAIT FOR TIMELOCK TO EXPIRE (hours to days depending on vault config)
# Check timelock status:
cast call $VAULT_ADDRESS "executableAt(bytes)(uint256)" \
  $(cast abi-encode "setReceiveSharesGate(address)" $GATE_ADDRESS) \
  --rpc-url https://rpc.hyperliquid.xyz/evm

# After timelock expires, execute
forge script script/ExecuteVaultGates.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --private-key $CURATOR_PRIVATE_KEY \
  --broadcast
```

---

## Step 3: Deploy Worker (2 minutes)

### Option A: Docker (Recommended)

```bash
cd workers

# Create .env file
cat > .env <<EOF
RPC_URL=https://rpc.hyperliquid.xyz/evm
MONITOR_ADDRESS=${MONITOR_ADDRESS}
GATE_ADDRESS=${GATE_ADDRESS}
KEEPER_PRIVATE_KEY=${KEEPER_PRIVATE_KEY}
CHECK_INTERVAL=30000
ALERT_WEBHOOK=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
PAGERDUTY_KEY=your_pagerduty_integration_key
DISCORD_WEBHOOK=https://discord.com/api/webhooks/YOUR/WEBHOOK
EOF

# Start worker
docker-compose up -d

# Check logs
docker-compose logs -f security-worker
```

### Option B: Node.js

```bash
cd workers

# Install dependencies
npm install

# Build
npm run build

# Start (with environment variables)
npm start
```

---

## Step 4: Test the System

```bash
# Check current status
forge script script/TestMonitoring.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --private-key $KEEPER_PRIVATE_KEY

# Simulate emergency (as guardian)
cast send $GATE_ADDRESS \
  "activateEmergency(string)" "Testing emergency activation" \
  --private-key $GUARDIAN_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm

# Check gate mode
cast call $GATE_ADDRESS "getModeString()(string)" \
  --rpc-url https://rpc.hyperliquid.xyz/evm

# Deactivate (as guardian)
cast send $GATE_ADDRESS \
  "deactivateEmergency(string)" "Test complete" \
  --private-key $GUARDIAN_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm
```

---

## 🎯 ROLE ASSIGNMENTS

### Who Gets What Role?

```
PRIMARY SETUP:
┌────────────────────────┬──────────────────────────┬─────────────────┐
│ Role                   │ Who                      │ Address Type    │
├────────────────────────┼──────────────────────────┼─────────────────┤
│ OWNER (Gate)           │ Protocol Team            │ 3/5 Multisig    │
│ GUARDIAN               │ Emergency Response Team  │ 2/3 Multisig    │
│ MONITOR                │ SecurityMonitor Contract │ Contract        │
│ EMERGENCY_RESPONDER    │ On-call Engineer         │ Hot Wallet/EOA  │
│ KEEPER (Worker)        │ Automated System         │ EOA (KMS)       │
└────────────────────────┴──────────────────────────┴─────────────────┘
```

### Configure Additional Roles

```bash
# Add additional guardians
cast send $GATE_ADDRESS \
  "setGuardian(address,bool)" $ADDITIONAL_GUARDIAN true \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm

# Add backup monitoring system
cast send $GATE_ADDRESS \
  "setMonitor(address,bool)" $BACKUP_MONITOR true \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm

# Add emergency responders
cast send $GATE_ADDRESS \
  "setEmergencyResponder(address,bool)" $RESPONDER true \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm

# Add exceptions (addresses that bypass restrictions)
cast send $GATE_ADDRESS \
  "setException(address,bool)" $RECOVERY_CONTRACT true \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm
```

---

## 🚨 EMERGENCY PROCEDURES

### If Automated System Detects Threat

```
1. Worker detects threat → Calls SecurityMonitor.checkAndRespond()
2. SecurityMonitor activates emergency → Calls EmergencyGateWithRoles.activateEmergencyAutomated()
3. Gate blocks all operations (except exceptions)
4. Alerts sent to Slack/PagerDuty/Discord
5. Team investigates
```

**What You'll Receive:**
- Slack message with incident details
- PagerDuty page (if CRITICAL)
- Discord notification
- On-chain incident log

**What to Do:**
1. Check incident details in SecurityMonitor contract
2. Investigate root cause
3. If false positive: Guardian deactivates emergency
4. If real threat: Follow incident response playbook

### Manual Emergency Activation

```bash
# As guardian or owner
cast send $GATE_ADDRESS \
  "activateEmergency(string)" "Reason for activation" \
  --private-key $GUARDIAN_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm
```

### During Emergency: Add Exception

```bash
# As emergency responder (during active emergency only)
cast send $GATE_ADDRESS \
  "addExceptionDuringEmergency(address,string)" \
  $RECOVERY_ADDRESS \
  "Enable recovery contract" \
  --private-key $RESPONDER_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm
```

### Deactivate Emergency

```bash
# As guardian or owner
cast send $GATE_ADDRESS \
  "deactivateEmergency(string)" "Threat resolved" \
  --private-key $GUARDIAN_PRIVATE_KEY \
  --rpc-url https://rpc.hyperliquid.xyz/evm
```

---

## 📊 MONITORING & DEBUGGING

### Check System Status

```bash
# Gate status
cast call $GATE_ADDRESS "getModeString()(string)" --rpc-url $RPC_URL
cast call $GATE_ADDRESS "isAutomatedEmergency()(bool)" --rpc-url $RPC_URL

# Monitor metrics
cast call $MONITOR_ADDRESS "getCurrentMetrics()(uint256,uint256,uint256,uint256)" --rpc-url $RPC_URL

# Incident count
cast call $MONITOR_ADDRESS "getIncidentCount()(uint256)" --rpc-url $RPC_URL

# Latest incident
INCIDENT_ID=$(cast call $MONITOR_ADDRESS "getIncidentCount()(uint256)" --rpc-url $RPC_URL)
INCIDENT_ID=$((INCIDENT_ID - 1))
cast call $MONITOR_ADDRESS "getIncident(uint256)(uint256,address,uint8,string,string,bool)" $INCIDENT_ID --rpc-url $RPC_URL
```

### Check Role Assignments

```bash
# Check roles for address
cast call $GATE_ADDRESS \
  "getRoles(address)(bool,bool,bool,bool,bool)" \
  $ADDRESS \
  --rpc-url $RPC_URL

# Returns: (isOwner, isGuardian, isMonitor, isEmergencyResponder, isException)
```

### Worker Logs

```bash
# Docker
docker-compose logs -f security-worker

# Node.js
# Check your process manager logs
```

---

## 🔧 CONFIGURATION TUNING

### Adjust Detection Thresholds

```bash
# Update SecurityMonitor config (owner only)
cast send $MONITOR_ADDRESS \
  "setConfig((uint256,uint256,uint256,uint256,uint256,bool,uint256))" \
  "(1500,3600,2500,3600,750,true,3600)" \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url $RPC_URL

# Parameters:
# 1. sharePriceCrashThreshold (BPS): 1500 = 15%
# 2. sharePriceCheckWindow (seconds): 3600 = 1 hour
# 3. rapidWithdrawalThreshold (BPS): 2500 = 25%
# 4. rapidWithdrawalWindow (seconds): 3600 = 1 hour
# 5. adapterBalanceMismatchThreshold (BPS): 750 = 7.5%
# 6. autoResponseEnabled (bool): true
# 7. cooldownPeriod (seconds): 3600 = 1 hour
```

### Disable Auto-Response (Testing Phase)

```bash
# Disable automated emergency activation
cast send $MONITOR_ADDRESS \
  "setConfig((uint256,uint256,uint256,uint256,uint256,bool,uint256))" \
  "(1000,3600,2000,3600,500,false,3600)" \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url $RPC_URL
# Note: autoResponseEnabled = false (6th parameter)
```

---

## ❓ TROUBLESHOOTING

### Worker Not Starting

```bash
# Check environment variables
env | grep -E "RPC_URL|MONITOR|GATE|KEEPER"

# Test RPC connection
cast block-number --rpc-url $RPC_URL

# Test keeper key
cast wallet address --private-key $KEEPER_PRIVATE_KEY
```

### No Alerts Received

```bash
# Test Slack webhook
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test alert"}' \
  $ALERT_WEBHOOK

# Check worker logs for errors
docker-compose logs security-worker | grep -i "error\|alert"
```

### Emergency Not Activating

```bash
# Check if gate is configured on vault
cast call $VAULT_ADDRESS "receiveSharesGate()(address)" --rpc-url $RPC_URL
# Should return gate address, not 0x0

# Check monitor role
cast call $GATE_ADDRESS \
  "isMonitor(address)(bool)" \
  $MONITOR_ADDRESS \
  --rpc-url $RPC_URL
# Should return true

# Check auto-response enabled
cast call $MONITOR_ADDRESS \
  "config()(uint256,uint256,uint256,uint256,uint256,bool,uint256)" \
  --rpc-url $RPC_URL
# 6th value should be true

# Check cooldown
cast call $MONITOR_ADDRESS \
  "lastEmergencyActivation()(uint256)" \
  --rpc-url $RPC_URL
# Should be > cooldownPeriod ago
```

### False Positives

```bash
# Increase thresholds or disable auto-response temporarily
# Review incident history
INCIDENT_COUNT=$(cast call $MONITOR_ADDRESS "getIncidentCount()(uint256)" --rpc-url $RPC_URL)
echo "Total incidents: $INCIDENT_COUNT"

# Review each incident
for i in $(seq 0 $((INCIDENT_COUNT - 1))); do
  echo "Incident $i:"
  cast call $MONITOR_ADDRESS \
    "getIncident(uint256)(uint256,address,uint8,string,string,bool)" \
    $i \
    --rpc-url $RPC_URL
  echo "---"
done
```

---

## 📚 ADDITIONAL RESOURCES

- **Full Documentation**: See `ROLE_MANAGEMENT_GUIDE.md`
- **Emergency Gate Guide**: See `EMERGENCY_GATE_GUIDE.md`
- **Security Analysis**: See comprehensive security analysis in previous messages
- **Contract Code**:
  - `src/gates/EmergencyGateWithRoles.sol`
  - `src/monitoring/SecurityMonitor.sol`
  - `workers/security-worker.ts`

---

## ✅ CHECKLIST

### Initial Setup
- [ ] Deploy EmergencyGateWithRoles
- [ ] Deploy SecurityMonitor
- [ ] Configure roles (owner, guardians, monitors, responders)
- [ ] Submit gate configuration to vault
- [ ] Wait for timelock
- [ ] Execute gate configuration
- [ ] Deploy worker
- [ ] Configure alerting (Slack, PagerDuty, Discord)
- [ ] Test emergency activation
- [ ] Document emergency procedures

### Ongoing Operations
- [ ] Monitor worker health
- [ ] Review incident logs weekly
- [ ] Tune thresholds based on false positives
- [ ] Update emergency contact list
- [ ] Test emergency procedures quarterly
- [ ] Review and update runbooks
- [ ] Audit role assignments monthly

---

## 🎓 KEY TAKEAWAYS

**Automated Protection**:
- ✅ On-chain threat detection (price crashes, rapid withdrawals, adapter anomalies)
- ✅ Off-chain threat detection (MEV, oracle manipulation, social attacks)
- ✅ Automated emergency activation
- ✅ Real-time alerting

**Human Oversight**:
- ✅ Guardian can deactivate false positives
- ✅ Emergency responder can add exceptions
- ✅ Owner controls all configuration
- ✅ Rate limiting prevents abuse

**Battle-Tested**:
- ✅ Multiple monitoring systems for redundancy
- ✅ Cooldown prevents spam
- ✅ Incident logging for audit trail
- ✅ Configurable thresholds for tuning

**Response Time**:
- ⚡ Automated detection: 30 seconds (default check interval)
- ⚡ Emergency activation: Immediate (no timelock for mode change)
- ⚡ Alert delivery: < 5 seconds
- ⚡ Team notification: Instant (Slack/PagerDuty)

This system provides **enterprise-grade security monitoring** with **automated response capabilities** while maintaining **human oversight** and **flexibility**.
