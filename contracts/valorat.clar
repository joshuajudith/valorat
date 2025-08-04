;; Valorat Vault Contract - A vault for managing STX deposits and shares

;; Error constants
(define-constant ERR-NOT-AUTHORIZED u100)
(define-constant ERR-VAULT-PAUSED u101)
(define-constant ERR-ZERO-AMOUNT u102)
(define-constant ERR-INSUFFICIENT-SHARES u103)
(define-constant ERR-INSUFFICIENT-BALANCE u104)
(define-constant ERR-ALREADY-INITIALIZED u105)
(define-constant ERR-INVALID-FEE u106)
(define-constant ERR-TRANSFER-FAILED u107)
;; New error constants for enhancements
(define-constant ERR-WITHDRAWAL-TOO-LARGE u200)
(define-constant ERR-DAILY-LIMIT-EXCEEDED u201)
(define-constant ERR-CIRCUIT-BREAKER-TRIGGERED u202)
(define-constant ERR-COOLDOWN-NOT-EXPIRED u203)
(define-constant ERR-INVALID-YIELD-RATE u204)

;; Contract constants
(define-constant MAX-FEE-BPS u1000) ;; Maximum 10% fee
(define-constant PRECISION u1000000) ;; For calculations
;; New constants for enhancements
(define-constant BLOCKS-PER-YEAR u52560) ;; Approximate blocks per year
(define-constant BASIS-POINTS u10000)
(define-constant MAX-YIELD-RATE u2000) ;; Maximum 20% annual yield

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var vault-manager principal tx-sender)
(define-data-var total-shares uint u0)
(define-data-var total-assets uint u0)
(define-data-var is-paused bool false)
(define-data-var management-fee-bps uint u100) ;; 1% default fee
(define-data-var is-initialized bool false)

;; New data variables for yield generation
(define-data-var annual-yield-rate uint u500) ;; 5% annual yield (in basis points)
(define-data-var last-yield-update uint u0)
(define-data-var accumulated-yield uint u0)

;; New data variables for risk management
(define-data-var daily-withdrawal-limit uint u1000000) ;; 1M STX daily limit
(define-data-var max-single-withdrawal-pct uint u1000) ;; 10% of total assets max
(define-data-var circuit-breaker-threshold uint u2000) ;; 20% price drop triggers circuit breaker
(define-data-var circuit-breaker-active bool false)
(define-data-var circuit-breaker-cooldown uint u144) ;; 24 hours in blocks
(define-data-var last-price-update uint u0)
(define-data-var historical-share-price uint u1000000)

;; Maps
(define-map user-shares principal uint)
(define-map user-deposits principal uint)
;; New maps for risk management
(define-map daily-withdrawals uint uint) ;; block-day -> total withdrawn

;; Private helper functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner)))

(define-private (is-vault-manager)
  (is-eq tx-sender (var-get vault-manager)))

(define-private (is-authorized)
  (or (is-contract-owner) (is-vault-manager)))

(define-private (check-not-paused)
  (if (var-get is-paused)
    (err ERR-VAULT-PAUSED)
    (ok true)))

(define-private (calculate-shares-for-deposit (deposit-amount uint))
  (let ((current-total-assets (var-get total-assets))
        (current-total-shares (var-get total-shares)))
    (if (is-eq current-total-assets u0)
      ;; First deposit: 1:1 ratio
      deposit-amount
      ;; Subsequent deposits: proportional to existing ratio
      (/ (* deposit-amount current-total-shares) current-total-assets))))

(define-private (calculate-assets-for-shares (share-amount uint))
  (let ((current-total-assets (var-get total-assets))
        (current-total-shares (var-get total-shares)))
    (if (is-eq current-total-shares u0)
      u0
      (/ (* share-amount current-total-assets) current-total-shares))))

(define-private (calculate-fee (amount uint))
  (/ (* amount (var-get management-fee-bps)) u10000))

(define-private (transfer-fee-if-needed (fee-amount uint))
  (if (> fee-amount u0)
    (match (as-contract (stx-transfer? fee-amount tx-sender (var-get vault-manager)))
      success (ok true)
      error (err ERR-TRANSFER-FAILED))
    (ok true)))

