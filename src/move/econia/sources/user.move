/// User-side book keeping and, optionally, collateral management.
///
/// # Market account custodians
///
/// For any given market, designated by a unique market ID, a user can
/// register multiple `MarketAccount`s, distinguished from one another
/// by their corresponding "general custodian ID". The custodian
/// capability having this ID is required to approve all market
/// transactions within the market account with the exception of generic
/// asset transfers, which are approved by a market-wide "generic
/// asset transfer custodian" in the case of a market having at least
/// one non-coin asset. When a general custodian ID is marked
/// `NO_CUSTODIAN`, a signing user is required to approve general
/// transactions rather than a custodian capability.
///
/// For example: market 5 has a generic (non-coin) base asset, a coin
/// quote asset, and generic asset transfer custodian ID 6. A user
/// opens two market accounts for market 5, one having general
/// custodian ID 7, and one having general custodian ID `NO_CUSTODIAN`.
/// When a user wishes to deposit base assets to the first market
/// account, custodian 6 is required for authorization. Then when the
/// user wishes to submit an ask, custodian 7 must approve it. As for
/// the second account, a user can deposit and withdraw quote coins,
/// and place or cancel trades via a signature, but custodian 6 is
/// still required to verify base deposits and withdrawals.
///
/// In other words, the market-wide generic asset transfer custodian ID
/// overrides the user-specific general custodian ID only when
/// depositing or withdrawing generic assets, otherwise the
/// user-specific general custodian ID takes precedence. Notably, a user
/// can register a `MarketAccount` having the same general custodian ID
/// and generic asset transfer custodian ID, and here, no overriding
/// takes place. For example, if market 8 requires generic asset
/// transfer custodian ID 9, a user can still register a market account
/// having general custodian ID 9, and then custodian 9 will be required
/// to authorize all of a user's transactions for the given
/// `MarketAccount`
///
/// # Market account ID
///
/// Since any of a user's `MarketAccount`s are specified by a
/// unique combination of market ID and general custodian ID, a user's
/// market account ID is thus defined as a 128-bit number, where the
/// most-significant ("first") 64 bits correspond to the market ID, and
/// the least-significant ("last") 64 bits correspond to the general
/// custodian ID.
///
/// For a market ID of `255` (`0b11111111`) and a general custodian ID
/// of `170` (`0b10101010`), for example, the corresponding market
/// account ID has the first 64 bits
/// `0000000000000000000000000000000000000000000000000000000011111111`
/// and the last 64 bits
/// `0000000000000000000000000000000000000000000000000000000010101010`,
/// corresponding to the base-10 integer `4703919738795935662250`. Note
/// that when a user opts to sign general transactions rather than
/// delegate to a general custodian, the market account ID uses a
/// general custodian ID of `NO_CUSTODIAN`, corresponding to `0`.
module econia::user {

    // Dependency planning stubs
    public(friend) fun return_0(): u8 {0}

    // Uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    use aptos_framework::coin::{Self, Coin};
    use aptos_std::type_info;
    use econia::critbit::{Self, CritBitTree};
    use econia::open_table;
    //use econia::order_id;
    use econia::registry::{Self, CustodianCapability};
    use std::option;
    use std::signer::address_of;

    // Uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    use econia::assets::{Self, BC, BG, QC, QG};

    // Test-only uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Friends >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    friend econia::market;

    // Friends <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    use econia::critbit::{u, u_long};

    // Test-only uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Structs >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Collateral map for given coin type, across all `MarketAccount`s
    struct Collateral<phantom CoinType> has key {
        /// Map from market account ID to coins held as collateral for
        /// given `MarketAccount`. Separated into different table
        /// entries to reduce transaction collisions across markets
        map: open_table::OpenTable<u128, Coin<CoinType>>
    }

    /// Represents a user's open orders and available assets for a given
    /// `MarketAccountInfo`
    struct MarketAccount has store {
        /// Base asset type info. When trading an
        /// `aptos_framework::coin::Coin`, corresponds to the phantom
        /// `CoinType`, for instance `MyCoin` rather than
        /// `Coin<MyCoin>`. Otherwise corresponds to `GenericAsset`, or
        /// a non-coin asset indicated by the market host.
        base_type_info: type_info::TypeInfo,
        /// Quote asset type info. When trading an
        /// `aptos_framework::coin::Coin`, corresponds to the phantom
        /// `CoinType`, for instance `MyCoin` rather than
        /// `Coin<MyCoin>`. Otherwise corresponds to `GenericAsset`, or
        /// a non-coin asset indicated by the market host.
        quote_type_info: type_info::TypeInfo,
        /// ID of custodian capability required to verify deposits and
        /// withdrawals of assets that are not coins. A "market-wide
        /// asset transfer custodian ID" that only applies to markets
        /// having at least one non-coin asset. For a market having
        /// one coin asset and one generic asset, only applies to the
        /// generic asset. Marked `PURE_COIN_PAIR` when base and quote
        /// types are both coins.
        generic_asset_transfer_custodian_id: u64,
        /// Map from order ID to size of outstanding order, measured in
        /// lots lefts to fill
        asks: CritBitTree<u64>,
        /// Map from order ID to size of outstanding order, measured in
        /// lots lefts to fill
        bids: CritBitTree<u64>,
        /// Total base asset units held as collateral
        base_total: u64,
        /// Base asset units available for withdraw
        base_available: u64,
        /// Amount `base_total` will increase to if all open bids fill
        base_ceiling: u64,
        /// Total quote asset units held as collateral
        quote_total: u64,
        /// Quote asset units available for withdraw
        quote_available: u64,
        /// Amount `quote_total` will increase to if all open asks fill
        quote_ceiling: u64
    }

