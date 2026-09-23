import { createPublicClient, http, parseAbiItem } from 'viem'
import { defineChain } from 'viem'

// Arc chain - env-driven so CCTP_ENV=mainnet flips it to Arc mainnet.
// Mainnet: id 5042, rpc.mainnet.arc.io, explorer.arc.io (verified, official).
// Testnet: id 5042002, rpc.testnet.arc.network, testnet.arcscan.app.
const ARC_IS_MAINNET = (process.env.CCTP_ENV ?? 'testnet') === 'mainnet'
const ARC_CHAIN_ID   = Number(process.env.ARC_CHAIN_ID ?? (ARC_IS_MAINNET ? 5042 : 5042002))
const ARC_RPC        = process.env.ARC_RPC_URL ?? (ARC_IS_MAINNET ? 'https://rpc.mainnet.arc.io' : 'https://rpc.testnet.arc.network')
const ARC_EXPLORER   = process.env.ARC_EXPLORER_URL ?? (ARC_IS_MAINNET ? 'https://explorer.arc.io' : 'https://testnet.arcscan.app')

export const arcTestnet = defineChain({
  id: ARC_CHAIN_ID,
  name: ARC_IS_MAINNET ? 'Arc' : 'Arc Testnet',
  nativeCurrency: { decimals: 18, name: 'USD Coin', symbol: 'USDC' },
  rpcUrls: {
    default: { http: [ARC_RPC] },
  },
  blockExplorers: {
    default: { name: ARC_IS_MAINNET ? 'ArcExplorer' : 'ArcScan', url: ARC_EXPLORER },
  },
  testnet: !ARC_IS_MAINNET,
})

export const arcClient = createPublicClient({
  chain: arcTestnet,
  transport: http(ARC_RPC),
})

// Arc contract addresses
export const USDC_ADDRESS = '0x3600000000000000000000000000000000000000' as const

// Watch USDC Transfer events used to detect incoming vault deposits
export function watchUSDCTransfers(
  toAddress: `0x${string}`,
  onTransfer: (from: string, value: bigint, txHash: string) => void,
) {
  return arcClient.watchEvent({
    address: USDC_ADDRESS,
    event:   parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args:    { to: toAddress },
    onLogs: (logs) => {
      for (const log of logs) {
        const { from, value } = log.args as { from: string; value: bigint }
        onTransfer(from, value, log.transactionHash ?? '')
      }
    },
  })
}

export async function getLatestBlock() {
  return arcClient.getBlockNumber()
}
// __NEXUM_MAINNET_M2__ 20260923-214326
