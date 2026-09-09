// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IUSDC.sol";

// Minimal CCTP V2 TokenMessenger interface (only the burn we need).
// depositForBurn burns `amount` from the CALLER (this vault, after it holds the
// net) and mints to `mintRecipient` on the destination domain. destinationCaller
// = bytes32(0) leaves the mint permissionless (any address may call
// receiveMessage on the destination), matching the existing bridge flow.
interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32  destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external returns (uint64 nonce);
}

/**
 * @title NexumVault
 * @notice Handles FX conversion + P2P marketplace + invoice payments with an
 *         on-chain platform-fee model (v2):
 *   - Market orders (live rate) and Limit orders (+/-5% of market)
 *   - Perpetual offers (no on-chain expiry - backend enforces timers)
 *   - Maker-set timer for taker completion window
 *   - reopenP2POffer: a timed-out accepted offer returns to the marketplace
 *     with its funds still escrowed, instead of being cancelled to the maker
 *   - Uniform inclusive fee model: the recipient nets (amount - fee). The fee
 *     is only ever collected on a SUCCESSFUL settlement (P2P release, invoice
 *     pay). Cancels and reopens never take a fee.
 *   - Per-protocol fee accounting (feesAccrued) so the owner can withdraw
 *     collected fees WITHOUT ever touching user escrow.
 *
 * Arc Testnet USDC: 0x3600000000000000000000000000000000000000
 * Chain ID: 5042002
 */