    /// Market account map for all of a user's `MarketAccount`s
    struct MarketAccounts has key {
        /// Map from market account ID to `MarketAccount`. Separated
        /// into different table entries to reduce transaction
        /// collisions across markets
        map: open_table::OpenTable<u128, MarketAccount>
    }

    // Structs <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Error codes >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// When indicated asset is not in the market pair
    const E_NOT_IN_MARKET_PAIR: u64 = 0;
    /// When indicated custodian ID is not registered
    const E_UNREGISTERED_CUSTODIAN_ID: u64 = 1;
    /// When market account already exists for given market account ID
    const E_EXISTS_MARKET_ACCOUNT: u64 = 2;
    /// When indicated market account does not exist
    const E_NO_MARKET_ACCOUNT: u64 = 3;
    /// When not enough asset available for operation
    const E_NOT_ENOUGH_ASSET_AVAILABLE: u64 = 4;
    /// When depositing an asset would overflow total holdings ceiling
    const E_DEPOSIT_OVERFLOW_ASSET_CEILING: u64 = 5;
    /// When number of ticks to fill order overflows a `u64`
    const E_TICKS_OVERFLOW: u64 = 6;
    /// When a user does not a `MarketAccounts`
    const E_NO_MARKET_ACCOUNTS: u64 = 7;
    /// When proposed order indicates a size of 0
    const E_SIZE_0: u64 = 8;
    /// When proposed order indicates a price of 0
    const E_PRICE_0: u64 = 9;
    /// When filling proposed order overflows asset received from trade
    const E_OVERFLOW_ASSET_IN: u64 = 10;
    /// When filling proposed order overflows asset traded away
    const E_OVERFLOW_ASSET_OUT: u64 = 11;
    /// When asset indicated as generic actually corresponds to a coin
    const E_NOT_GENERIC_ASSET: u64 = 12;
    /// When asset indicated as coin actually corresponds to a generic
    const E_NOT_COIN_ASSET: u64 = 13;
    /// When indicated custodian unauthorized to perform operation
    const E_UNAUTHORIZED_CUSTODIAN: u64 = 14;

    // Error codes <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Flag for asks side
    const ASK: bool = true;
    /// Flag for asks side
    const BID: bool = false;
    /// Flag for asset transfer of coin type
    const COIN_ASSET_TRANSFER: u64 = 0;
    /// Positions to bitshift for operating on first 64 bits
    const FIRST_64: u8 = 64;
    /// `u64` bitmask with all bits set
    const HI_64: u64 = 0xffffffffffffffff;
    /// Flag for inbound coins
    const IN: bool = true;
    /// Custodian ID flag for no delegated custodian
    const NO_CUSTODIAN: u64 = 0;
    /// When both base and quote assets are coins
    const PURE_COIN_PAIR: u64 = 0;
    /// Flag for outbound coins
    const OUT: bool = false;

    // Constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Deposit `coins` of `CoinType` to `user`'s market account having
    /// `market_id` and `general_custodian_id`
    ///
    /// See wrapped function `deposit_asset()`
    public fun deposit_coins<CoinType>(
        user: address,
        market_id: u64,
        general_custodian_id: u64,
        coins: Coin<CoinType>
    ) acquires
        Collateral,
        MarketAccounts
    {
        deposit_asset<CoinType>(
            user,
            get_market_account_id(market_id, general_custodian_id),
            coin::value(&coins),
            option::some(coins),
            COIN_ASSET_TRANSFER
        )
    }

    /// Deposit `amount` of non-coin assets of `AssetType` to `user`'s
    /// market account having `market_id` and `general_custodian_id`,
    /// under authority of custodian indicated by
    /// `generic_asset_transfer_custodian_capability_ref`
    ///
    /// See wrapped function `deposit_asset()`
    ///
    /// # Abort conditions
    /// * If `AssetType` corresponds to the `CoinType` of an initialized
    ///   coin
    public fun deposit_generic_asset<AssetType>(
        user: address,
        market_id: u64,
        general_custodian_id: u64,
        amount: u64,
        generic_asset_transfer_custodian_capability_ref: &CustodianCapability
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Assert asset type does not correspond to an initialized coin
        assert!(!coin::is_coin_initialized<AssetType>(), E_NOT_GENERIC_ASSET);
        // Get generic asset transfer custodian ID
        let generic_asset_transfer_custodian_id = registry::custodian_id(
            generic_asset_transfer_custodian_capability_ref);
        deposit_asset<AssetType>( // Deposit generic asset
            user,
            get_market_account_id(market_id, general_custodian_id),
            amount,
            option::none<Coin<AssetType>>(),
            generic_asset_transfer_custodian_id
        )
    }

    /// Return market account ID for given `market_id` and
    /// `general_custodian_id`
    public fun get_market_account_id(
        market_id: u64,
        general_custodian_id: u64
    ): u128 {
        (market_id as u128) << FIRST_64 | (general_custodian_id as u128)
    }

    /// Get market ID encoded in `market_account_id`
    public fun get_market_id(
        market_account_id: u128
    ): u64 {
        (market_account_id >> FIRST_64 as u64)
    }

    /// Get general custodian ID encoded in `market_account_id`
    public fun get_general_custodian_id(
        market_account_id: u128
    ): u64 {
        (market_account_id & (HI_64 as u128) as u64)
    }

