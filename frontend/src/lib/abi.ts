// Minimal vault ABI for read-only discovery. Add to this if you extend the UI
// to show more fields. Generated names match `out/HyperCoreVault.sol/*.json`.

export const vaultAbi = [
    {type: "function", name: "name", stateMutability: "view", inputs: [], outputs: [{type: "string"}]},
    {type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{type: "string"}]},
    {type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{type: "uint8"}]},
    {type: "function", name: "asset", stateMutability: "view", inputs: [], outputs: [{type: "address"}]},
    {type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
    {type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
    {type: "function", name: "pricePerShare", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
    {type: "function", name: "idleUsdc", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
    {type: "function", name: "coreSpotUsdc", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
    {type: "function", name: "perpWithdrawable", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
    {type: "function", name: "leverageCapBps", stateMutability: "view", inputs: [], outputs: [{type: "uint16"}]},
    {type: "function", name: "perfFeeBps", stateMutability: "view", inputs: [], outputs: [{type: "uint16"}]},
    {type: "function", name: "mgmtFeeAnnualBps", stateMutability: "view", inputs: [], outputs: [{type: "uint16"}]},
    {type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{type: "bool"}]},
    {type: "function", name: "emergencyShutdownActive", stateMutability: "view", inputs: [], outputs: [{type: "bool"}]},
] as const;
