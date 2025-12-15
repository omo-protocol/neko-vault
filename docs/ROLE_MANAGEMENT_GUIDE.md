## Role Management & Automated Monitoring System

## 🎯 Overview

This guide explains how to set up a complete **automated security monitoring system** with **role-based access control** for EmergencyGate. The system automatically detects security incidents and triggers emergency responses.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    VAULT V2 ECOSYSTEM                        │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────┐         ┌──────────────────┐             │
│  │   VaultV2    │◄────────│ EmergencyGate    │             │
│  │              │         │  WithRoles       │             │
│  └──────┬───────┘         └────────▲─────────┘             │
│         │                           │                        │
│         │                           │ activateEmergency()   │
│         │                           │                        │
│  ┌──────▼───────┐         ┌────────┴─────────┐             │
│  │   Adapter    │         │ SecurityMonitor   │             │
│  │   (UniversalAdapterEscrow) │  Contract    │             │
│  └──────────────┘         └────────▲─────────┘             │
│                                     │                        │
└─────────────────────────────────────┼────────────────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │   OFF-CHAIN WORKER      │
                         │   (Keeper System)       │
                         ├──────────────────────────┤
                         │ • Monitors on-chain data │
                         │ • Calls checkAndRespond()│
                         │ • Reports incidents      │
                         │ • Alerts team            │
                         └──────────────────────────┘
```

---

## 👥 ROLE SYSTEM

### Role Hierarchy

| Role | Powers | Who Should Have It | Example |
|------|--------|-------------------|---------|
| **OWNER** | • Full control<br>• Add/remove all roles<br>• Change configuration<br>• Manage exceptions<br>• Emergency control | Protocol team multisig | 3/5 Gnosis Safe |
| **GUARDIAN** | • Activate emergency<br>• Deactivate emergency<br>• No configuration changes | Secondary multisig or trusted entity | 2/3 emergency multisig |
| **MONITOR** | • ONLY activate emergency<br>• Cannot deactivate<br>• Rate limited | Automated monitoring contracts | SecurityMonitor contract |
| **EMERGENCY RESPONDER** | • Add exceptions during emergency<br>• Quick recovery operations<br>• No deactivation power | Hot wallet for emergency ops | EOA with secure key management |
| **EXCEPTION** | • Bypass all gate restrictions<br>• Can operate during emergency | Vault itself, recovery contracts | Vault address, recovery multisig |

### Role Assignment Strategy

```
PRIMARY SETUP (Recommended):
├── OWNER: 3/5 multisig (protocol team)
├── GUARDIAN: 2/3 multisig (emergency response team)
├── MONITOR: SecurityMonitor contract (automated)
├── MONITOR: Backup monitoring contract (redundancy)
├── EMERGENCY RESPONDER: Hot wallet (for quick exception adds)
└── EXCEPTIONS:
    ├── Vault address (automatic)
    ├── Protocol treasury (for recovery)
    └── Trusted contracts (bundlers, etc.)

DEVELOPMENT/TESTING SETUP:
├── OWNER: EOA (developer)
├── GUARDIAN: EOA (testing account)
├── MONITOR: SecurityMonitor contract
└── EMERGENCY RESPONDER: EOA (testing account)
```

---

## 🤖 AUTOMATED MONITORING SYSTEM

### SecurityMonitor Contract

The `SecurityMonitor` contract automatically detects threats and triggers emergency responses.

#### Detection Capabilities

1. **Share Price Crash Detection**
   - Monitors share price over configurable window
   - Triggers if price drops > threshold % (e.g., 10%)
   - Classification: MEDIUM (10-15%), HIGH (15-20%), CRITICAL (>20%)

2. **Rapid Withdrawal Detection**
   - Tracks withdrawals within time window
   - Triggers if withdrawals > threshold % of TVL (e.g., 20% in 1 hour)
   - Classification: MEDIUM (20-30%), HIGH (30-40%), CRITICAL (>40%)

3. **Adapter Balance Anomaly Detection**
   - Compares `totalAllocations` vs `realAssets` for UniversalAdapterEscrow
   - Triggers if mismatch > threshold % (e.g., 5%)
   - Classification: MEDIUM (5-10%), HIGH (10-15%), CRITICAL (>15%)

4. **Manual Incident Reporting**
   - Off-chain worker can report incidents detected externally
   - Examples: MEV attacks, oracle manipulation, social attacks

#### Configuration Parameters

```solidity
struct MonitoringConfig {
    // Share price monitoring
    uint256 sharePriceCrashThreshold;       // BPS (e.g., 1000 = 10%)
    uint256 sharePriceCheckWindow;          // Seconds (e.g., 3600 = 1 hour)

