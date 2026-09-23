import { defineChain } from 'viem'

const ARC_IS_MAINNET = (process.env.NEXT_PUBLIC_CCTP_ENV ?? 'testnet') === 'mainnet'
const RPC = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? (ARC_IS_MAINNET ? 'https://rpc.mainnet.arc.io' : 'https://rpc.testnet.arc.network')
const ARC_EXPLORER = ARC_IS_MAINNET ? 'https://explorer.arc.io' : 'https://testnet.arcscan.app'

export const arcTestnet = defineChain({
  id: Number(process.env.NEXT_PUBLIC_ARC_CHAIN_ID ?? (ARC_IS_MAINNET ? 5042 : 5042002)),
  name: ARC_IS_MAINNET ? 'Arc' : 'Arc Testnet',
  nativeCurrency: {
    decimals: 18,
    name: 'USD Coin',
    symbol: 'USDC',
  },
  rpcUrls: {
    default: {
      http:      [RPC],
      webSocket: [RPC.replace('https://', 'wss://')],
    },
  },
  blockExplorers: {
    default: {
      name: ARC_IS_MAINNET ? 'ArcExplorer' : 'ArcScan',
      url:  ARC_EXPLORER,
    },
  },
  testnet: !ARC_IS_MAINNET,
})
// __NEXUM_MAINNET_M3__ 20260923-214519
