# OVault Frontend Integration Guide

## Overview

For frontends on **spoke chains** (Arbitrum, Plasma, etc.), you only need to integrate with **2 contracts**:
1. **AssetOFT** - For deposits
2. **ShareOFT** - For withdrawals

No need to interact with VaultV2 directly! LayerZero handles everything.

---

## Smart Contract Addresses You Need

### Spoke Chain (e.g., Arbitrum)
```typescript
const ARBITRUM_CONTRACTS = {
  assetOFT: "0x...",      // AssetOFT (USDT)
  shareOFT: "0x...",      // ShareOFT (vUSDT)
  lzEndpoint: "0x...",    // LayerZero endpoint
};

const HUB_EID = 30XXX;    // HyperEVM endpoint ID
const ARBITRUM_EID = 30110; // Arbitrum endpoint ID
```

---

## 1. DEPOSIT Flow (Spoke Chain)

### User Action: Deposit USDT → Receive Shares

```typescript
import { ethers } from "ethers";

// ============================================
// STEP 1: Approve AssetOFT to spend USDT
// ============================================
async function approveDeposit(amount: bigint) {
  const assetOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.assetOFT,
    ASSET_OFT_ABI,
    signer
  );

  const tx = await assetOFT.approve(
    ARBITRUM_CONTRACTS.assetOFT,  // Approve itself (OFT needs to burn)
    amount
  );
  await tx.wait();
  console.log("✅ Approval complete");
}

// ============================================
// STEP 2: Estimate LayerZero Gas Fee
// ============================================
async function estimateDepositFee(
  userAddress: string,
  amount: bigint,
  minShares: bigint
) {
  const assetOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.assetOFT,
    ASSET_OFT_ABI,
    provider
  );

  // Encode compose message
  const composeMsg = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "uint32", "uint256"],
    [
      userAddress,      // Final share recipient
      ARBITRUM_EID,     // Return shares to Arbitrum
      minShares         // Minimum shares (slippage protection)
    ]
  );

  // Build send parameters
  const sendParam = {
    dstEid: HUB_EID,                          // Destination: HyperEVM
    to: addressToBytes32(COMPOSER_ADDRESS),   // Recipient: VaultComposerSync
    amountLD: amount,                         // Amount to send
    minAmountLD: amount,                      // Minimum (no slippage on transfer)
    extraOptions: getComposeOption(),         // Gas settings
    composeMsg: composeMsg,                   // Vault instructions
    oftCmd: "0x"                              // No extra commands
  };

  // Quote the fee
  const [nativeFee, lzTokenFee] = await assetOFT.quoteSend(
    sendParam,
    false  // Not paying in LZ token
  );

  return {
    nativeFee,      // ETH/native token fee
    lzTokenFee,     // LZ token fee (usually 0)
    sendParam       // Save for actual send
  };
}

// ============================================
// STEP 3: Execute Cross-Chain Deposit
// ============================================
async function executeDeposit(
  amount: bigint,
  minShares: bigint,
  userAddress: string
) {
  const assetOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.assetOFT,
    ASSET_OFT_ABI,
    signer
  );

  // Get fee estimate
  const { nativeFee, sendParam } = await estimateDepositFee(
    userAddress,
    amount,
    minShares
  );

  // Execute send
  const tx = await assetOFT.send(
    sendParam,
    { nativeFee, lzTokenFee: 0 },  // Fee payment
    userAddress,                    // Refund address
    { value: nativeFee }            // Pay ETH fee
  );

  const receipt = await tx.wait();
  
  // Get message GUID for tracking
  const guid = getGuidFromReceipt(receipt);
  
  console.log("✅ Deposit initiated");
  console.log("📋 Track on LayerZero Scan:", guid);
  
  return { tx, receipt, guid };
}

// ============================================
// COMPLETE DEPOSIT FLOW
// ============================================
async function deposit(amountUSDT: string, slippageBps: number) {
  const user = await signer.getAddress();
  const amount = ethers.parseUnits(amountUSDT, 6); // USDT is 6 decimals
  
  // 1. Get expected shares (call hub chain VaultV2.previewDeposit)
  const expectedShares = await getExpectedShares(amount);
  
  // 2. Apply slippage tolerance
  const minShares = expectedShares * BigInt(10000 - slippageBps) / 10000n;
  
  // 3. Approve
  await approveDeposit(amount);
  
  // 4. Execute
  const { guid } = await executeDeposit(amount, minShares, user);
  
  // 5. Wait for completion (optional - poll LayerZero)
  await waitForCompletion(guid);
  
  console.log("✅ Shares received!");
}
```