    // Withdrawal monitoring
    uint256 rapidWithdrawalThreshold;       // BPS (e.g., 2000 = 20% of TVL)
    uint256 rapidWithdrawalWindow;          // Seconds (e.g., 3600 = 1 hour)

    // Adapter monitoring
    uint256 adapterBalanceMismatchThreshold; // BPS (e.g., 500 = 5%)

    // Auto-response settings
    bool autoResponseEnabled;               // Enable automated emergency activation
    uint256 cooldownPeriod;                 // Seconds between activations (e.g., 3600)
}
```

**Recommended Production Settings:**

```solidity
MonitoringConfig({
    sharePriceCrashThreshold: 1000,        // 10% price drop
    sharePriceCheckWindow: 3600,           // 1 hour
    rapidWithdrawalThreshold: 2000,        // 20% of TVL
    rapidWithdrawalWindow: 3600,           // 1 hour
    adapterBalanceMismatchThreshold: 500,  // 5% mismatch
    autoResponseEnabled: true,             // Enable auto-response
    cooldownPeriod: 3600                   // 1 hour cooldown
})
```

---

## 🔧 OFF-CHAIN WORKER INTEGRATION

### Worker System Architecture

```typescript
// Worker runs continuously (e.g., every 30 seconds)
class VaultSecurityWorker {
    private monitorContract: SecurityMonitor;
    private gate: EmergencyGateWithRoles;
    private alerting: AlertingService;

    async run() {
        while (true) {
            try {
                // 1. Check on-chain threats
                const [detected, activated] = await this.monitorContract.checkAndRespond();

                if (detected) {
                    // 2. Get incident details
                    const incidentId = await this.monitorContract.getIncidentCount() - 1;
                    const incident = await this.monitorContract.getIncident(incidentId);

                    // 3. Alert team
                    await this.alerting.sendAlert({
                        severity: incident.threat,
                        category: incident.category,
                        description: incident.description,
                        emergencyActivated: activated
                    });

                    // 4. Log to monitoring system
                    await this.logIncident(incident);
                }

                // 5. Check off-chain threats (your custom logic)
                const offChainThreats = await this.checkOffChainThreats();

                if (offChainThreats.length > 0) {
                    for (const threat of offChainThreats) {
                        // Report to SecurityMonitor
                        await this.monitorContract.reportIncident(
                            threat.level,
                            threat.category,
                            threat.description,
                            threat.shouldActivateEmergency
                        );

                        // Alert team
                        await this.alerting.sendAlert(threat);
                    }
                }

            } catch (error) {
                console.error('Worker error:', error);
                await this.alerting.sendError(error);
            }

            // Wait before next check
            await this.sleep(30000); // 30 seconds
        }
    }

    async checkOffChainThreats(): Promise<Threat[]> {
        const threats: Threat[] = [];

        // Example: Check MEV activity
        const mevActivity = await this.mevMonitor.check();
        if (mevActivity.suspicious) {
            threats.push({
                level: ThreatLevel.HIGH,
                category: 'MEV_ATTACK',
                description: `Suspicious MEV detected: ${mevActivity.details}`,
                shouldActivateEmergency: true
            });
        }

        // Example: Check oracle manipulation
        const oracleHealth = await this.oracleMonitor.check();
        if (!oracleHealth.healthy) {
            threats.push({
                level: ThreatLevel.CRITICAL,
                category: 'ORACLE_MANIPULATION',
                description: `Oracle anomaly: ${oracleHealth.issue}`,
                shouldActivateEmergency: true
            });
        }

        // Example: Check social attacks (Discord, Twitter)
        const socialThreats = await this.socialMonitor.check();
        if (socialThreats.detected) {
            threats.push({
                level: ThreatLevel.MEDIUM,
                category: 'SOCIAL_ATTACK',
                description: `Social engineering attempt detected`,
                shouldActivateEmergency: false  // Just alert, don't auto-activate
            });
        }

        return threats;
    }
}
```

### Worker Deployment Options

#### Option 1: AWS Lambda (Serverless)

```yaml
# serverless.yml
service: vault-security-worker

provider:
  name: aws
  runtime: nodejs18.x
  environment:
    RPC_URL: ${env:RPC_URL}
    MONITOR_ADDRESS: ${env:MONITOR_ADDRESS}
    KEEPER_PRIVATE_KEY: ${env:KEEPER_PRIVATE_KEY}
    ALERT_WEBHOOK: ${env:ALERT_WEBHOOK}