contract NexumVault is Ownable, ReentrancyGuard, Pausable {

    IUSDC public immutable usdc;

    uint256 public spreadBps  = 50;
    // Platform fee, uniform across fee-bearing protocols. 10 bps = 0.10%.
    uint256 public p2pFeeBps      = 10;
    uint256 public invoiceFeeBps  = 10;
    uint256 public bridgeFeeBps   = 10;
    uint256 public constant MAX_SPREAD_BPS = 200;
    uint256 public constant MAX_FEE_BPS    = 100; // hard cap 1% on any platform fee

    // CCTP V2 TokenMessenger on this chain, used by bridgeWithFee. Settable by
    // owner because the address is chain/environment-specific and may change.
    ITokenMessenger public tokenMessenger;

    // ── Fee accounting ───────────────────────────────────────
    // Fees are collected inclusively (kept in the vault when a settlement pays
    // out amount-minus-fee) and tracked per protocol so withdrawFees can never
    // dip into escrowed user funds. Incremented ONLY on success.
    enum FeeProtocol { P2P, Invoice, Bridge }
    mapping(FeeProtocol => uint256) public feesAccrued;      // lifetime collected
    mapping(FeeProtocol => uint256) public feesWithdrawn;    // lifetime withdrawn

    enum OfferStatus { Open, Accepted, Released, Cancelled }
    enum OrderType   { Market, Limit }

    struct P2POffer {
        bytes32     offerId;
        address     maker;
        address     taker;
        uint256     usdcAmount;
        string      localCurrency;
        uint256     localAmount;        // auto-calculated from rate
        uint256     rateOffered;        // local units per USDC * 1e6
        OrderType   orderType;          // Market or Limit
        uint256     makerTimerSeconds;  // window maker gives taker
        OfferStatus status;
        bool        makerConfirmed;     // maker received local currency
        bool        takerConfirmed;     // taker sent local currency
    }

    mapping(bytes32 => P2POffer) public offers;

    // Invoices are paid THROUGH the vault so the fee can be split on-chain.
    // We only need to guard against a double-pay of the same invoiceId; all
    // other invoice metadata stays in the API/DB.
    mapping(bytes32 => bool) public invoicePaid;

    event OfferCreated(
        bytes32 indexed offerId,
        address indexed maker,
        uint256 usdcAmount,
        string  localCurrency,
        uint256 localAmount,
        uint8   orderType,
        uint256 makerTimerSeconds
    );
    event OfferAccepted(bytes32 indexed offerId, address indexed taker);
    event TakerConfirmed(bytes32 indexed offerId);
    event MakerConfirmed(bytes32 indexed offerId);
    event OfferReleased(bytes32 indexed offerId, address indexed taker, uint256 amount, uint256 fee);
    event OfferCancelled(bytes32 indexed offerId, string reason);
    event OfferReopened(bytes32 indexed offerId);
    event InvoicePaid(bytes32 indexed invoiceId, address indexed payer, address indexed creator, uint256 amount, uint256 fee);
    event ConversionRequested(address indexed user, uint256 amount, string currency, uint256 ts);
    event FeesWithdrawn(uint8 indexed protocol, address indexed to, uint256 amount);
    event BridgeInitiated(address indexed user, uint256 grossAmount, uint256 net, uint256 fee, uint32 destinationDomain, bytes32 mintRecipient, uint64 nonce);
    event TokenMessengerSet(address indexed messenger);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IUSDC(_usdc);
    }

    // ── FX Conversion ────────────────────────────────────────

    function requestConversion(
        uint256 amount,
        string calldata targetCurrency
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        usdc.transferFrom(msg.sender, address(this), amount);
        emit ConversionRequested(msg.sender, amount, targetCurrency, block.timestamp);
    }

    // ── P2P Marketplace ──────────────────────────────────────

    /**
     * @notice Create a perpetual P2P offer (no on-chain expiry).
     * @param usdcAmount        USDC to lock (6 decimals). This is the FULL
     *                          escrow; the fee is taken out of it on release
     *                          (inclusive model), so the taker nets
     *                          usdcAmount - fee and nothing extra is pulled.
     * @param localCurrency     ISO code e.g. "NGN"
     * @param localAmount       Local currency amount (calculated from rate off-chain)
     * @param orderType         0=Market, 1=Limit
     * @param makerTimerSeconds Window given to taker after accepting (in seconds)
     */
    function createP2POffer(
        uint256 usdcAmount,
        string  calldata localCurrency,
        uint256 localAmount,
        uint8   orderType,
        uint256 makerTimerSeconds
    ) external nonReentrant whenNotPaused returns (bytes32 offerId) {
        require(usdcAmount    > 0,  "Amount required");
        require(localAmount   > 0,  "Local amount required");
        require(makerTimerSeconds >= 5 minutes, "Min timer: 5 minutes");
        require(makerTimerSeconds <= 24 hours,  "Max timer: 24 hours");

        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        offerId = keccak256(abi.encodePacked(
            msg.sender, usdcAmount, localCurrency, block.timestamp, block.prevrandao
        ));

        uint256 rate = (usdcAmount * 1e6) / localAmount;

        offers[offerId] = P2POffer({
            offerId:           offerId,
            maker:             msg.sender,
            taker:             address(0),
            usdcAmount:        usdcAmount,
            localCurrency:     localCurrency,
            localAmount:       localAmount,
            rateOffered:       rate,
            orderType:         OrderType(orderType),
            makerTimerSeconds: makerTimerSeconds,
            status:            OfferStatus.Open,
            makerConfirmed:    false,
            takerConfirmed:    false
        });

        emit OfferCreated(offerId, msg.sender, usdcAmount, localCurrency, localAmount, orderType, makerTimerSeconds);
    }

    function acceptP2POffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status   == OfferStatus.Open, "Offer not open");
        require(offer.maker    != msg.sender,        "Cannot self-trade");
        offer.taker  = msg.sender;
        offer.status = OfferStatus.Accepted;
        emit OfferAccepted(offerId, msg.sender);
    }

    // Taker confirms they SENT local currency to maker
    function takerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  == msg.sender,           "Not the taker");
        offer.takerConfirmed = true;
        emit TakerConfirmed(offerId);
    }

    // Maker confirms they RECEIVED local currency from taker
    function makerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.maker  == msg.sender,           "Not the maker");
        offer.makerConfirmed = true;
        emit MakerConfirmed(offerId);
    }

    // Platform releases USDC to taker (owner only). Inclusive fee: taker nets
    // usdcAmount - fee, the fee stays in the vault and is recorded as accrued.
    function releaseP2POffer(bytes32 offerId) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  != address(0),           "No taker");
        uint256 fee    = (offer.usdcAmount * p2pFeeBps) / 10_000;
        uint256 payout = offer.usdcAmount - fee;
        offer.status   = OfferStatus.Released;
        feesAccrued[FeeProtocol.P2P] += fee;
        usdc.transfer(offer.taker, payout);
        emit OfferReleased(offerId, offer.taker, payout, fee);
    }

    // Platform cancels and returns the FULL escrow to maker (owner only).
    // No fee is taken on a failed trade.
    function cancelP2POffer(bytes32 offerId, string calldata reason) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(
            offer.status == OfferStatus.Open ||
            offer.status == OfferStatus.Accepted,
            "Cannot cancel"
        );
        offer.status = OfferStatus.Cancelled;
        usdc.transfer(offer.maker, offer.usdcAmount);
        emit OfferCancelled(offerId, reason);
    }

    /**
     * @notice Return a timed-out accepted offer to the marketplace (owner only).
     * @dev The taker accepted but never completed within the maker's window.
     *      Instead of cancelling back to the maker, we reset the offer to Open
     *      and KEEP the USDC escrowed in place (no transfer), so the same offer
     *      - identical parameters, same escrow - can be taken by someone else.
     *      Only valid from Accepted. Clears taker + both confirmations.
     */
    function reopenP2POffer(bytes32 offerId) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Not accepted");
        offer.status         = OfferStatus.Open;
        offer.taker          = address(0);
        offer.takerConfirmed = false;
        offer.makerConfirmed = false;
        emit OfferReopened(offerId);
    }

    // Maker cancels own open offer - full escrow returned, no fee.
    function makerCancelOffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Open, "Offer not open");
        require(offer.maker  == msg.sender,       "Not the maker");
        offer.status = OfferStatus.Cancelled;
        usdc.transfer(offer.maker, offer.usdcAmount);
        emit OfferCancelled(offerId, "Maker cancelled");
    }

    function getOffer(bytes32 offerId) external view returns (P2POffer memory) {
        return offers[offerId];
    }

    // ── Invoices ─────────────────────────────────────────────

    /**
     * @notice Pay an invoice through the vault so the platform fee is split
     *         on-chain. Inclusive fee: the creator receives amount - fee, the
     *         fee stays in the vault and is recorded as accrued.
     * @dev The payer must have approved the vault for `amount` first
     *      (approve + payInvoice for external EOAs; a contractExecution for
     *      Circle wallets). invoiceId is the app's invoice reference; a given
     *      invoiceId can only be paid once here.
     * @param invoiceId App reference for the invoice (bytes32).
     * @param creator   Address that should receive the net payment.
     * @param amount    Gross USDC amount the payer sends (6 decimals).
     */
    function payInvoice(
        bytes32 invoiceId,
        address creator,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(amount  > 0,             "Amount required");
        require(creator != address(0),  "No creator");
        require(!invoicePaid[invoiceId], "Already paid");

        invoicePaid[invoiceId] = true;
        usdc.transferFrom(msg.sender, address(this), amount);

        uint256 fee    = (amount * invoiceFeeBps) / 10_000;
        uint256 payout = amount - fee;
        feesAccrued[FeeProtocol.Invoice] += fee;
        usdc.transfer(creator, payout);

        emit InvoicePaid(invoiceId, msg.sender, creator, payout, fee);
    }

    // ── Bridge (CCTP V2) with platform fee ───────────────────

    /**
     * @notice Bridge USDC cross-chain via CCTP, taking the 0.1% platform fee on
     *         the source chain, atomically with the burn.
     * @dev The user approves THIS vault for `amount`, then calls this. The vault
     *      pulls `amount`, keeps `fee = amount * bridgeFeeBps / 10_000`, and
     *      burns the NET via the CCTP TokenMessenger with the user as
     *      mintRecipient. Fee and burn are one transaction: if the burn reverts,
     *      the whole call reverts and no fee is taken. If the burn SUCCEEDS the
     *      USDC is gone from this chain and the transfer will finalize on the
     *      destination (CCTP attestations do not expire), so the fee is earned -
     *      no refund path is needed. The user receives NET on the destination.
     *      destinationCaller is bytes32(0), so the mint stays permissionless
     *      (the user or a reconciler completes it), matching the current flow.
     * @param amount               Gross USDC to bridge (6 decimals). Fee comes
     *                             out of this; net = amount - fee is burned.
     * @param destinationDomain    CCTP domain id of the destination chain.
     * @param mintRecipient        Recipient on the destination, as bytes32.
     * @param maxFee               CCTP V2 maxFee (from the bridge quote).
     * @param minFinalityThreshold CCTP V2 finality threshold (from the quote).
     */
    function bridgeWithFee(
        uint256 amount,
        uint32  destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external nonReentrant whenNotPaused returns (uint64 nonce) {
        require(amount > 0,                          "Amount required");
        require(mintRecipient != bytes32(0),         "No recipient");
        require(address(tokenMessenger) != address(0), "Messenger not set");

        uint256 fee = (amount * bridgeFeeBps) / 10_000;
        uint256 net = amount - fee;
        require(net > maxFee, "Net below CCTP maxFee");

        // Pull gross from the user (they approved the vault), keep the fee.
        usdc.transferFrom(msg.sender, address(this), amount);
        feesAccrued[FeeProtocol.Bridge] += fee;

        // Approve the messenger for the net and burn. Reset allowance to 0 first
        // for tokens that require it before a new approval.
        usdc.approve(address(tokenMessenger), 0);
        usdc.approve(address(tokenMessenger), net);

        nonce = tokenMessenger.depositForBurn(
            net,
            destinationDomain,
            mintRecipient,
            address(usdc),
            bytes32(0),
            maxFee,
            minFinalityThreshold
        );

        emit BridgeInitiated(msg.sender, amount, net, fee, destinationDomain, mintRecipient, nonce);
    }

    // ── Fee withdrawal (owner only, fee-only, never escrow) ──

    /**
     * @notice Amount of a protocol's fees still available to withdraw.
     */
    function feesAvailable(FeeProtocol protocol) public view returns (uint256) {
        return feesAccrued[protocol] - feesWithdrawn[protocol];
    }

    /**
     * @notice Total platform fees still available across all protocols.
     */
    function totalFeesAvailable() external view returns (uint256) {
        return feesAvailable(FeeProtocol.P2P) + feesAvailable(FeeProtocol.Invoice) + feesAvailable(FeeProtocol.Bridge);
    }

    /**
     * @notice Withdraw collected platform fees for one protocol (owner only).
     * @dev Bounded to feesAvailable(protocol): this can NEVER transfer escrowed
     *      user funds, only fees that were actually collected on settlement.
     *      The "we don't touch escrow" invariant, enforced on-chain.
     */
    function withdrawFees(FeeProtocol protocol, address to, uint256 amount)
        external onlyOwner nonReentrant
    {
        require(to != address(0),                       "Bad recipient");
        require(amount > 0,                             "Amount required");
        require(amount <= feesAvailable(protocol),      "Exceeds available fees");
        feesWithdrawn[protocol] += amount;
        usdc.transfer(to, amount);
        emit FeesWithdrawn(uint8(protocol), to, amount);
    }

    // ── Admin config ─────────────────────────────────────────

    function setSpreadBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_SPREAD_BPS, "Too high");
        spreadBps = _bps;
    }

    function setP2PFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "Max 1%");
        p2pFeeBps = _bps;
    }

    function setInvoiceFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "Max 1%");
        invoiceFeeBps = _bps;
    }

    function setBridgeFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "Max 1%");
        bridgeFeeBps = _bps;
    }

    function setTokenMessenger(address _messenger) external onlyOwner {
        require(_messenger != address(0), "Zero messenger");
        tokenMessenger = ITokenMessenger(_messenger);
        emit TokenMessengerSet(_messenger);
    }

    function calcSpread(uint256 amount) public view returns (uint256) {
        return (amount * spreadBps) / 10_000;
    }

    function vaultBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }
}