---

## 2. WITHDRAW Flow (Spoke Chain)

### User Action: Burn Shares → Receive USDT

```typescript
// ============================================
// STEP 1: Approve ShareOFT to burn shares
// ============================================
async function approveWithdraw(shares: bigint) {
  const shareOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.shareOFT,
    SHARE_OFT_ABI,
    signer
  );

  const tx = await shareOFT.approve(
    ARBITRUM_CONTRACTS.shareOFT,  // Approve itself (OFT needs to burn)
    shares
  );
  await tx.wait();
  console.log("✅ Approval complete");
}

// ============================================
// STEP 2: Estimate LayerZero Gas Fee
// ============================================
async function estimateWithdrawFee(
  userAddress: string,
  shares: bigint,
  minAssets: bigint
) {
  const shareOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.shareOFT,
    SHARE_OFT_ABI,
    provider
  );

  // Encode compose message
  const composeMsg = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "uint32", "uint256"],
    [
      userAddress,      // Final USDT recipient
      ARBITRUM_EID,     // Return USDT to Arbitrum
      minAssets         // Minimum USDT (slippage protection)
    ]
  );

  // Build send parameters
  const sendParam = {
    dstEid: HUB_EID,                          // Destination: HyperEVM
    to: addressToBytes32(COMPOSER_ADDRESS),   // Recipient: VaultComposerSync
    amountLD: shares,                         // Shares to redeem
    minAmountLD: shares,                      // Minimum (no slippage on transfer)
    extraOptions: getComposeOption(),         // Gas settings
    composeMsg: composeMsg,                   // Vault instructions
    oftCmd: "0x"                              // No extra commands
  };

  // Quote the fee
  const [nativeFee, lzTokenFee] = await shareOFT.quoteSend(
    sendParam,
    false
  );

  return { nativeFee, lzTokenFee, sendParam };
}

// ============================================
// STEP 3: Execute Cross-Chain Withdrawal
// ============================================
async function executeWithdraw(
  shares: bigint,
  minAssets: bigint,
  userAddress: string
) {
  const shareOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.shareOFT,
    SHARE_OFT_ABI,
    signer
  );

  // Get fee estimate
  const { nativeFee, sendParam } = await estimateWithdrawFee(
    userAddress,
    shares,
    minAssets
  );

  // Execute send
  const tx = await shareOFT.send(
    sendParam,
    { nativeFee, lzTokenFee: 0 },
    userAddress,
    { value: nativeFee }
  );

  const receipt = await tx.wait();
  const guid = getGuidFromReceipt(receipt);
  
  console.log("✅ Withdrawal initiated");
  console.log("📋 Track on LayerZero Scan:", guid);
  
  return { tx, receipt, guid };
}

// ============================================
// COMPLETE WITHDRAW FLOW
// ============================================
async function withdraw(sharesToBurn: string, slippageBps: number) {
  const user = await signer.getAddress();
  const shares = ethers.parseUnits(sharesToBurn, 18); // Shares are 18 decimals
  
  // 1. Get expected assets (call hub chain VaultV2.previewRedeem)
  const expectedAssets = await getExpectedAssets(shares);
  
  // 2. Apply slippage tolerance
  const minAssets = expectedAssets * BigInt(10000 - slippageBps) / 10000n;
  
  // 3. Approve
  await approveWithdraw(shares);
  
  // 4. Execute
  const { guid } = await executeWithdraw(shares, minAssets, user);
  
  // 5. Wait for completion
  await waitForCompletion(guid);
  
  console.log("✅ USDT received!");
}
```