    // Public functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public entry functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[cmd]
    /// Transfer `amount` of coins of `CoinType` from `user`'s
    /// `aptos_framework::coin::CoinStore` to their `Collateral` for
    /// market account having `market_id`, `general_custodian_id`, and
    /// `generic_asset_transfer_custodian_id`.
    ///
    /// See wrapped function `deposit_coins()`
    public entry fun deposit_from_coinstore<CoinType>(
        user: &signer,
        market_id: u64,
        general_custodian_id: u64,
        amount: u64
    ) acquires
        Collateral,
        MarketAccounts
    {
        deposit_coins<CoinType>(
            address_of(user),
            market_id,
            general_custodian_id,
            coin::withdraw<CoinType>(user, amount)
        )
    }

    #[cmd]
    /// Register user with a market account
    ///
    /// # Type parameters
    /// * `BaseType`: Base type for market
    /// * `QuoteType`: Quote type for market
    ///
    /// # Parameters
    /// * `user`: Signing user
    /// * `market_id`: Serial ID of corresonding market
    /// * `general_custodian_id`: Serial ID of custodian capability
    ///   required for general account authorization, set to
    ///   `NO_CUSTODIAN` if signing user required for authorization on
    ///   market account
    ///
    /// # Abort conditions
    /// * If invalid `custodian_id`
    public entry fun register_market_account<
        BaseType,
        QuoteType
    >(
        user: &signer,
        market_id: u64,
        general_custodian_id: u64
    ) acquires
        Collateral,
        MarketAccounts
    {
        // If general custodian ID indicated, assert it is registered
        if (general_custodian_id != NO_CUSTODIAN) assert!(
            registry::is_registered_custodian_id(general_custodian_id),
            E_UNREGISTERED_CUSTODIAN_ID);
        // Get market account ID
        let market_account_id = get_market_account_id(
            market_id, general_custodian_id);
        // Register entry in market accounts map
        register_market_accounts_entry<BaseType, QuoteType>(
            user, market_account_id);
        // If base asset is coin, register collateral entry
        if (coin::is_coin_initialized<BaseType>())
            register_collateral_entry<BaseType>(user, market_account_id);
        // If quote asset is coin, register collateral entry
        if (coin::is_coin_initialized<QuoteType>())
            register_collateral_entry<QuoteType>(user, market_account_id);
    }

    // Public entry functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Private functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Deposit `amount` of `AssetType`, which may include
    /// `optional_coins`, to `user`'s market account
    /// having `market_account_id`, optionally verifying
    /// `generic_asset_transfer_custodian_id` in the case of depositing
    /// a generic asset.
    ///
    /// `generic_asset_transfer_custodian_id` is ignored when depositing
    /// a coin type.
    ///
    /// # Assumes
    /// * That if depositing a coin asset, `amount` matches value of
    ///   `optional_coins`
    /// * That when depositing a coin asset, if the market account
    ///   exists, then a corresponding collateral container does too
    ///
    /// # Abort conditions
    /// * If deposit would overflow the total asset holdings ceiling
    /// * If unauthorized `generic_asset_transfer_custodian_id` in the
    ///   case of depositing a generic asset
    fun deposit_asset<AssetType>(
        user: address,
        market_account_id: u128,
        amount: u64,
        optional_coins: option::Option<Coin<AssetType>>,
        generic_asset_transfer_custodian_id: u64
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Verify user has corresponding market account
        verify_market_account_exists(user, market_account_id);
        // Borrow mutable reference to market accounts map
        let market_accounts_map_ref_mut =
            &mut borrow_global_mut<MarketAccounts>(user).map;
        // Borrow mutable reference to total asset holdings, mutable
        // reference to amount of assets available for withdrawal,
        // mutable reference to total asset holdings ceiling, and
        // immutable reference to generic asset transfer custodian ID
        let (asset_total_ref_mut, asset_available_ref_mut,
             asset_ceiling_ref_mut, generic_asset_transfer_custodian_id_ref) =
                borrow_transfer_fields_mixed<AssetType>(
                    market_accounts_map_ref_mut, market_account_id);
        // Assert deposit does not overflow asset ceiling
        assert!(!((*asset_ceiling_ref_mut as u128) + (amount as u128) >
            (HI_64 as u128)), E_DEPOSIT_OVERFLOW_ASSET_CEILING);
        // Increment total asset holdings amount
        *asset_total_ref_mut = *asset_total_ref_mut + amount;
        // Increment assets available for withdrawal amount
        *asset_available_ref_mut = *asset_available_ref_mut + amount;
        // Increment total asset holdings ceiling amount
        *asset_ceiling_ref_mut = *asset_ceiling_ref_mut + amount;
        if (option::is_some(&optional_coins)) { // If asset is coin type
            // Borrow mutable reference to collateral map
            let collateral_map_ref_mut =
                &mut borrow_global_mut<Collateral<AssetType>>(user).map;
            // Borrow mutable reference to collateral for market account
            let collateral_ref_mut = open_table::borrow_mut(
                collateral_map_ref_mut, market_account_id);
            coin::merge( // Merge optional coins into collateral
                collateral_ref_mut, option::destroy_some(optional_coins));
        } else { // If asset is not coin type
            // Verify indicated generic asset transfer custodian ID
            assert!(generic_asset_transfer_custodian_id ==
                *generic_asset_transfer_custodian_id_ref,
                E_UNAUTHORIZED_CUSTODIAN);
            // Destroy empty option resource
            option::destroy_none(optional_coins);
        }
    }

