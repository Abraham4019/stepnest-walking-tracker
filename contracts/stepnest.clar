;; StepNest Walking Tracker
;; A decentralized platform for tracking, sharing, and discovering walking/hiking routes on the Stacks blockchain.
;; This contract manages user profiles, routes, activities, and social interactions for the StepNest platform.

;; ========================================
;; Constants & Error Codes
;; ========================================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-USER-ALREADY-EXISTS (err u101))
(define-constant ERR-USER-NOT-FOUND (err u102))
(define-constant ERR-ROUTE-NOT-FOUND (err u103))
(define-constant ERR-ACTIVITY-NOT-FOUND (err u104))
(define-constant ERR-INVALID-PARAMS (err u105))
(define-constant ERR-ALREADY-FOLLOWING (err u106))
(define-constant ERR-NOT-FOLLOWING (err u107))
(define-constant ERR-CANNOT-FOLLOW-SELF (err u108))
(define-constant ERR-ALREADY-UPVOTED (err u109))
(define-constant ERR-CANNOT-MODIFY (err u110))

;; Privacy settings constants
(define-constant PRIVACY-PUBLIC u1)
(define-constant PRIVACY-FOLLOWERS u2)
(define-constant PRIVACY-PRIVATE u3)

;; ========================================
;; Data Maps & Variables
;; ========================================

;; User profiles
(define-map users
  { user-id: principal }
  {
    username: (string-utf8 50),
    bio: (string-utf8 500),
    joined-at: uint,
    total-distance: uint,
    total-activities: uint,
    current-streak: uint,
    longest-streak: uint,
    privacy-setting: uint,
    rewards-balance: uint
  }
)

;; Routes created by users
(define-map routes
  { route-id: uint }
  {
    creator: principal,
    name: (string-utf8 100),
    description: (string-utf8 500),
    distance: uint,
    elevation-gain: uint,
    location-start: (string-utf8 100),
    location-end: (string-utf8 100),
    coordinates: (string-ascii 1000), ;; GeoJSON format as string
    difficulty: uint,
    created-at: uint,
    upvotes: uint,
    privacy-setting: uint
  }
)

;; Individual walking activities
(define-map activities
  { activity-id: uint }
  {
    user-id: principal,
    route-id: (optional uint),
    distance: uint,
    elevation-gain: uint,
    duration: uint,
    started-at: uint,
    completed-at: uint,
    coordinates: (string-ascii 1000), ;; GeoJSON format as string
    notes: (string-utf8 500),
    privacy-setting: uint
  }
)

;; Social following relationships
(define-map follows
  { follower: principal, following: principal }
  { created-at: uint }
)

;; Route favorites/bookmarks
(define-map favorites
  { user-id: principal, route-id: uint }
  { added-at: uint }
)

;; Route upvotes 
(define-map upvotes
  { user-id: principal, route-id: uint }
  { upvoted-at: uint }
)

;; User route preferences for discovery
(define-map user-preferences
  { user-id: principal }
  {
    preferred-distance-min: uint,
    preferred-distance-max: uint,
    preferred-elevation-min: uint,
    preferred-elevation-max: uint,
    preferred-difficulty-min: uint,
    preferred-difficulty-max: uint,
    preferred-location: (string-utf8 100)
  }
)

;; Counters for generating IDs
(define-data-var next-route-id uint u1)
(define-data-var next-activity-id uint u1)

;; ========================================
;; Private Functions
;; ========================================

;; Checks if a user exists
(define-private (user-exists (user-id principal))
  (is-some (map-get? users { user-id: user-id }))
)

;; Checks if a route exists
(define-private (route-exists (route-id uint))
  (is-some (map-get? routes { route-id: route-id }))
)

;; Checks if user is authorized to view content based on privacy setting
(define-private (can-view-content (owner principal) (viewer principal) (privacy-setting uint))
  (or
    (is-eq owner viewer)
    (is-eq privacy-setting PRIVACY-PUBLIC)
    (and 
      (is-eq privacy-setting PRIVACY-FOLLOWERS)
      (is-following owner viewer)
    )
  )
)

;; Checks if user is following another user
(define-private (is-following (follower principal) (following principal))
  (is-some (map-get? follows { follower: follower, following: following }))
)