---

## 3. Read-Only Functions (Query Data)

```typescript
// ============================================
// Get User Balances
// ============================================
async function getUserBalances(userAddress: string) {
  const assetOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.assetOFT,
    ASSET_OFT_ABI,
    provider
  );
  
  const shareOFT = new ethers.Contract(
    ARBITRUM_CONTRACTS.shareOFT,
    SHARE_OFT_ABI,
    provider
  );

  const [usdtBalance, shareBalance] = await Promise.all([
    assetOFT.balanceOf(userAddress),
    shareOFT.balanceOf(userAddress)
  ]);

  return {
    usdt: ethers.formatUnits(usdtBalance, 6),
    shares: ethers.formatUnits(shareBalance, 18)
  };
}

// ============================================
// Get Expected Shares/Assets (from Hub)
// ============================================
// NOTE: These require calling VaultV2 on HUB chain!
// Use multicall or RPC to hub chain

async function getExpectedShares(assets: bigint): Promise<bigint> {
  // Call VaultV2.previewDeposit() on HUB CHAIN (HyperEVM)
  const hubProvider = new ethers.JsonRpcProvider(HYPEREVM_RPC);
  const vault = new ethers.Contract(
    HUB_VAULT_ADDRESS,
    VAULT_ABI,
    hubProvider
  );
  
  return await vault.previewDeposit(assets);
}

async function getExpectedAssets(shares: bigint): Promise<bigint> {
  // Call VaultV2.previewRedeem() on HUB CHAIN (HyperEVM)
  const hubProvider = new ethers.JsonRpcProvider(HYPEREVM_RPC);
  const vault = new ethers.Contract(
    HUB_VAULT_ADDRESS,
    VAULT_ABI,
    hubProvider
  );
  
  return await vault.previewRedeem(shares);
}

// ============================================
// Get Share Price (from Hub)
// ============================================
async function getSharePrice(): Promise<number> {
  const hubProvider = new ethers.JsonRpcProvider(HYPEREVM_RPC);
  const vault = new ethers.Contract(
    HUB_VAULT_ADDRESS,
    VAULT_ABI,
    hubProvider
  );
  
  const [totalAssets, totalSupply] = await Promise.all([
    vault.totalAssets(),
    vault.totalSupply()
  ]);
  
  // Price = totalAssets / totalSupply
  return Number(totalAssets) / Number(totalSupply);
}

// ============================================
// Get Vault APY (from Hub)
// ============================================
async function getVaultAPY(): Promise<number> {
  // Read from VaultV2 on hub chain
  // Calculate based on historical totalAssets growth
  
  const hubProvider = new ethers.JsonRpcProvider(HYPEREVM_RPC);
  const vault = new ethers.Contract(
    HUB_VAULT_ADDRESS,
    VAULT_ABI,
    hubProvider
  );
  
  // Get current total assets
  const currentAssets = await vault.totalAssets();
  
  // Get historical total assets (from events or oracle)
  const historicalAssets = await getHistoricalAssets(vault, 7); // 7 days ago
  
  // Calculate APY
  const growth = (Number(currentAssets) - Number(historicalAssets)) / Number(historicalAssets);
  const apy = (growth * 365 / 7) * 100; // Annualized
  
  return apy;
}
```

---

## 4. Helper Functions