    /// Borrow mutable/immutable references to `MarketAccount` fields
    /// required when depositing/withdrawing `AssetType`
    ///
    /// Look up the `MarketAccount` having `market_account_id` in the
    /// market accounts map indicated by `market_accounts_map_ref_mut`,
    /// then return a mutable reference to the amount of `AssetType`
    /// holdings, a mutable reference to the amount of `AssetType`
    /// available for withdraw, a mutable reference to `AssetType`
    /// ceiling, and an immutable reference to the generic asset
    /// transfer custodian ID for the given market
    ///
    /// # Returns
    /// * `u64`: Mutable reference to `MarketAccount.base_total` for
    ///   corresponding market account if `AssetType` is market base,
    ///   else mutable reference to `MarketAccount.quote_total`
    /// * `u64`: Mutable reference to `MarketAccount.base_available` for
    ///   corresponding market account if `AssetType` is market base,
    ///   else mutable reference to `MarketAccount.quote_available`
    /// * `u64`: Mutable reference to `MarketAccount.base_ceiling` for
    ///   corresponding market account if `AssetType` is market base,
    ///   else mutable reference to `MarketAccount.quote_ceiling`
    /// * `u64`: Immutable reference to generic asset transfer custodian
    ///   ID
    ///
    /// # Assumes
    /// * `market_accounts_map` has an entry with `market_account_id`
    ///
    /// # Abort conditions
    /// * If `AssetType` is neither base nor quote for given market
    ///   account
    fun borrow_transfer_fields_mixed<AssetType>(
        market_accounts_map_ref_mut:
            &mut open_table::OpenTable<u128, MarketAccount>,
        market_account_id: u128
    ): (
        &mut u64,
        &mut u64,
        &mut u64,
        &u64,
    ) {
        // Borrow mutable reference to market account
        let market_account_ref_mut =
            open_table::borrow_mut(
                market_accounts_map_ref_mut, market_account_id);
        // Get asset type info
        let asset_type_info = type_info::type_of<AssetType>();
        // If is base asset, return mutable references to base fields
        if (asset_type_info == market_account_ref_mut.base_type_info) {
            return (
                &mut market_account_ref_mut.base_total,
                &mut market_account_ref_mut.base_available,
                &mut market_account_ref_mut.base_ceiling,
                &market_account_ref_mut.generic_asset_transfer_custodian_id
            )
        // If is quote asset, return mutable references to quote fields
        } else if (asset_type_info == market_account_ref_mut.quote_type_info) {
            return (
                &mut market_account_ref_mut.quote_total,
                &mut market_account_ref_mut.quote_available,
                &mut market_account_ref_mut.quote_ceiling,
                &market_account_ref_mut.generic_asset_transfer_custodian_id
            )
        }; // Otherwise abort
        abort E_NOT_IN_MARKET_PAIR
    }

    /// Register `user` with `Collateral` map entry for given `CoinType`
    /// and `market_account_id`, initializing `Collateral` if it does
    /// not already exist.
    ///
    /// # Abort conditions
    /// * If user already has a `Collateral` entry for given
    ///   `market_account_id`
    fun register_collateral_entry<
        CoinType
    >(
        user: &signer,
        market_account_id: u128,
    ) acquires Collateral {
        let user_address = address_of(user); // Get user's address
        // If user does not have a collateral map initialized
        if(!exists<Collateral<CoinType>>(user_address)) {
            // Pack an empty one and move to their account
            move_to<Collateral<CoinType>>(user,
                Collateral{map: open_table::empty()})
        };
        // Borrow mutable reference to collateral map
        let collateral_map_ref_mut =
            &mut borrow_global_mut<Collateral<CoinType>>(user_address).map;
        // Assert no entry exists for given market account ID
        assert!(!open_table::contains(collateral_map_ref_mut,
            market_account_id), E_EXISTS_MARKET_ACCOUNT);
        // Add an empty entry for given market account ID
        open_table::add(collateral_map_ref_mut, market_account_id,
            coin::zero<CoinType>());
    }

    /// Register user with a `MarketAccounts` map entry for given
    /// `BaseType`, `QuoteType`, and `market_account_id`, initializing
    /// `MarketAccounts` if it does not already exist
    ///
    /// # Abort conditions
    /// * If user already has a `MarketAccounts` entry for given
    ///   `market_account_id`
    fun register_market_accounts_entry<
        BaseType,
        QuoteType
    >(
        user: &signer,
        market_account_id: u128,
    ) acquires MarketAccounts {
        // Get generic asset transfer custodian ID for verified market
        let generic_asset_transfer_custodian_id = registry::
            get_verified_market_custodian_id<BaseType, QuoteType>(
                get_market_id(market_account_id));
        let user_address = address_of(user); // Get user's address
        // If user does not have a market accounts map initialized
        if(!exists<MarketAccounts>(user_address)) {
            // Pack an empty one and move it to their account
            move_to<MarketAccounts>(user,
                MarketAccounts{map: open_table::empty()})
        };
        // Borrow mutable reference to market accounts map
        let market_accounts_map_ref_mut =
            &mut borrow_global_mut<MarketAccounts>(user_address).map;
        // Assert no entry exists for given market account ID
        assert!(!open_table::contains(market_accounts_map_ref_mut,
            market_account_id), E_EXISTS_MARKET_ACCOUNT);
        // Add an empty entry for given market account ID
        open_table::add(market_accounts_map_ref_mut, market_account_id,
            MarketAccount{
                base_type_info: type_info::type_of<BaseType>(),
                quote_type_info: type_info::type_of<QuoteType>(),
                generic_asset_transfer_custodian_id,
                asks: critbit::empty(),
                bids: critbit::empty(),
                base_total: 0,
                base_available: 0,
                base_ceiling: 0,
                quote_total: 0,
                quote_available: 0,
                quote_ceiling: 0
        });
    }