;; Updates user streak based on activity timestamps
(define-private (update-streak (user-id principal) (activity-time uint))
  (let (
    (user-info (unwrap! (map-get? users { user-id: user-id }) (err "User not found")))
    (current-streak (get current-streak user-info))
    (longest-streak (get longest-streak user-info))
    (one-day-in-seconds u86400)
    (now-timestamp (get-block-info? time (- block-height u1)))
    (current-time (default-to u0 now-timestamp))
    (time-diff (- current-time activity-time))
  )
  (if (< time-diff one-day-in-seconds)
    ;; Activity was within a day, increment streak
    (let (
      (new-streak (+ current-streak u1))
      (new-longest (if (> new-streak longest-streak) new-streak longest-streak))
    )
      (map-set users 
        { user-id: user-id }
        (merge user-info { 
          current-streak: new-streak, 
          longest-streak: new-longest
        })
      )
    )
    ;; Activity was not within a day, reset streak
    (map-set users
      { user-id: user-id }
      (merge user-info { current-streak: u1 })
    )
  ))
)

;; Award rewards based on activity and streaks
(define-private (process-rewards (user-id principal))
  (let (
    (user-info (unwrap! (map-get? users { user-id: user-id }) (err "User not found")))
    (current-streak (get current-streak user-info))
    (base-reward u10)
    (streak-bonus (if (> current-streak u5) (* u2 current-streak) u0))
    (total-reward (+ base-reward streak-bonus))
  )
    (map-set users
      { user-id: user-id }
      (merge user-info { 
        rewards-balance: (+ (get rewards-balance user-info) total-reward) 
      })
    )
  )
)

;; ========================================
;; Read-Only Functions
;; ========================================

;; Get user profile
(define-read-only (get-user-profile (user-id principal))
  (map-get? users { user-id: user-id })
)

;; Get route details 
(define-read-only (get-route (route-id uint) (viewer principal))
  (let (
    (route-data (map-get? routes { route-id: route-id }))
  )
    (match route-data
      route-info (if (can-view-content (get creator route-info) viewer (get privacy-setting route-info))
                   (some route-info)
                   none)
      none
    )
  )
)

;; Get activity details
(define-read-only (get-activity (activity-id uint) (viewer principal))
  (let (
    (activity-data (map-get? activities { activity-id: activity-id }))
  )
    (match activity-data
      activity-info (if (can-view-content (get user-id activity-info) viewer (get privacy-setting activity-info))
                      (some activity-info)
                      none)
      none
    )
  )
)

;; Check if user is following another user
(define-read-only (check-following (follower principal) (following principal))
  (is-some (map-get? follows { follower: follower, following: following }))
)

;; Get list of public routes (paginated)
(define-read-only (get-public-routes (start-idx uint) (end-idx uint))
  ;; This would ideally use list filtering functions but is simplified here
  ;; In a production implementation, this would need to be implemented with proper pagination
  ;; and filtering based on privacy settings
  (ok true)
)

;; Get user's favorite routes
(define-read-only (get-user-favorites (user-id principal) (viewer principal))
  ;; This would ideally return a list of routes that the user has favorited
  ;; Implementation simplified for clarity
  (ok true)
)

;; Get personalized route recommendations
(define-read-only (get-route-recommendations (user-id principal))
  ;; This would implement the recommendation algorithm using user preferences and past activities
  ;; Implementation simplified for clarity
  (ok true)
)

;; ========================================
;; Public Functions
;; ========================================

;; Create or update user profile
(define-public (register-user (username (string-utf8 50)) (bio (string-utf8 500)) (privacy-setting uint))
  (let (
    (user-id tx-sender)
    (now-timestamp (get-block-info? time (- block-height u1)))
    (current-time (default-to u0 now-timestamp))
  )
    (if (user-exists user-id)
      ;; Update existing user
      (let (
        (existing-user (unwrap! (map-get? users { user-id: user-id }) ERR-USER-NOT-FOUND))
      )
        (map-set users
          { user-id: user-id }
          (merge existing-user {
            username: username,
            bio: bio,
            privacy-setting: privacy-setting
          })
        )
        (ok true)
      )
      ;; Create new user
      (begin
        (map-set users
          { user-id: user-id }
          {
            username: username,
            bio: bio,
            joined-at: current-time,
            total-distance: u0,
            total-activities: u0,
            current-streak: u0,
            longest-streak: u0,
            privacy-setting: privacy-setting,
            rewards-balance: u0
          }
        )
        (ok true)
      )
    )
  )
)

