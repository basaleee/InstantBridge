
;; title: InstantBridge
;; version: 1.0.0
;; summary: Cross-chain AMM liquidity pool for instant Bitcoin-STX conversions
;; description: A decentralized automated market maker that enables instant swaps between Bitcoin and STX tokens

;; traits
;;

;; token definitions
;;

;; constants
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_SLIPPAGE_TOO_HIGH (err u103))
(define-constant ERR_POOL_NOT_EXISTS (err u104))
(define-constant ERR_INSUFFICIENT_LIQUIDITY (err u105))
(define-constant ERR_ZERO_AMOUNT (err u106))
(define-constant ERR_ALREADY_INITIALIZED (err u107))

(define-constant CONTRACT_OWNER tx-sender)
(define-constant FEE_RATE u30) ;; 0.3% fee (30 basis points)
(define-constant FEE_DENOMINATOR u10000)

;; data vars
(define-data-var pool-initialized bool false)
(define-data-var stx-reserve uint u0)
(define-data-var btc-reserve uint u0)
(define-data-var total-liquidity uint u0)
(define-data-var protocol-fee-stx uint u0)
(define-data-var protocol-fee-btc uint u0)

;; data maps
(define-map liquidity-providers principal uint)
(define-map pending-btc-deposits
  { txid: (buff 32) }
  {
    sender: principal,
    amount: uint,
    stx-address: principal,
    confirmed: bool
  }
)

;; public functions

;; Initialize the liquidity pool with initial reserves
(define-public (initialize-pool (initial-stx uint) (initial-btc uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (not (var-get pool-initialized)) ERR_ALREADY_INITIALIZED)
    (asserts! (and (> initial-stx u0) (> initial-btc u0)) ERR_INVALID_AMOUNT)

    ;; Transfer STX to contract
    (try! (stx-transfer? initial-stx tx-sender (as-contract tx-sender)))

    ;; Set initial reserves and liquidity
    (var-set stx-reserve initial-stx)
    (var-set btc-reserve initial-btc)
    (let ((initial-liquidity (* initial-stx initial-btc))) ;; Simple product for initial liquidity
      (var-set total-liquidity initial-liquidity)
      (map-set liquidity-providers tx-sender initial-liquidity)
    )

    (var-set pool-initialized true)
    (ok true)
  )
)

;; Add liquidity to the pool
(define-public (add-liquidity (stx-amount uint) (btc-amount uint) (min-liquidity uint))
  (let (
    (current-stx (var-get stx-reserve))
    (current-btc (var-get btc-reserve))
    (current-liquidity (var-get total-liquidity))
  )
    (asserts! (var-get pool-initialized) ERR_POOL_NOT_EXISTS)
    (asserts! (and (> stx-amount u0) (> btc-amount u0)) ERR_ZERO_AMOUNT)

    ;; Calculate liquidity tokens to mint
    (let (
      (stx-ratio (/ (* stx-amount current-liquidity) current-stx))
      (btc-ratio (/ (* btc-amount current-liquidity) current-btc))
      (liquidity-minted (if (< stx-ratio btc-ratio) stx-ratio btc-ratio))
    )
      (asserts! (>= liquidity-minted min-liquidity) ERR_SLIPPAGE_TOO_HIGH)

      ;; Transfer STX to contract
      (try! (stx-transfer? stx-amount tx-sender (as-contract tx-sender)))

      ;; Update reserves and liquidity
      (var-set stx-reserve (+ current-stx stx-amount))
      (var-set btc-reserve (+ current-btc btc-amount))
      (var-set total-liquidity (+ current-liquidity liquidity-minted))

      ;; Update user's liquidity balance
      (let ((current-user-liquidity (default-to u0 (map-get? liquidity-providers tx-sender))))
        (map-set liquidity-providers tx-sender (+ current-user-liquidity liquidity-minted))
      )

      (ok liquidity-minted)
    )
  )
)

;; Remove liquidity from the pool
(define-public (remove-liquidity (liquidity-amount uint) (min-stx uint) (min-btc uint))
  (let (
    (user-liquidity (default-to u0 (map-get? liquidity-providers tx-sender)))
    (current-stx (var-get stx-reserve))
    (current-btc (var-get btc-reserve))
    (current-liquidity (var-get total-liquidity))
  )
    (asserts! (>= user-liquidity liquidity-amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> liquidity-amount u0) ERR_ZERO_AMOUNT)

    ;; Calculate STX and BTC to return
    (let (
      (stx-amount (/ (* liquidity-amount current-stx) current-liquidity))
      (btc-amount (/ (* liquidity-amount current-btc) current-liquidity))
    )
      (asserts! (and (>= stx-amount min-stx) (>= btc-amount min-btc)) ERR_SLIPPAGE_TOO_HIGH)

      ;; Transfer STX back to user
      (try! (as-contract (stx-transfer? stx-amount tx-sender tx-sender)))

      ;; Update reserves and liquidity
      (var-set stx-reserve (- current-stx stx-amount))
      (var-set btc-reserve (- current-btc btc-amount))
      (var-set total-liquidity (- current-liquidity liquidity-amount))

      ;; Update user's liquidity balance
      (map-set liquidity-providers tx-sender (- user-liquidity liquidity-amount))

      (ok { stx-amount: stx-amount, btc-amount: btc-amount })
    )
  )
)