    /// Verify `user` has a market account with `market_account_id`
    ///
    /// # Abort conditions
    /// * If user does not have a `MarketAccounts`
    /// * If user does not have a `MarketAccount` for given
    ///   `market_account_id`
    fun verify_market_account_exists(
        user: address,
        market_account_id: u128
    ) acquires MarketAccounts {
        // Assert user has a market accounts map
        assert!(exists<MarketAccounts>(user), E_NO_MARKET_ACCOUNTS);
        // Borrow immutable reference to market accounts map
        let market_accounts_map_ref =
            &borrow_global<MarketAccounts>(user).map;
        // Assert user has an entry in map for market account ID
        assert!(open_table::contains(market_accounts_map_ref,
            market_account_id), E_NO_MARKET_ACCOUNT);
    }

    // Private functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    /// Return immutable reference to market account for given
    /// `market_id` and `general_custodian_id` in `MarketAccounts`
    /// indicated by `market_accounts_ref`
    fun borrow_market_account_test(
        market_id: u64,
        general_custodian_id: u64,
        market_accounts_ref: &MarketAccounts
    ): &MarketAccount {
        // Get corresponding market account ID
        let market_account_id = get_market_account_id(
            market_id, general_custodian_id);
        // Return immutable reference to market account
        open_table::borrow(&market_accounts_ref.map, market_account_id)
    }

    #[test_only]
    /// Return asset counts of `user`'s market account for given
    /// `market_id` and `general_custodian_id`
    public fun get_asset_counts_test(
        user: address,
        market_id: u64,
        general_custodian_id: u64
    ): (
        u64,
        u64,
        u64,
        u64,
        u64,
        u64
    ) acquires MarketAccounts {
        // Borrow immutable reference to user's market accounts
        let market_accounts_ref = borrow_global<MarketAccounts>(user);
        // Borrow immutable reference to corresponding market account
        let market_account_ref = borrow_market_account_test(
            market_id, general_custodian_id, market_accounts_ref);
        (
            market_account_ref.base_total,
            market_account_ref.base_available,
            market_account_ref.base_ceiling,
            market_account_ref.quote_total,
            market_account_ref.quote_available,
            market_account_ref.quote_ceiling,
        )
    }

    #[test_only]
    /// Return `Coin.value` of `user`'s entry in `Collateral` for given
    /// `AssetType`, `market_id`, and `general_custodian_id`
    public fun get_collateral_value_test<CoinType>(
        user: address,
        market_id: u64,
        general_custodian_id: u64
    ): u64
    acquires Collateral {
        // Get corresponding market account ID
        let market_account_id = get_market_account_id(
            market_id, general_custodian_id);
        // Borrow immutable reference to collateral map
        let collateral_map_ref =
            &borrow_global<Collateral<CoinType>>(user).map;
        // Borrow immutable reference to corresonding coin collateral
        let coin_ref = open_table::borrow(
            collateral_map_ref, market_account_id);
        coin::value(coin_ref) // Return value of coin
    }

    #[test_only]
    /// Return `true` if `user` has an entry in `Collateral` for given
    /// `AssetType`, `market_id`, and `general_custodian_id`
    public fun has_collateral_test<AssetType>(
        user: address,
        market_id: u64,
        general_custodian_id: u64
    ): bool
    acquires Collateral {
        // Return false if does not even have collateral map
        if (!exists<Collateral<AssetType>>(user)) return false;
        // Get corresponding market account ID
        let market_account_id = get_market_account_id(
            market_id, general_custodian_id);
        // Borrow immutable reference to collateral map
        let collateral_map_ref =
            &borrow_global<Collateral<AssetType>>(user).map;
        // Return if table contains entry for market account ID
        open_table::contains(collateral_map_ref, market_account_id)
    }

    #[test_only]
    /// Register user to trade on markets initialized via
    /// `registry::register_market_internal_multiple_test`, returning
    /// corresponding market account ID for each market
    public fun register_user_with_market_accounts_test(
        econia: &signer,
        user: &signer,
        general_custodian_id_pure_generic: u64,
        general_custodian_id_pure_coin: u64
    ): (
        u128,
        u128
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Init test markets, storing market IDs
        let  (_, _, _, market_id_pure_generic,
              _, _, _, market_id_pure_coin
        ) = registry::register_market_internal_multiple_test(econia);
        // Register user for pure generic market
        register_market_account<BG, QG>(
            user, market_id_pure_generic, general_custodian_id_pure_generic);
        // Register user for pure coin market
        register_market_account<BC, QC>(
            user, market_id_pure_coin, general_custodian_id_pure_coin);
        // Declare market account IDs
        let market_account_id_pure_generic = get_market_account_id(
            market_id_pure_generic, general_custodian_id_pure_generic);
        let market_account_id_pure_coin = get_market_account_id(
            market_id_pure_coin, general_custodian_id_pure_coin);
        // Return corresponding market account IDs
        (market_account_id_pure_generic, market_account_id_pure_coin)
    }