;; Create a new route
(define-public (create-route 
    (name (string-utf8 100))
    (description (string-utf8 500))
    (distance uint)
    (elevation-gain uint)
    (location-start (string-utf8 100))
    (location-end (string-utf8 100))
    (coordinates (string-ascii 1000))
    (difficulty uint)
    (privacy-setting uint)
  )
  (let (
    (route-id (var-get next-route-id))
    (creator tx-sender)
    (now-timestamp (get-block-info? time (- block-height u1)))
    (current-time (default-to u0 now-timestamp))
  )
    (asserts! (user-exists creator) ERR-USER-NOT-FOUND)
    (asserts! (and (>= privacy-setting PRIVACY-PUBLIC) (<= privacy-setting PRIVACY-PRIVATE)) ERR-INVALID-PARAMS)
    
    ;; Create the route
    (map-set routes
      { route-id: route-id }
      {
        creator: creator,
        name: name,
        description: description,
        distance: distance,
        elevation-gain: elevation-gain,
        location-start: location-start,
        location-end: location-end,
        coordinates: coordinates,
        difficulty: difficulty,
        created-at: current-time,
        upvotes: u0,
        privacy-setting: privacy-setting
      }
    )
    
    ;; Increment route ID counter
    (var-set next-route-id (+ route-id u1))
    
    (ok route-id)
  )
)

;; Record a walking activity
(define-public (record-activity
    (route-id (optional uint))
    (distance uint)
    (elevation-gain uint)
    (duration uint)
    (started-at uint)
    (completed-at uint)
    (coordinates (string-ascii 1000))
    (notes (string-utf8 500))
    (privacy-setting uint)
  )
  (let (
    (activity-id (var-get next-activity-id))
    (user-id tx-sender)
    (now-timestamp (get-block-info? time (- block-height u1)))
    (current-time (default-to u0 now-timestamp))
  )
    (asserts! (user-exists user-id) ERR-USER-NOT-FOUND)
    (asserts! (and (>= privacy-setting PRIVACY-PUBLIC) (<= privacy-setting PRIVACY-PRIVATE)) ERR-INVALID-PARAMS)
    (asserts! (< started-at completed-at) ERR-INVALID-PARAMS)
    
    ;; Verify route exists if provided
    (match route-id
      some-id (asserts! (route-exists some-id) ERR-ROUTE-NOT-FOUND)
      none true
    )
    
    ;; Create the activity
    (map-set activities
      { activity-id: activity-id }
      {
        user-id: user-id,
        route-id: route-id,
        distance: distance,
        elevation-gain: elevation-gain,
        duration: duration,
        started-at: started-at,
        completed-at: completed-at,
        coordinates: coordinates,
        notes: notes,
        privacy-setting: privacy-setting
      }
    )
    
    ;; Update user stats
    (let (
      (user-info (unwrap! (map-get? users { user-id: user-id }) ERR-USER-NOT-FOUND))
    )
      (map-set users
        { user-id: user-id }
        (merge user-info {
          total-distance: (+ (get total-distance user-info) distance),
          total-activities: (+ (get total-activities user-info) u1)
        })
      )
    )
    
    ;; Update streak and process rewards
    (update-streak user-id completed-at)
    (process-rewards user-id)
    
    ;; Increment activity ID counter
    (var-set next-activity-id (+ activity-id u1))
    
    (ok activity-id)
  )
)

;; Follow another user
(define-public (follow-user (to-follow principal))
  (let (
    (follower tx-sender)
    (now-timestamp (get-block-info? time (- block-height u1)))
    (current-time (default-to u0 now-timestamp))
  )
    (asserts! (not (is-eq follower to-follow)) ERR-CANNOT-FOLLOW-SELF)
    (asserts! (user-exists follower) ERR-USER-NOT-FOUND)
    (asserts! (user-exists to-follow) ERR-USER-NOT-FOUND)
    (asserts! (not (is-following follower to-follow)) ERR-ALREADY-FOLLOWING)
    
    (map-set follows
      { follower: follower, following: to-follow }
      { created-at: current-time }
    )
    
    (ok true)
  )
)

;; Unfollow a user
(define-public (unfollow-user (to-unfollow principal))
  (let (
    (follower tx-sender)
  )
    (asserts! (is-following follower to-unfollow) ERR-NOT-FOLLOWING)
    
    (map-delete follows { follower: follower, following: to-unfollow })
    
    (ok true)
  )
)

;; Add a route to favorites
(define-public (add-favorite (route-id uint))
  (let (
    (user-id tx-sender)
    (now-timestamp (get-block-info? time (- block-height u1)))
    (current-time (default-to u0 now-timestamp))
  )
    (asserts! (user-exists user-id) ERR-USER-NOT-FOUND)
    (asserts! (route-exists route-id) ERR-ROUTE-NOT-FOUND)
    
    (map-set favorites
      { user-id: user-id, route-id: route-id }
      { added-at: current-time }
    )
    
    (ok true)
  )
)

;; Remove a route from favorites
(define-public (remove-favorite (route-id uint))
  (let (
    (user-id tx-sender)
  )
    (map-delete favorites { user-id: user-id, route-id: route-id })
    
    (ok true)
  )
)

