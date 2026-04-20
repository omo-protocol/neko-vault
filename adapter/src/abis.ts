// Minimal ABIs for Base-side contracts the adapter interacts with.

export const BASE_EXECUTION_GATEWAY_ABI = [
  {
    type: "function",
    name: "executeCommand",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "env",
        type: "tuple",
        components: [
          { name: "cycleId", type: "bytes32" },
          { name: "commandType", type: "uint8" },
          { name: "dstVault", type: "address" },
          { name: "asset", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "destinationRef", type: "bytes32" },
          { name: "payloadHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
          { name: "ritualTxHash", type: "bytes32" },
        ],
      },
      { name: "sigs", type: "bytes[]" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "DOMAIN_SEPARATOR",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

export const UNIVERSAL_VALUER_ABI = [
  {
    type: "function",
    name: "updateValue",
    stateMutability: "nonpayable",
    inputs: [
      { name: "strategyId", type: "bytes32" },
      { name: "value", type: "uint256" },
      { name: "confidence", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "expiry", type: "uint256" },
      { name: "signatures", type: "bytes[]" },
    ],
    outputs: [],
  },
] as const;

export const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export const COMMAND_ENVELOPE_EIP712_TYPE = {
  CommandEnvelope: [
    { name: "cycleId", type: "bytes32" },
    { name: "commandType", type: "uint8" },
    { name: "dstVault", type: "address" },
    { name: "asset", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "destinationRef", type: "bytes32" },
    { name: "payloadHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "ritualTxHash", type: "bytes32" },
  ],
} as const;