;; New private functions for yield generation
(define-private (calculate-pending-yield)
  (let ((current-block stacks-block-height)
        (last-update (var-get last-yield-update))
        (blocks-elapsed (- current-block last-update))
        (current-total-assets (var-get total-assets))
        (annual-rate (var-get annual-yield-rate)))
    (if (and (> blocks-elapsed u0) (> current-total-assets u0) (> last-update u0))
      (/ (* (* current-total-assets annual-rate) blocks-elapsed) 
         (* BASIS-POINTS BLOCKS-PER-YEAR))
      u0)))

(define-private (update-yield-internal)
  (let ((pending-yield (calculate-pending-yield)))
    (if (> pending-yield u0)
      (begin
        (var-set total-assets (+ (var-get total-assets) pending-yield))
        (var-set accumulated-yield (+ (var-get accumulated-yield) pending-yield))
        (var-set last-yield-update stacks-block-height)
        pending-yield)
      u0)))

;; New private functions for risk management - FIXED MATCH STATEMENT
(define-private (check-withdrawal-limits (amount uint))
  (let ((current-day (/ stacks-block-height u144))
        (daily-total (default-to u0 (map-get? daily-withdrawals current-day)))
        (current-total-assets (var-get total-assets))
        (max-single (/ (* current-total-assets (var-get max-single-withdrawal-pct)) u10000)))
    
    ;; Check single withdrawal limit
    (asserts! (<= amount max-single) (err ERR-WITHDRAWAL-TOO-LARGE))
    
    ;; Check daily limit
    (asserts! (<= (+ daily-total amount) (var-get daily-withdrawal-limit)) 
              (err ERR-DAILY-LIMIT-EXCEEDED))
    
    (ok true)))

(define-private (check-circuit-breaker)
  (if (var-get circuit-breaker-active)
    (err ERR-CIRCUIT-BREAKER-TRIGGERED)
    (let ((current-price (unwrap-panic (get-share-price)))
          (historical-price (var-get historical-share-price))
          (price-drop-pct (if (> historical-price u0)
                           (/ (* (- historical-price current-price) u10000) historical-price)
                           u0)))
      (if (> price-drop-pct (var-get circuit-breaker-threshold))
        (begin
          (var-set circuit-breaker-active true)
          (var-set last-price-update stacks-block-height)
          (err ERR-CIRCUIT-BREAKER-TRIGGERED))
        (ok true)))))

(define-private (update-daily-withdrawal-tracking (amount uint))
  (let ((current-day (/ stacks-block-height u144))
        (daily-total (default-to u0 (map-get? daily-withdrawals current-day))))
    (map-set daily-withdrawals current-day (+ daily-total amount))
    (ok true)))

;; Initialization function
(define-public (initialize (manager principal) (fee-bps uint))
  (begin
    (asserts! (not (var-get is-initialized)) (err ERR-ALREADY-INITIALIZED))
    (asserts! (is-contract-owner) (err ERR-NOT-AUTHORIZED))
    (asserts! (<= fee-bps MAX-FEE-BPS) (err ERR-INVALID-FEE))
    
    (var-set vault-manager manager)
    (var-set management-fee-bps fee-bps)
    (var-set is-initialized true)
    (var-set last-yield-update stacks-block-height)
    (var-set historical-share-price u1000000)
    (ok true)))

;; Admin functions
(define-public (pause-vault)
  (begin
    (asserts! (is-authorized) (err ERR-NOT-AUTHORIZED))
    (var-set is-paused true)
    (ok true)))

(define-public (unpause-vault)
  (begin
    (asserts! (is-authorized) (err ERR-NOT-AUTHORIZED))
    (var-set is-paused false)
    (ok true)))

(define-public (set-management-fee (new-fee-bps uint))
  (begin
    (asserts! (is-vault-manager) (err ERR-NOT-AUTHORIZED))
    (asserts! (<= new-fee-bps MAX-FEE-BPS) (err ERR-INVALID-FEE))
    (var-set management-fee-bps new-fee-bps)
    (ok new-fee-bps)))

(define-public (transfer-management (new-manager principal))
  (begin
    (asserts! (is-vault-manager) (err ERR-NOT-AUTHORIZED))
    (var-set vault-manager new-manager)
    (ok new-manager)))