```typescript
// ============================================
// Convert address to bytes32 (LayerZero format)
// ============================================
function addressToBytes32(address: string): string {
  return ethers.zeroPadValue(address, 32);
}

// ============================================
// Get compose options (gas settings)
// ============================================
function getComposeOption(): string {
  // LayerZero gas options
  // Type 3: lzReceive + lzCompose gas
  const optionType = 3;
  const lzReceiveGas = 200000;    // Gas for receiving on hub
  const lzComposeGas = 400000;    // Gas for composer execution
  const lzComposeValue = 0;       // No ETH needed for compose
  
  // Encode options
  return ethers.concat([
    "0x0003",  // Option type 3
    ethers.toBeHex(lzReceiveGas, 16),
    ethers.toBeHex(lzComposeGas, 16),
    ethers.toBeHex(lzComposeValue, 16)
  ]);
}

// ============================================
// Extract GUID from transaction receipt
// ============================================
function getGuidFromReceipt(receipt: any): string {
  // Find PacketSent event
  const packetSentTopic = ethers.id("PacketSent(bytes,bytes,address)");
  const log = receipt.logs.find((log: any) => 
    log.topics[0] === packetSentTopic
  );
  
  if (!log) throw new Error("PacketSent event not found");
  
  // Decode event
  const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
    ["bytes", "bytes", "address"],
    log.data
  );
  
  // Extract GUID from encodedPayload
  const encodedPayload = decoded[0];
  const guid = ethers.dataSlice(encodedPayload, 0, 32);
  
  return guid;
}

// ============================================
// Wait for LayerZero message completion
// ============================================
async function waitForCompletion(guid: string): Promise<void> {
  // Poll LayerZero scan API
  const maxAttempts = 60;  // 5 minutes max (5 sec intervals)
  
  for (let i = 0; i < maxAttempts; i++) {
    const status = await checkMessageStatus(guid);
    
    if (status === "DELIVERED") {
      console.log("✅ Message delivered!");
      return;
    }
    
    if (status === "FAILED") {
      throw new Error("❌ Message failed");
    }
    
    // Wait 5 seconds
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
  
  throw new Error("⏱️ Timeout waiting for message");
}

async function checkMessageStatus(guid: string): Promise<string> {
  // Call LayerZero scan API
  const response = await fetch(
    `https://api-testnet.layerzeroscan.com/tx/${guid}`
  );
  const data = await response.json();
  return data.status; // "INFLIGHT", "DELIVERED", "FAILED"
}
```

---

## 5. Contract ABIs You Need

### AssetOFT ABI (Minimal)
```typescript
const ASSET_OFT_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function send((uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, bytes extraOptions, bytes composeMsg, bytes oftCmd) sendParam, (uint256 nativeFee, uint256 lzTokenFee) fee, address refundAddress) payable returns ((bytes32 guid, uint64 nonce, (uint256 nativeFee, uint256 lzTokenFee) fee) receipt)",
  "function quoteSend((uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, bytes extraOptions, bytes composeMsg, bytes oftCmd) sendParam, bool payInLzToken) view returns (uint256 nativeFee, uint256 lzTokenFee)",
];
```

### ShareOFT ABI (Minimal)
```typescript
const SHARE_OFT_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function send((uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, bytes extraOptions, bytes composeMsg, bytes oftCmd) sendParam, (uint256 nativeFee, uint256 lzTokenFee) fee, address refundAddress) payable returns ((bytes32 guid, uint64 nonce, (uint256 nativeFee, uint256 lzTokenFee) fee) receipt)",
  "function quoteSend((uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, bytes extraOptions, bytes composeMsg, bytes oftCmd) sendParam, bool payInLzToken) view returns (uint256 nativeFee, uint256 lzTokenFee)",
];
```

### VaultV2 ABI (For Hub Queries)
```typescript
const VAULT_ABI = [
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
];
```

---

## 6. Complete Frontend Integration Example

```typescript
// ============================================
// React Component Example
// ============================================
import { useState } from "react";
import { useAccount, useProvider, useSigner } from "wagmi";

