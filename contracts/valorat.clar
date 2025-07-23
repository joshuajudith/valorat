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

;; Contract constants
(define-constant MAX-FEE-BPS u1000) ;; Maximum 10% fee
(define-constant PRECISION u1000000) ;; For calculations

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var vault-manager principal tx-sender)
(define-data-var total-shares uint u0)
(define-data-var total-assets uint u0)
(define-data-var is-paused bool false)
(define-data-var management-fee-bps uint u100) ;; 1% default fee
(define-data-var is-initialized bool false)

;; Maps
(define-map user-shares principal uint)
(define-map user-deposits principal uint)

;; Private helper functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner)))

(define-private (is-vault-manager)
  (is-eq tx-sender (var-get vault-manager)))

(define-private (is-authorized)
  (or (is-contract-owner) (is-vault-manager)))

(define-private (check-not-paused)
  (if (var-get is-paused)
    (err ERR-VAULT-PAUSED)  ;; Fixed: ERR-VAULT-PAUSED is already u101, not (err u101)
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

;; Initialization function
(define-public (initialize (manager principal) (fee-bps uint))
  (begin
    (asserts! (not (var-get is-initialized)) (err ERR-ALREADY-INITIALIZED))
    (asserts! (is-contract-owner) (err ERR-NOT-AUTHORIZED))
    (asserts! (<= fee-bps MAX-FEE-BPS) (err ERR-INVALID-FEE))
    
    (var-set vault-manager manager)
    (var-set management-fee-bps fee-bps)
    (var-set is-initialized true)
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

;; Core vault functions
(define-public (deposit (amount uint))
  (begin
    (try! (check-not-paused))
    (asserts! (> amount u0) (err ERR-ZERO-AMOUNT))
    
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
    
    (let ((user-shares-balance (default-to u0 (map-get? user-shares tx-sender)))
          (assets-to-withdraw (calculate-assets-for-shares share-amount))
          (fee-amount (calculate-fee assets-to-withdraw))
          (net-withdrawal (- assets-to-withdraw fee-amount)))
      
      (asserts! (>= user-shares-balance share-amount) (err ERR-INSUFFICIENT-SHARES))
      (asserts! (>= (stx-get-balance (as-contract tx-sender)) assets-to-withdraw) (err ERR-INSUFFICIENT-BALANCE))
      
      ;; Update user shares
      (map-set user-shares tx-sender (- user-shares-balance share-amount))
      
      ;; Update vault totals
      (var-set total-shares (- (var-get total-shares) share-amount))
      (var-set total-assets (- (var-get total-assets) assets-to-withdraw))
      
      ;; Transfer assets to user
      (match (as-contract (stx-transfer? net-withdrawal tx-sender tx-sender))
        success (begin
          ;; Transfer fee to manager
          (try! (transfer-fee-if-needed fee-amount))
          (ok net-withdrawal))
        error (err ERR-TRANSFER-FAILED)))))

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
    contract-balance: (stx-get-balance (as-contract tx-sender))
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

;; Contract balance check
(define-read-only (get-contract-balance)
  (ok (stx-get-balance (as-contract tx-sender))))