    // Test-only functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Tests >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test(
        econia = @econia,
        user = @user
    )]
    #[expected_failure(abort_code = 0)]
    /// Verify failure for asset not in pair
    fun test_borrow_transfer_fields_mixed_not_in_pair(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Register user with agnostic market account
        let (market_account_id, _) = register_user_with_market_accounts_test(
            econia, user, NO_CUSTODIAN, NO_CUSTODIAN);
        // Borrow mutable reference to market accounts map
        let market_accounts_map_ref_mut =
            &mut borrow_global_mut<MarketAccounts>(@user).map;
        borrow_transfer_fields_mixed<BC>( // Attempt invalid invocation
            market_accounts_map_ref_mut, market_account_id);
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    /// Verify state for depositing generic and coin assets
    fun test_deposit_assets_mixed(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Declare deposit parameters
        let coin_amount = 700;
        let generic_amount = 500;
        // Declare user-level general custodian ID
        let general_custodian_id = NO_CUSTODIAN;
        assets::init_coin_types(econia); // Initialize coin types
        registry::init_registry(econia); // Initalize registry
        // Register a custodian capability
        let custodian_capability = registry::register_custodian_capability();
        // Get ID of custodian capability
        let generic_asset_transfer_custodian_id = registry::custodian_id(
            &custodian_capability);
        // Register market with generic base asset and coin quote asset
        registry::register_market_internal<BG, QC>(@econia, 1, 2,
            generic_asset_transfer_custodian_id);
        let market_id = 0; // Declare market ID
        // Register user to trade on the account
        register_market_account<BG, QC>(user, market_id, general_custodian_id);
        coin::register_for_test<QC>(user); // Register coin store
        coin::deposit(@user, assets::mint<QC>(econia, coin_amount));
        // Deposit coin asset
        deposit_from_coinstore<QC>(user, market_id, general_custodian_id,
            coin_amount);
        // Deposit generic asset
        deposit_generic_asset<BG>(@user, market_id, general_custodian_id,
            generic_amount, &custodian_capability);
        // Destroy custodian capability
        registry::destroy_custodian_capability_test(custodian_capability);
        // Assert state
        let ( base_total,  base_available,  base_ceiling,
             quote_total, quote_available, quote_ceiling) =
            get_asset_counts_test(@user, market_id, general_custodian_id);
        assert!(base_total      == generic_amount, 0);
        assert!(base_available  == generic_amount, 0);
        assert!(base_ceiling    == generic_amount, 0);
        assert!(quote_total     == coin_amount,    0);
        assert!(quote_available == coin_amount,    0);
        assert!(quote_ceiling   == coin_amount,    0);
        assert!(!has_collateral_test<BG>(
            @user, market_id, general_custodian_id), 0);
        assert!(get_collateral_value_test<QC>(
            @user, market_id, general_custodian_id) == coin_amount, 0);
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    #[expected_failure(abort_code = 5)]
    /// Verify failure for deposit that overflows asset ceiling
    fun test_deposit_asset_overflow_ceiling(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Declare general custodian ID
        let general_custodian_id = NO_CUSTODIAN;
        // Register user with pure coin market account
        let (_, market_account_id) = register_user_with_market_accounts_test(
            econia, user, NO_CUSTODIAN, general_custodian_id);
        // Get market ID
        let market_id = get_market_id(market_account_id);
        // Deposit as many coins as possible to market account
        deposit_coins<BC>(@user, market_id, general_custodian_id,
            assets::mint<BC>(econia, HI_64));
        // Try to deposit one more coin
        deposit_coins<BC>(@user, market_id, general_custodian_id,
            assets::mint<BC>(econia, 1));
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    #[expected_failure(abort_code = 12)]
    /// Verify failure for calling with a coin type
    fun test_deposit_generic_asset_not_generic_asset(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        assets::init_coin_types(econia); // Initialize coin types
        registry::init_registry(econia); // Initalize registry
        // Register a custodian capability
        let custodian_capability = registry::register_custodian_capability();
        // Get ID of custodian capability
        let generic_asset_transfer_custodian_id = registry::custodian_id(
            &custodian_capability);
        // Register market with generic base asset and coin quote asset
        registry::register_market_internal<BG, QC>(@econia, 1, 2,
            generic_asset_transfer_custodian_id);
        let market_id = 0; // Declare market ID
        // Declare user-level general custodian ID
        let general_custodian_id = NO_CUSTODIAN;
        // Register user to trade on the account
        register_market_account<BG, QC>(user, market_id, general_custodian_id);
        // Attempt invalid invocation
        deposit_generic_asset<QC>(@user, market_id, general_custodian_id,
            500, &custodian_capability);
        // Destroy custodian capability
        registry::destroy_custodian_capability_test(custodian_capability);
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    #[expected_failure(abort_code = 14)]
    /// Verify failure for calling with unauthorized custodian
    fun test_deposit_generic_asset_unauthorized_custodian(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        assets::init_coin_types(econia); // Initialize coin types
        registry::init_registry(econia); // Initalize registry
        // Register a custodian capability
        let custodian_capability = registry::register_custodian_capability();
        // Get ID of custodian capability
        let generic_asset_transfer_custodian_id = registry::custodian_id(
            &custodian_capability);
        registry::register_market_internal<BG, QC>(@econia, 1, 2,
            generic_asset_transfer_custodian_id);
        let market_id = 0; // Declare market ID
        // Declare user-level general custodian ID
        let general_custodian_id = NO_CUSTODIAN;
        // Register user to trade on the account
        register_market_account<BG, QC>(user, market_id, general_custodian_id);
        // Get a custodian capability that is not authorized for generic
        // asset transfers
        let unauthorized_capability =
            registry::register_custodian_capability();
        // Attempt invalid invocation
        deposit_generic_asset<BG>(@user, market_id, general_custodian_id,
            500, &unauthorized_capability);
        // Destroy custodian capabilities
        registry::destroy_custodian_capability_test(custodian_capability);
        registry::destroy_custodian_capability_test(unauthorized_capability);
    }

    #[test]
    /// Verify expected return
    fun test_get_general_custodian_id() {
        // Define market_account id (60 characters on first two lines,
        // 8 on last)
        let market_account_id = u_long(
            b"111111111111111111111111111111111111111111111111111111111111",
            b"111100000000000000000000000000000000000000000000000000000000",
            b"10101010"
        );
        // Assert expected return
        assert!(get_general_custodian_id(market_account_id) ==
            (u(b"10101010") as u64), 0);
    }

    #[test]
    /// Verify expected return
    fun test_get_market_account_id() {
        // Declare market ID
        let market_id = (u(b"1101") as u64);
        // Declare general custodian ID
        let general_custodian_id = (u(b"1010") as u64);
        // Define expected return (60 characters on first two lines, 8
        // on last)
        let market_account_id = u_long(
            b"000000000000000000000000000000000000000000000000000000000000",
            b"110100000000000000000000000000000000000000000000000000000000",
            b"00001010"
        );
        // Assert expected return
        assert!(get_market_account_id(market_id, general_custodian_id) ==
            market_account_id, 0);
    }

    #[test]
    /// Verify expected return
    fun test_get_market_id() {
        // Define market_account id (60 characters on first two lines,
        // 8 on last)
        let market_account_id = u_long(
            b"000000000000000000000000000000000000000000000000000000001010",
            b"101011111111111111111111111111111111111111111111111111111111",
            b"11111111"
        );
        // Assert expected return
        assert!(get_market_id(market_account_id) ==
            (u(b"10101010") as u64), 0);
    }

    #[test(user = @user)]
    /// Verify registration for multiple market accounts
    fun test_register_collateral_entry(
        user: &signer
    ) acquires Collateral {
        // Declare market account IDs
        let market_account_id_1 = get_market_account_id(0, 1);
        let market_account_id_2 = get_market_account_id(0, NO_CUSTODIAN);
        // Register collateral entry
        register_collateral_entry<BC>(user, market_account_id_1);
        // Register another collateral entry
        register_collateral_entry<BC>(user, market_account_id_2);
        // Borrow immutable ref to collateral map
        let collateral_map_ref =
            &borrow_global<Collateral<BC>>(address_of(user)).map;
        // Borrow immutable ref to collateral for first market account
        let collateral_ref_1 =
            open_table::borrow(collateral_map_ref, market_account_id_1);
        // Assert amount
        assert!(coin::value(collateral_ref_1) == 0, 0);
        // Borrow immutable ref to collateral for second market account
        let collateral_ref_2 =
            open_table::borrow(collateral_map_ref, market_account_id_2);
        // Assert amount
        assert!(coin::value(collateral_ref_2) == 0, 0);
    }

    #[test(user = @user)]
    #[expected_failure(abort_code = 2)]
    /// Verify failure for given market account is already registered
    fun test_register_collateral_entry_already_registered(
        user: &signer
    ) acquires Collateral {
        // Declare market account ID
        let market_account_id = get_market_account_id(0, 1);
        // Register collateral entry
        register_collateral_entry<BC>(user, market_account_id);
        // Attempt invalid re-registration
        register_collateral_entry<BC>(user, market_account_id);
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    #[expected_failure(abort_code = 1)]
    /// Verify failure for invalid user-level custodian ID
    fun test_register_market_account_invalid_custodian_id(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Register test markets
        registry::register_market_internal_multiple_test(econia);
        let agnostic_test_market_id = 0; // Declare market ID
        // Attempt invalid registration
        register_market_account<BG, QG>(
            user, agnostic_test_market_id, 1000000000);
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    /// Verify successful market account registration
    fun test_register_market_accounts(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Init test markets, storing market IDs
        let  (_, _, _, market_id_agnostic,
              _, _, _, market_id_pure_coin
        ) = registry::register_market_internal_multiple_test(econia);
        // Declare custodian IDs
        let general_custodian_id_agnostic = NO_CUSTODIAN;
        let general_custodian_id_pure_coin = 2;
        // Register corresponding market accounts
        register_market_account<BG, QG>(
            user, market_id_agnostic, general_custodian_id_agnostic);
        register_market_account<BC, QC>(
            user, market_id_pure_coin, general_custodian_id_pure_coin);
        // Get market account ID for both market accounts
        let market_account_id_agnostic = get_market_account_id(
            market_id_agnostic, general_custodian_id_agnostic);
        let market_account_id_pure_coin = get_market_account_id(
            market_id_pure_coin, general_custodian_id_pure_coin);
        // Borrow immutable reference to market accounts map
        let market_accounts_map_ref =
            &borrow_global<MarketAccounts>(@user).map;
        // Assert entries added to table
        assert!(open_table::contains(
            market_accounts_map_ref, market_account_id_agnostic), 0);
        assert!(open_table::contains(
            market_accounts_map_ref, market_account_id_pure_coin), 0);
        // Assert no initialized collateral map for generic assets
        assert!(!exists<Collateral<BG>>(@user), 0);
        assert!(!exists<Collateral<QG>>(@user), 0);
        // Borrow immutable reference to base coin collateral map
        let collateral_map_ref =
            &borrow_global<Collateral<BC>>(@user).map;
        // Assert entry added for pure coin market account
        assert!(open_table::contains(collateral_map_ref,
            market_account_id_pure_coin), 0);
        // Borrow immutable reference to quote coin collateral map
        let collateral_map_ref =
            &borrow_global<Collateral<QC>>(@user).map;
        // Assert entry added for pure coin market account
        assert!(open_table::contains(collateral_map_ref,
            market_account_id_pure_coin), 0);
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    /// Verify registration for multiple market accounts
    fun test_register_market_accounts_entry(
        econia: &signer,
        user: &signer
    ) acquires MarketAccounts {
        // Declare market values
        let market_id_1 = 0;
        let general_custodian_id_1 = 1;
        let market_account_id_1 = get_market_account_id(market_id_1,
            general_custodian_id_1);
        let generic_asset_transfer_custodian_id_1 = PURE_COIN_PAIR;
        let market_id_2 = 0;
        let general_custodian_id_2 = NO_CUSTODIAN;
        let market_account_id_2 = get_market_account_id(market_id_2,
            general_custodian_id_2);
        let generic_asset_transfer_custodian_id_2 = PURE_COIN_PAIR;
        // Initialize registry
        registry::init_registry(econia);
        // Initialize coin types
        assets::init_coin_types(econia);
        // Set custodian to be valid
        registry::set_registered_custodian_test(general_custodian_id_1);
        // Register test markets
        registry::register_market_internal<BC, QC>(@econia, 1, 2,
            generic_asset_transfer_custodian_id_1);
        registry::register_market_internal<BC, QC>(@econia, 3, 4,
            generic_asset_transfer_custodian_id_2);
        // Register market accounts entry
        register_market_accounts_entry<BC, QC>(user, market_account_id_1);
        // Register market accounts entry
        register_market_accounts_entry<BC, QC>(user, market_account_id_2);
        // Borrow immutable reference to market accounts map
        let market_accounts_map_ref =
            &borrow_global<MarketAccounts>(address_of(user)).map;
        // Borrow immutable reference to first market account
        let market_account_ref_1 =
            open_table::borrow(market_accounts_map_ref, market_account_id_1);
        // Assert fields
        assert!(market_account_ref_1.base_type_info ==
            type_info::type_of<BC>(), 0);
        assert!(market_account_ref_1.quote_type_info ==
            type_info::type_of<QC>(), 0);
        assert!(market_account_ref_1.generic_asset_transfer_custodian_id ==
            generic_asset_transfer_custodian_id_1, 0);
        assert!(critbit::is_empty(&market_account_ref_1.asks), 0);
        assert!(critbit::is_empty(&market_account_ref_1.bids), 0);
        assert!(market_account_ref_1.base_total == 0, 0);
        assert!(market_account_ref_1.base_available == 0, 0);
        assert!(market_account_ref_1.base_ceiling == 0, 0);
        assert!(market_account_ref_1.quote_total == 0, 0);
        assert!(market_account_ref_1.quote_available == 0, 0);
        assert!(market_account_ref_1.quote_ceiling == 0, 0);
        // Borrow immutable reference to second market account
        let market_account_ref_2 =
            open_table::borrow(market_accounts_map_ref, market_account_id_2);
        // Assert fields
        assert!(market_account_ref_2.base_type_info ==
            type_info::type_of<BC>(), 0);
        assert!(market_account_ref_2.quote_type_info ==
            type_info::type_of<QC>(), 0);
        assert!(market_account_ref_2.generic_asset_transfer_custodian_id ==
            generic_asset_transfer_custodian_id_2, 0);
        assert!(critbit::is_empty(&market_account_ref_2.asks), 0);
        assert!(critbit::is_empty(&market_account_ref_2.bids), 0);
        assert!(market_account_ref_2.base_total == 0, 0);
        assert!(market_account_ref_2.base_available == 0, 0);
        assert!(market_account_ref_2.base_ceiling == 0, 0);
        assert!(market_account_ref_2.quote_total == 0, 0);
        assert!(market_account_ref_2.quote_available == 0, 0);
        assert!(market_account_ref_2.quote_ceiling == 0, 0);
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    #[expected_failure(abort_code = 2)]
    /// Verify failure for attempting to re-register market account
    fun test_register_market_accounts_entry_already_registered(
        econia: &signer,
        user: &signer
    ) acquires MarketAccounts {
        // Declare market values
        let market_id_1 = 0;
        let general_custodian_id_1 = 1;
        let market_account_id_1 = get_market_account_id(market_id_1,
            general_custodian_id_1);
        let generic_asset_transfer_custodian_id_1 = PURE_COIN_PAIR;
        // Initialize registry
        registry::init_registry(econia);
        // Initialize coin types
        assets::init_coin_types(econia);
        // Set custodian to be valid
        registry::set_registered_custodian_test(general_custodian_id_1);
        // Register test markets
        registry::register_market_internal<BC, QC>(@econia, 1, 2,
            generic_asset_transfer_custodian_id_1);
        // Register market accounts entry
        register_market_accounts_entry<BC, QC>(user, market_account_id_1);
        // Register market accounts entry
        register_market_accounts_entry<BC, QC>(user, market_account_id_1);
    }

    #[test]
    #[expected_failure(abort_code = 7)]
    /// Verify failure for no market accounts
    fun test_verify_market_account_exists_no_market_accounts()
    acquires MarketAccounts {
        // Attempt invalid invocation
        verify_market_account_exists(@user, get_market_account_id(1, 2));
    }

    #[test(
        econia = @econia,
        user = @user
    )]
    #[expected_failure(abort_code = 3)]
    /// Verify failure for wrong market account
    fun test_verify_market_account_exists_wrong_market_account(
        econia: &signer,
        user: &signer
    ) acquires
        Collateral,
        MarketAccounts
    {
        // Register user with pure generic market account
        let (market_account_id, _) = register_user_with_market_accounts_test(
            econia, user, NO_CUSTODIAN, NO_CUSTODIAN);
        // Attempt invalid existence verification
        verify_market_account_exists(@user, market_account_id + 1);
    }

    // Tests <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

}