;; New admin functions for yield management
(define-public (set-yield-rate (new-rate uint))
  (begin
    (asserts! (is-vault-manager) (err ERR-NOT-AUTHORIZED))
    (asserts! (<= new-rate MAX-YIELD-RATE) (err ERR-INVALID-YIELD-RATE))
    (update-yield-internal) ;; Update yield before changing rate
    (var-set annual-yield-rate new-rate)
    (ok new-rate)))

;; New admin functions for risk management
(define-public (set-withdrawal-limits (daily-limit uint) (single-withdrawal-pct uint))
  (begin
    (asserts! (is-vault-manager) (err ERR-NOT-AUTHORIZED))
    (asserts! (<= single-withdrawal-pct u5000) (err ERR-INVALID-FEE)) ;; Max 50%
    (var-set daily-withdrawal-limit daily-limit)
    (var-set max-single-withdrawal-pct single-withdrawal-pct)
    (ok true)))

(define-public (reset-circuit-breaker)
  (begin
    (asserts! (is-vault-manager) (err ERR-NOT-AUTHORIZED))
    (asserts! (>= (- stacks-block-height (var-get last-price-update)) 
                  (var-get circuit-breaker-cooldown)) 
              (err ERR-COOLDOWN-NOT-EXPIRED))
    
    (var-set circuit-breaker-active false)
    (var-set historical-share-price (unwrap-panic (get-share-price)))
    (ok true)))

;; Core vault functions
(define-public (deposit (amount uint))
  (begin
    (try! (check-not-paused))
    (asserts! (> amount u0) (err ERR-ZERO-AMOUNT))
    
    ;; Update yield before deposit
    (update-yield-internal)
    
    (let ((shares-to-mint (calculate-shares-for-deposit amount))
          (current-user-shares (default-to u0 (map-get? user-shares tx-sender)))
          (current-user-deposits (default-to u0 (map-get? user-deposits tx-sender))))
      
      ;; Transfer STX from user to contract
      (match (stx-transfer? amount tx-sender (as-contract tx-sender))
        success (begin
          ;; Update state
          (map-set user-shares tx-sender (+ current-user-shares shares-to-mint))
          (map-set user-deposits tx-sender (+ current-user-deposits amount))
          (var-set total-shares (+ (var-get total-shares) shares-to-mint))
          (var-set total-assets (+ (var-get total-assets) amount))
          (ok shares-to-mint))
        error (err ERR-TRANSFER-FAILED)))))

(define-public (withdraw (share-amount uint))
  (begin
    (try! (check-not-paused))
    (asserts! (> share-amount u0) (err ERR-ZERO-AMOUNT))
    
    ;; Update yield before withdrawal
    (update-yield-internal)
    
    ;; Check circuit breaker
    (try! (check-circuit-breaker))
    
    (let ((user-shares-balance (default-to u0 (map-get? user-shares tx-sender)))
          (assets-to-withdraw (calculate-assets-for-shares share-amount))
          (fee-amount (calculate-fee assets-to-withdraw))
          (net-withdrawal (- assets-to-withdraw fee-amount)))
      
      (asserts! (>= user-shares-balance share-amount) (err ERR-INSUFFICIENT-SHARES))
      (asserts! (>= (stx-get-balance (as-contract tx-sender)) assets-to-withdraw) (err ERR-INSUFFICIENT-BALANCE))
      
      ;; Check withdrawal limits
      (try! (check-withdrawal-limits assets-to-withdraw))
      
      ;; Update user shares
      (map-set user-shares tx-sender (- user-shares-balance share-amount))
      
      ;; Update vault totals
      (var-set total-shares (- (var-get total-shares) share-amount))
      (var-set total-assets (- (var-get total-assets) assets-to-withdraw))
      
      ;; Update withdrawal tracking
      (unwrap-panic (update-daily-withdrawal-tracking assets-to-withdraw))
      
      ;; Transfer assets to user
      (match (as-contract (stx-transfer? net-withdrawal tx-sender tx-sender))
        success (begin
          ;; Transfer fee to manager
          (try! (transfer-fee-if-needed fee-amount))
          (ok net-withdrawal))
        error (err ERR-TRANSFER-FAILED)))))