functions:
  securityCheck:
    handler: worker.checkSecurity
    events:
      - schedule: rate(1 minute)  # Run every minute
    timeout: 30
```

#### Option 2: Docker Container (Self-Hosted)

```dockerfile
# Dockerfile
FROM node:18-alpine

WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .

CMD ["node", "worker.js"]
```

```yaml
# docker-compose.yml
version: '3.8'
services:
  security-worker:
    build: .
    environment:
      - RPC_URL=https://rpc.hyperliquid.xyz/evm
      - MONITOR_ADDRESS=0x...
      - KEEPER_PRIVATE_KEY=${KEEPER_PRIVATE_KEY}
      - ALERT_WEBHOOK=${ALERT_WEBHOOK}
    restart: always
```

#### Option 3: Gelato Network (Decentralized)

```typescript
// Use Gelato for decentralized keeper
import { GelatoOpsSDK } from "@gelatonetwork/ops-sdk";

const gelato = new GelatoOpsSDK(chainId, signer);

// Create automated task
await gelato.createTask({
    execAddress: monitorAddress,
    execSelector: "checkAndRespond()",
    resolverAddress: monitorAddress,
    resolverData: "0x", // No resolver data needed
    interval: 60,  // Check every 60 seconds
});
```

---

## 📋 DEPLOYMENT GUIDE

### Step 1: Deploy EmergencyGateWithRoles

```bash
# Set environment variables
export VAULT_ADDRESS="0x..."
export GATE_OWNER="0x..."  # Multisig address
export INITIAL_MODE="0"    # 0 = NORMAL

# Deploy
forge script script/DeployEmergencyGateWithRoles.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --broadcast \
  --verify
```

### Step 2: Configure Roles

```solidity
EmergencyGateWithRoles gate = EmergencyGateWithRoles(GATE_ADDRESS);

// Add guardians
gate.setGuardian(EMERGENCY_MULTISIG, true);

// Add emergency responders
gate.setEmergencyResponder(HOT_WALLET, true);

// Add exceptions
gate.setException(VAULT_ADDRESS, true);  // Already done in constructor
gate.setException(PROTOCOL_TREASURY, true);
gate.setException(RECOVERY_CONTRACT, true);
```

### Step 3: Deploy SecurityMonitor

```bash
export VAULT_ADDRESS="0x..."
export GATE_ADDRESS="0x..."
export MONITOR_OWNER="0x..."  # Multisig
export KEEPER_ADDRESS="0x..."  # Worker EOA

# Configuration
export SHARE_PRICE_CRASH_THRESHOLD="1000"      # 10%
export SHARE_PRICE_CHECK_WINDOW="3600"         # 1 hour
export RAPID_WITHDRAWAL_THRESHOLD="2000"       # 20%
export RAPID_WITHDRAWAL_WINDOW="3600"          # 1 hour
export ADAPTER_BALANCE_MISMATCH="500"          # 5%
export AUTO_RESPONSE_ENABLED="true"
export COOLDOWN_PERIOD="3600"                  # 1 hour

# Deploy
forge script script/DeploySecurityMonitor.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --broadcast \
  --verify
```

### Step 4: Grant Monitor Role to SecurityMonitor Contract

```solidity
EmergencyGateWithRoles gate = EmergencyGateWithRoles(GATE_ADDRESS);

// Grant MONITOR role to SecurityMonitor contract
gate.setMonitor(SECURITY_MONITOR_ADDRESS, true);
```

### Step 5: Connect Gate to Vault (TIMELOCKED!)

```bash
# Submit gate configuration
export VAULT_ADDRESS="0x..."
export GATE_ADDRESS="0x..."

forge script script/ConfigureVaultGates.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --broadcast

# WAIT FOR TIMELOCK EXPIRATION

# Execute gate configuration
forge script script/ExecuteVaultGates.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --broadcast
```

### Step 6: Deploy Off-Chain Worker

```bash
# Configure worker
cat > .env <<EOF
RPC_URL=https://rpc.hyperliquid.xyz/evm
MONITOR_ADDRESS=0x...
KEEPER_PRIVATE_KEY=0x...
ALERT_WEBHOOK=https://hooks.slack.com/services/...
PAGERDUTY_API_KEY=...
EOF

# Start worker
docker-compose up -d security-worker