export function VaultInterface() {
  const { address } = useAccount();
  const provider = useProvider();
  const { data: signer } = useSigner();
  
  const [amount, setAmount] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleDeposit() {
    if (!signer || !address) return;
    
    setLoading(true);
    try {
      // 1. Get user input
      const depositAmount = ethers.parseUnits(amount, 6);
      
      // 2. Get expected shares from hub
      const expectedShares = await getExpectedShares(depositAmount);
      
      // 3. Calculate slippage (0.5%)
      const minShares = expectedShares * 9950n / 10000n;
      
      // 4. Approve AssetOFT
      await approveDeposit(depositAmount);
      
      // 5. Execute deposit
      const { guid } = await executeDeposit(
        depositAmount,
        minShares,
        address
      );
      
      // 6. Show success with tracking link
      alert(`Deposit initiated! Track: https://layerzeroscan.com/tx/${guid}`);
      
      // 7. Wait for completion (optional)
      await waitForCompletion(guid);
      
      alert("✅ Shares received!");
    } catch (error) {
      console.error(error);
      alert("❌ Deposit failed");
    } finally {
      setLoading(false);
    }
  }

  async function handleWithdraw() {
    if (!signer || !address) return;
    
    setLoading(true);
    try {
      // Similar to deposit but with ShareOFT
      const shares = ethers.parseUnits(amount, 18);
      const expectedAssets = await getExpectedAssets(shares);
      const minAssets = expectedAssets * 9950n / 10000n;
      
      await approveWithdraw(shares);
      const { guid } = await executeWithdraw(shares, minAssets, address);
      
      alert(`Withdrawal initiated! Track: https://layerzeroscan.com/tx/${guid}`);
      await waitForCompletion(guid);
      
      alert("✅ USDT received!");
    } catch (error) {
      console.error(error);
      alert("❌ Withdrawal failed");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div>
      <h2>OVault - Deposit/Withdraw</h2>
      
      <input
        type="number"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        placeholder="Amount"
      />
      
      <button onClick={handleDeposit} disabled={loading}>
        {loading ? "Processing..." : "Deposit USDT"}
      </button>
      
      <button onClick={handleWithdraw} disabled={loading}>
        {loading ? "Processing..." : "Withdraw USDT"}
      </button>
      
      <div>
        <p>Your USDT: {/* Show balance */}</p>
        <p>Your Shares: {/* Show balance */}</p>
        <p>Share Price: {/* Show price from hub */}</p>
        <p>APY: {/* Show APY from hub */}</p>
      </div>
    </div>
  );
}
```

---

## 7. Summary: What Frontend Needs

### On Spoke Chain (Arbitrum, Plasma)

**For Deposits:**
1. ✅ `AssetOFT.approve()` - Approve USDT spending
2. ✅ `AssetOFT.quoteSend()` - Estimate gas fee
3. ✅ `AssetOFT.send()` - Execute cross-chain deposit
4. ✅ `AssetOFT.balanceOf()` - Show USDT balance

**For Withdrawals:**
1. ✅ `ShareOFT.approve()` - Approve share spending
2. ✅ `ShareOFT.quoteSend()` - Estimate gas fee
3. ✅ `ShareOFT.send()` - Execute cross-chain withdrawal
4. ✅ `ShareOFT.balanceOf()` - Show share balance

**For Display (from Hub):**
1. ✅ `VaultV2.previewDeposit()` - Show expected shares
2. ✅ `VaultV2.previewRedeem()` - Show expected assets
3. ✅ `VaultV2.totalAssets()` - Calculate share price
4. ✅ `VaultV2.totalSupply()` - Calculate share price

### On Hub Chain (HyperEVM) - Optional Direct Access

If users connect directly to HyperEVM:
1. ✅ `VaultV2.deposit()` - Direct deposit (no cross-chain)
2. ✅ `VaultV2.redeem()` - Direct withdrawal (no cross-chain)

---

## 8. Key Points

1. **Only 2 Contracts on Spoke** ✅
   - AssetOFT for deposits
   - ShareOFT for withdrawals

2. **No VaultV2 on Spoke** ✅
   - Vault only on hub
   - Query hub for share prices/APY

3. **LayerZero Handles Everything** ✅
   - Compose messages automate vault operations
   - Users just call OFT.send()

4. **User Experience** ✅
   - Feels like depositing to local vault
   - 5-10 second cross-chain execution
   - Track via LayerZero Scan

5. **Gas Fees** ⚠️
   - User pays native gas on spoke (ETH/ARB)
   - Plus LayerZero fee (~$0.10-1.00)
   - Estimate with quoteSend()

---

**That's it! Frontend only needs AssetOFT and ShareOFT on spoke chains.** 🎉