;; New public functions for yield management
(define-public (update-yield)
  (let ((yield-added (update-yield-internal)))
    (ok yield-added)))

(define-public (compound-yield)
  (begin
    (update-yield-internal)
    (ok true)))

;; Emergency functions
(define-public (emergency-withdraw)
  (begin
    (asserts! (is-vault-manager) (err ERR-NOT-AUTHORIZED))
    (let ((contract-balance (stx-get-balance (as-contract tx-sender))))
      (match (as-contract (stx-transfer? contract-balance tx-sender (var-get vault-manager)))
        success (begin
          (var-set total-assets u0)
          (ok contract-balance))
        error (err ERR-TRANSFER-FAILED)))))

;; Read-only functions
(define-read-only (get-vault-info)
  (ok {
    total-assets: (var-get total-assets),
    total-shares: (var-get total-shares),
    management-fee-bps: (var-get management-fee-bps),
    is-paused: (var-get is-paused),
    vault-manager: (var-get vault-manager),
    contract-balance: (stx-get-balance (as-contract tx-sender)),
    annual-yield-rate: (var-get annual-yield-rate),
    accumulated-yield: (var-get accumulated-yield),
    circuit-breaker-active: (var-get circuit-breaker-active)
  }))

(define-read-only (get-user-info (user principal))
  (let ((user-shares-balance (default-to u0 (map-get? user-shares user)))
        (user-deposit-total (default-to u0 (map-get? user-deposits user))))
    (ok {
      shares: user-shares-balance,
      total-deposits: user-deposit-total,
      withdrawable-assets: (if (> user-shares-balance u0)
                            (calculate-assets-for-shares user-shares-balance)
                            u0)
    })))

(define-read-only (get-share-price)
  (let ((current-total-assets (var-get total-assets))
        (current-total-shares (var-get total-shares)))
    (if (is-eq current-total-shares u0)
      (ok u1000000) ;; 1.0 in fixed point
      (ok (/ (* current-total-assets PRECISION) current-total-shares)))))

(define-read-only (calculate-deposit-shares (amount uint))
  (ok (calculate-shares-for-deposit amount)))

(define-read-only (calculate-withdrawal-amount (shares uint))
  (let ((gross-amount (calculate-assets-for-shares shares))
        (fee (calculate-fee gross-amount)))
    (ok {
      gross-amount: gross-amount,
      fee: fee,
      net-amount: (- gross-amount fee)
    })))

;; New read-only functions for yield information
(define-read-only (get-yield-info)
  (ok {
    annual-yield-rate: (var-get annual-yield-rate),
    last-yield-update: (var-get last-yield-update),
    accumulated-yield: (var-get accumulated-yield),
    pending-yield: (calculate-pending-yield)
  }))

;; New read-only functions for risk management
(define-read-only (get-risk-metrics)
  (ok {
    circuit-breaker-active: (var-get circuit-breaker-active),
    daily-withdrawal-limit: (var-get daily-withdrawal-limit),
    max-single-withdrawal-pct: (var-get max-single-withdrawal-pct),
    current-day-withdrawals: (default-to u0 (map-get? daily-withdrawals (/ stacks-block-height u144))),
    historical-share-price: (var-get historical-share-price)
  }))

(define-read-only (get-withdrawal-limits-info (amount uint))
  (let ((current-day (/ stacks-block-height u144))
        (daily-total (default-to u0 (map-get? daily-withdrawals current-day)))
        (current-total-assets (var-get total-assets))
        (max-single (/ (* current-total-assets (var-get max-single-withdrawal-pct)) u10000)))
    (ok {
      max-single-withdrawal: max-single,
      daily-limit: (var-get daily-withdrawal-limit),
      daily-used: daily-total,
      daily-remaining: (- (var-get daily-withdrawal-limit) daily-total),
      can-withdraw-amount: (and (<= amount max-single) 
                                (<= (+ daily-total amount) (var-get daily-withdrawal-limit)))
    })))

;; Contract balance check
(define-read-only (get-contract-balance)
  (ok (stx-get-balance (as-contract tx-sender))))