;; Upvote a route
(define-public (upvote-route (route-id uint))
  (let (
    (user-id tx-sender)
    (now-timestamp (get-block-info? time (- block-height u1)))
    (current-time (default-to u0 now-timestamp))
  )
    (asserts! (user-exists user-id) ERR-USER-NOT-FOUND)
    (asserts! (route-exists route-id) ERR-ROUTE-NOT-FOUND)
    (asserts! (is-none (map-get? upvotes { user-id: user-id, route-id: route-id })) ERR-ALREADY-UPVOTED)
    
    ;; Record the upvote
    (map-set upvotes
      { user-id: user-id, route-id: route-id }
      { upvoted-at: current-time }
    )
    
    ;; Increment the route's upvote count
    (let (
      (route-info (unwrap! (map-get? routes { route-id: route-id }) ERR-ROUTE-NOT-FOUND))
    )
      (map-set routes
        { route-id: route-id }
        (merge route-info { upvotes: (+ (get upvotes route-info) u1) })
      )
    )
    
    (ok true)
  )
)

;; Update user preferences for route discovery
(define-public (update-preferences
    (preferred-distance-min uint)
    (preferred-distance-max uint)
    (preferred-elevation-min uint)
    (preferred-elevation-max uint)
    (preferred-difficulty-min uint)
    (preferred-difficulty-max uint)
    (preferred-location (string-utf8 100))
  )
  (let (
    (user-id tx-sender)
  )
    (asserts! (user-exists user-id) ERR-USER-NOT-FOUND)
    (asserts! (<= preferred-distance-min preferred-distance-max) ERR-INVALID-PARAMS)
    (asserts! (<= preferred-elevation-min preferred-elevation-max) ERR-INVALID-PARAMS)
    (asserts! (<= preferred-difficulty-min preferred-difficulty-max) ERR-INVALID-PARAMS)
    
    (map-set user-preferences
      { user-id: user-id }
      {
        preferred-distance-min: preferred-distance-min,
        preferred-distance-max: preferred-distance-max,
        preferred-elevation-min: preferred-elevation-min,
        preferred-elevation-max: preferred-elevation-max,
        preferred-difficulty-min: preferred-difficulty-min,
        preferred-difficulty-max: preferred-difficulty-max,
        preferred-location: preferred-location
      }
    )
    
    (ok true)
  )
)

;; Update route privacy settings
(define-public (update-route-privacy (route-id uint) (new-privacy-setting uint))
  (let (
    (user-id tx-sender)
  )
    (asserts! (route-exists route-id) ERR-ROUTE-NOT-FOUND)
    (asserts! (and (>= new-privacy-setting PRIVACY-PUBLIC) (<= new-privacy-setting PRIVACY-PRIVATE)) ERR-INVALID-PARAMS)
    
    (let (
      (route-info (unwrap! (map-get? routes { route-id: route-id }) ERR-ROUTE-NOT-FOUND))
    )
      (asserts! (is-eq user-id (get creator route-info)) ERR-NOT-AUTHORIZED)
      
      (map-set routes
        { route-id: route-id }
        (merge route-info { privacy-setting: new-privacy-setting })
      )
    )
    
    (ok true)
  )
)

;; Update activity privacy settings
(define-public (update-activity-privacy (activity-id uint) (new-privacy-setting uint))
  (let (
    (user-id tx-sender)
  )
    (asserts! (and (>= new-privacy-setting PRIVACY-PUBLIC) (<= new-privacy-setting PRIVACY-PRIVATE)) ERR-INVALID-PARAMS)
    
    (let (
      (activity-info (unwrap! (map-get? activities { activity-id: activity-id }) ERR-ACTIVITY-NOT-FOUND))
    )
      (asserts! (is-eq user-id (get user-id activity-info)) ERR-NOT-AUTHORIZED)
      
      (map-set activities
        { activity-id: activity-id }
        (merge activity-info { privacy-setting: new-privacy-setting })
      )
    )
    
    (ok true)
  )
)

;; Spend reward tokens (simplified implementation)
(define-public (spend-rewards (amount uint))
  (let (
    (user-id tx-sender)
  )
    (asserts! (user-exists user-id) ERR-USER-NOT-FOUND)
    
    (let (
      (user-info (unwrap! (map-get? users { user-id: user-id }) ERR-USER-NOT-FOUND))
      (current-balance (get rewards-balance user-info))
    )
      (asserts! (>= current-balance amount) ERR-INVALID-PARAMS)
      
      (map-set users
        { user-id: user-id }
        (merge user-info { rewards-balance: (- current-balance amount) })
      )
    )
    
    (ok true)
  )
)