;; Swap STX for BTC
(define-public (swap-stx-for-btc (stx-amount uint) (min-btc-out uint))
  (let (
    (current-stx (var-get stx-reserve))
    (current-btc (var-get btc-reserve))
  )
    (asserts! (> stx-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (> current-btc u0) ERR_INSUFFICIENT_LIQUIDITY)

    ;; Calculate BTC output with fee (x * y = k AMM formula)
    (let (
      (stx-after-fee (- stx-amount (/ (* stx-amount FEE_RATE) FEE_DENOMINATOR)))
      (new-stx-reserve (+ current-stx stx-after-fee))
      (new-btc-reserve (/ (* current-stx current-btc) new-stx-reserve))
      (btc-out (- current-btc new-btc-reserve))
      (fee-amount (/ (* stx-amount FEE_RATE) FEE_DENOMINATOR))
    )
      (asserts! (>= btc-out min-btc-out) ERR_SLIPPAGE_TOO_HIGH)
      (asserts! (> btc-out u0) ERR_INSUFFICIENT_LIQUIDITY)

      ;; Transfer STX to contract
      (try! (stx-transfer? stx-amount tx-sender (as-contract tx-sender)))

      ;; Update reserves
      (var-set stx-reserve (+ current-stx stx-after-fee))
      (var-set btc-reserve new-btc-reserve)

      ;; Update protocol fees
      (var-set protocol-fee-stx (+ (var-get protocol-fee-stx) fee-amount))

      (ok btc-out)
    )
  )
)

;; Swap BTC for STX (requires off-chain BTC deposit verification)
(define-public (swap-btc-for-stx (btc-amount uint) (min-stx-out uint) (btc-txid (buff 32)))
  (let (
    (current-stx (var-get stx-reserve))
    (current-btc (var-get btc-reserve))
  )
    (asserts! (> btc-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (> current-stx u0) ERR_INSUFFICIENT_LIQUIDITY)

    ;; In a real implementation, this would verify the BTC transaction
    ;; For now, we'll store the pending deposit for manual verification
    (map-set pending-btc-deposits
      { txid: btc-txid }
      {
        sender: tx-sender,
        amount: btc-amount,
        stx-address: tx-sender,
        confirmed: false
      }
    )

    (ok true)
  )
)

;; Confirm BTC deposit and complete swap (admin function)
(define-public (confirm-btc-deposit (btc-txid (buff 32)))
  (let (
    (deposit-info (unwrap! (map-get? pending-btc-deposits { txid: btc-txid }) ERR_POOL_NOT_EXISTS))
    (btc-amount (get amount deposit-info))
    (recipient (get stx-address deposit-info))
    (current-stx (var-get stx-reserve))
    (current-btc (var-get btc-reserve))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (not (get confirmed deposit-info)) ERR_ALREADY_INITIALIZED)

    ;; Calculate STX output with fee
    (let (
      (btc-after-fee (- btc-amount (/ (* btc-amount FEE_RATE) FEE_DENOMINATOR)))
      (new-btc-reserve (+ current-btc btc-after-fee))
      (new-stx-reserve (/ (* current-stx current-btc) new-btc-reserve))
      (stx-out (- current-stx new-stx-reserve))
      (fee-amount (/ (* btc-amount FEE_RATE) FEE_DENOMINATOR))
    )
      ;; Transfer STX to user
      (try! (as-contract (stx-transfer? stx-out tx-sender recipient)))

      ;; Update reserves
      (var-set stx-reserve new-stx-reserve)
      (var-set btc-reserve (+ current-btc btc-after-fee))

      ;; Update protocol fees
      (var-set protocol-fee-btc (+ (var-get protocol-fee-btc) fee-amount))

      ;; Mark deposit as confirmed
      (map-set pending-btc-deposits
        { txid: btc-txid }
        (merge deposit-info { confirmed: true })
      )

      (ok stx-out)
    )
  )
)

;; read only functions

;; Get current pool reserves
(define-read-only (get-reserves)
  {
    stx-reserve: (var-get stx-reserve),
    btc-reserve: (var-get btc-reserve),
    total-liquidity: (var-get total-liquidity)
  }
)

;; Get user's liquidity balance
(define-read-only (get-user-liquidity (user principal))
  (default-to u0 (map-get? liquidity-providers user))
)

;; Calculate STX output for given BTC input
(define-read-only (get-stx-output (btc-amount uint))
  (let (
    (current-stx (var-get stx-reserve))
    (current-btc (var-get btc-reserve))
    (btc-after-fee (- btc-amount (/ (* btc-amount FEE_RATE) FEE_DENOMINATOR)))
  )
    (if (and (> current-stx u0) (> current-btc u0) (> btc-after-fee u0))
      (let (
        (new-btc-reserve (+ current-btc btc-after-fee))
        (new-stx-reserve (/ (* current-stx current-btc) new-btc-reserve))
      )
        (some (- current-stx new-stx-reserve))
      )
      none
    )
  )
)

;; Calculate BTC output for given STX input
(define-read-only (get-btc-output (stx-amount uint))
  (let (
    (current-stx (var-get stx-reserve))
    (current-btc (var-get btc-reserve))
    (stx-after-fee (- stx-amount (/ (* stx-amount FEE_RATE) FEE_DENOMINATOR)))
  )
    (if (and (> current-stx u0) (> current-btc u0) (> stx-after-fee u0))
      (let (
        (new-stx-reserve (+ current-stx stx-after-fee))
        (new-btc-reserve (/ (* current-stx current-btc) new-stx-reserve))
      )
        (some (- current-btc new-btc-reserve))
      )
      none
    )
  )
)

;; Get pending BTC deposit info
(define-read-only (get-pending-deposit (btc-txid (buff 32)))
  (map-get? pending-btc-deposits { txid: btc-txid })
)

;; Check if pool is initialized
(define-read-only (is-pool-initialized)
  (var-get pool-initialized)
)

;; private functions
;;