# Check logs
docker-compose logs -f security-worker
```

---

## 🚨 EMERGENCY RESPONSE WORKFLOWS

### Scenario 1: Automated Detection & Response

```
1. Threat occurs (e.g., 15% share price drop)
   │
   ├─→ Worker calls checkAndRespond()
   │
   ├─→ SecurityMonitor detects HIGH threat
   │
   ├─→ SecurityMonitor calls gate.activateEmergencyAutomated()
   │
   ├─→ Gate activates EMERGENCY mode
   │
   ├─→ All vault operations blocked (except exceptions)
   │
   ├─→ Worker alerts team via Slack/PagerDuty
   │
   └─→ Team investigates and responds
```

### Scenario 2: Off-Chain Threat Detection

```
1. Worker detects MEV attack off-chain
   │
   ├─→ Worker calls monitor.reportIncident(HIGH, "MEV_ATTACK", description, true)
   │
   ├─→ SecurityMonitor calls gate.activateEmergencyAutomated()
   │
   ├─→ Gate activates EMERGENCY mode
   │
   ├─→ Worker alerts team
   │
   └─→ Team investigates
```

### Scenario 3: Manual Guardian Intervention

```
1. Team discovers critical vulnerability
   │
   ├─→ Guardian calls gate.activateEmergency("Critical vulnerability in adapter X")
   │
   ├─→ Gate activates EMERGENCY mode
   │
   ├─→ Emergency responder adds recovery contract as exception
   │   gate.addExceptionDuringEmergency(RECOVERY_CONTRACT, "Enable recovery")
   │
   ├─→ Recovery contract executes emergency procedures
   │
   ├─→ After resolution, guardian deactivates emergency
   │   gate.deactivateEmergency("Vulnerability patched")
   │
   └─→ Normal operations resume
```

---

## 🔐 SECURITY CONSIDERATIONS

### 1. Keeper Security

**Problem**: Keeper has MONITOR role - compromised keeper can spam emergency activations.

**Mitigations**:
- ✅ Rate limiting (5-minute cooldown per monitor)
- ✅ Separate keeper key (not main protocol keys)
- ✅ AWS KMS or HSM for key storage
- ✅ Monitor keeper activity for suspicious patterns
- ✅ Multiple independent monitoring systems

**Best Practice**:
```solidity
// Deploy multiple independent monitors
gate.setMonitor(MONITORING_SYSTEM_1, true);
gate.setMonitor(MONITORING_SYSTEM_2, true);
gate.setMonitor(MONITORING_SYSTEM_3, true);
```

### 2. False Positives

**Problem**: Automated system might activate emergency for benign events.

**Mitigations**:
- ✅ Careful threshold tuning (start conservative)
- ✅ Cooldown period prevents repeated activations
- ✅ Guardian can deactivate emergency quickly
- ✅ Incident logging for post-mortem analysis
- ✅ Alert team even if auto-response disabled

**Recommended Flow**:
```
Phase 1 (Week 1-2): autoResponseEnabled = false
  → Monitor only, no auto-activation
  → Tune thresholds based on false positives

Phase 2 (Week 3-4): autoResponseEnabled = true, high thresholds
  → Conservative activation (e.g., 20% drop)
  → Observe behavior

Phase 3 (Production): autoResponseEnabled = true, tuned thresholds
  → Optimized thresholds (e.g., 10% drop)
  → Full automated response
```

### 3. Monitor Contract Bugs

**Problem**: Bug in SecurityMonitor could cause DoS or incorrect activations.

**Mitigations**:
- ✅ Extensive testing before deployment
- ✅ Pause function (owner can disable monitoring)
- ✅ Guardian can deactivate emergency if false positive
- ✅ Multiple independent monitoring systems
- ✅ Monitor contract is upgradeable (via redeployment + role change)

**Emergency Fix**:
```solidity
// If SecurityMonitor has bug
// 1. Owner pauses monitoring
monitor.setPaused(true);

// 2. Owner revokes monitor role
gate.setMonitor(OLD_MONITOR, false);

// 3. Deploy new SecurityMonitor
// 4. Grant monitor role to new contract
gate.setMonitor(NEW_MONITOR, true);
```

### 4. Role Centralization

**Problem**: If owner is compromised, entire system is at risk.

**Mitigations**:
- ✅ Use multisig for owner (3/5 recommended)
- ✅ Separate guardians from owner (different entities)
- ✅ Timelock for role changes (optional additional layer)
- ✅ Monitor role changes on-chain
- ✅ Regular security audits of key management

---

## 📊 MONITORING & ALERTING

### Metrics to Track

1. **Incident Count**: `monitor.getIncidentCount()`
2. **Emergency Activations**: Count of `EmergencyActivated` events
3. **False Positives**: Manually track incidents that were benign
4. **Response Time**: Time from threat to emergency activation
5. **Recovery Time**: Time from emergency to normal mode

### Alert Configuration

```typescript
// Example: Slack alerting
async function sendAlert(incident: Incident) {
    const severity = getSeverityEmoji(incident.threat);
    const message = {
        text: `${severity} Vault Security Alert`,
        blocks: [
            {
                type: "header",
                text: { type: "plain_text", text: `${severity} Security Incident` }
            },
            {
                type: "section",
                fields: [
                    { type: "mrkdwn", text: `*Threat Level:*\n${incident.threat}` },
                    { type: "mrkdwn", text: `*Category:*\n${incident.category}` },
                    { type: "mrkdwn", text: `*Emergency Activated:*\n${incident.emergencyActivated ? '✅ Yes' : '❌ No'}` },
                ]
            },
            {
                type: "section",
                text: { type: "mrkdwn", text: `*Description:*\n${incident.description}` }
            },
            {
                type: "actions",
                elements: [
                    {
                        type: "button",
                        text: { type: "plain_text", text: "View on Etherscan" },
                        url: `https://explorer.hyperliquid.xyz/tx/${incident.txHash}`
                    },
                    {
                        type: "button",
                        text: { type: "plain_text", text: "Emergency Runbook" },
                        url: "https://docs.yourprotocol.com/emergency"
                    }
                ]
            }
        ]
    };

    await axios.post(SLACK_WEBHOOK, message);

    // Also page on-call if CRITICAL
    if (incident.threat === ThreatLevel.CRITICAL) {
        await pagerduty.trigger({
            routing_key: PAGERDUTY_KEY,
            event_action: "trigger",
            payload: {
                summary: `CRITICAL: ${incident.description}`,
                severity: "critical",
                source: "vault-security-monitor"
            }
        });
    }
}

function getSeverityEmoji(threat: ThreatLevel): string {
    switch (threat) {
        case ThreatLevel.CRITICAL: return "🚨";
        case ThreatLevel.HIGH: return "⚠️";
        case ThreatLevel.MEDIUM: return "⚡";
        case ThreatLevel.LOW: return "ℹ️";
        default: return "✅";
    }
}
```

---

## 🧪 TESTING CHECKLIST

### Unit Tests

- [ ] Test all role assignments and revocations
- [ ] Test each detection method independently
- [ ] Test rate limiting for monitors
- [ ] Test cooldown period enforcement
- [ ] Test emergency activation by each role
- [ ] Test exception management during emergency
- [ ] Test incident logging

### Integration Tests

- [ ] Test worker → SecurityMonitor → EmergencyGate flow
- [ ] Test automated detection and activation
- [ ] Test manual incident reporting
- [ ] Test guardian deactivation after auto-activation
- [ ] Test multiple monitors triggering concurrently
- [ ] Test recovery from false positive

### Production Readiness

- [ ] Deploy to testnet
- [ ] Run worker for 1 week with monitoring disabled
- [ ] Analyze false positive rate
- [ ] Tune thresholds
- [ ] Simulate emergency scenarios
- [ ] Test alerting system
- [ ] Document runbooks
- [ ] Train team on emergency procedures

---

## 📚 SUMMARY

**Key Components**:
1. **EmergencyGateWithRoles**: Role-based gate with 4 role types
2. **SecurityMonitor**: Automated threat detection contract
3. **Off-Chain Worker**: Continuous monitoring and alerting
4. **Alert System**: Real-time notifications to team

**Role Assignments**:
- OWNER → Protocol multisig (full control)
- GUARDIAN → Emergency multisig (activate/deactivate)
- MONITOR → SecurityMonitor contract (auto-detect)
- EMERGENCY_RESPONDER → Hot wallet (add exceptions quickly)

**Security Model**:
- ✅ Multi-layered defense (on-chain + off-chain)
- ✅ Rate limiting prevents abuse
- ✅ Guardian oversight of automated activations
- ✅ Incident logging for audit trail
- ✅ Configurable thresholds for fine-tuning

**Deployment Flow**:
1. Deploy EmergencyGateWithRoles
2. Configure roles
3. Deploy SecurityMonitor
4. Grant monitor role to SecurityMonitor
5. Connect gate to vault (timelocked)
6. Deploy off-chain worker
7. Monitor and tune

This system provides **automated, real-time protection** while maintaining **human oversight** and **fail-safes**.
