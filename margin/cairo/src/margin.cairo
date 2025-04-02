#[starknet::contract]
pub mod Margin {
    use core::num::traits::Zero;
    use starknet::{
        event::EventEmitter,
        storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map},
        ContractAddress, get_contract_address, get_caller_address,
    };
    use margin::{
        interface::{
            IMargin, IERC20MetadataForPragmaDispatcherTrait, IERC20MetadataForPragmaDispatcher,
            IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait,
        },
        types::{Position, TokenAmount, PositionParameters, SwapData, EkuboSlippageLimits},
        constants::SCALE_NUMBER,
    };
    use margin::mocks::erc20_mock::{};
    use alexandria_math::{BitShift, U256BitShift};

    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use pragma_lib::types::{DataType, PragmaPricesResponse};

    use ekubo::{
        interfaces::core::{ICoreDispatcher, ILocker, ICoreDispatcherTrait},
        types::{keys::PoolKey, delta::Delta},
        components::shared_locker::{consume_callback_data, handle_delta, call_core_with_callback},
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    /// Ownable
    #[abi(embed_v0)]
    impl OwnableTwoStepMixinImpl =
        OwnableComponent::OwnableTwoStepMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[derive(starknet::Event, Drop)]
    struct Deposit {
        depositor: ContractAddress,
        token: ContractAddress,
        amount: TokenAmount,
    }

    #[derive(starknet::Event, Drop)]
    struct Withdraw {
        withdrawer: ContractAddress,
        token: ContractAddress,
        amount: TokenAmount,
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        Deposit: Deposit,
        Withdraw: Withdraw,
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        ekubo_core: ICoreDispatcher,
        treasury_balances: Map<(ContractAddress, ContractAddress), TokenAmount>,
        pools: Map<ContractAddress, TokenAmount>,
        positions: Map<ContractAddress, Position>,
        oracle_address: ContractAddress,
        risk_factors: Map<ContractAddress, u128>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, owner: ContractAddress, 
        ekubo_core: ICoreDispatcher, oracle_address: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.ekubo_core.write(ekubo_core);
        self.oracle_address.write(oracle_address);
    }

    /// @notice Calculates the health factor for a given contract address based on its position and associated risk factor.
    /// @dev The health factor is determined by multiplying the traded amount with the price of the initial token, the scaling constant (SCALE_NUMBER),
    ///      and the risk factor, then dividing by the product of the debt, the price of the debt token, and the scaling constant (SCALE_NUMBER).
    /// Requirements:
    /// - The traded_amount in the position must be greater than zero.
    /// - The debt in the position must be greater than zero.
    /// @param self A mutable reference to the contract state containing positions and risk factors.
    /// @param address The contract address used to retrieve the position and risk factor.
    /// @return u256 The computed health factor as a 256-bit unsigned integer.
    fn get_health_factor(ref self: ContractState, address: ContractAddress) -> u256 {
        let position = self.positions.entry(address).read();
        let risk_factor = self.risk_factors.entry(address).read();

        assert(position.traded_amount > 0, 'Traded amount is zero');
        assert(position.debt > 0, 'Debt is zero');
        
        (position.traded_amount * self.get_data(position.initial_token).price.into() * SCALE_NUMBER * risk_factor.into())
        / (position.debt * self.get_data(position.debt_token).price.into() * SCALE_NUMBER)
    }


    #[generate_trait]
    pub impl InternalImpl of InternalTrait {
        fn swap(ref self: ContractState, swap_data: SwapData) -> Delta {
            call_core_with_callback(self.ekubo_core.read(), @swap_data)
        }

        fn get_data(self: @ContractState, token: ContractAddress) -> PragmaPricesResponse {
            let token_symbol: felt252 = IERC20MetadataForPragmaDispatcher {
                contract_address: token,
            }
                .symbol();

            let token_symbol_u256: u256 = token_symbol.into();
            let pair_id = BitShift::shl(token_symbol_u256, 4) + '/USD';

            IPragmaOracleDispatcher { contract_address: self.oracle_address.read() }
                .get_data_median(
                    DataType::SpotEntry(pair_id.try_into().expect('pair id overflows')),
                )
        }
    }


    #[abi(embed_v0)]
    impl Margin of IMargin<ContractState> {
        /// Deposits specified amount of ERC20 tokens into the contract's treasury
        /// @param token The contract address of the ERC20 token to deposit
        /// @param amount The amount of tokens to deposit
        /// @dev Transfers tokens from caller to contract and updates balances
        fn deposit(ref self: ContractState, token: ContractAddress, amount: TokenAmount) {
            assert(amount.is_non_zero(), 'Amount is zero');
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let (depositor, contract) = (get_caller_address(), get_contract_address());

            assert(
                token_dispatcher.allowance(depositor, contract) >= amount, 'Insufficient allowance',
            );
            assert(token_dispatcher.balance_of(depositor) >= amount, 'Insufficient balance');

            let user_balance = self.treasury_balances.entry((depositor, token)).read();
            self.treasury_balances.entry((depositor, token)).write(user_balance + amount);

            self.pools.entry(token).write(self.pools.entry(token).read() + amount);
            token_dispatcher.transfer_from(depositor, contract, amount);

            self.emit(Deposit { depositor, token, amount });
        }

        fn withdraw(ref self: ContractState, token: ContractAddress, amount: TokenAmount) {
            assert(amount > 0, 'Withdraw amount is zero');

            let withdrawer = get_caller_address();

            let user_treasury_amount = self.treasury_balances.entry((withdrawer, token)).read();
            assert(amount <= user_treasury_amount, 'Insufficient user treasury');

            self.treasury_balances.entry((withdrawer, token)).write(user_treasury_amount - amount);
            IERC20Dispatcher { contract_address: token }.transfer(withdrawer, amount);

            self.pools.entry(token).write(self.pools.entry(token).read() - amount);
            self.emit(Withdraw { withdrawer, token, amount });
        }

        fn open_margin_position(
            ref self: ContractState,
            position_parameters: PositionParameters,
            pool_key: PoolKey,
            ekubo_limits: EkuboSlippageLimits,
        ) {}
        fn close_position(
            ref self: ContractState, pool_key: PoolKey, ekubo_limits: EkuboSlippageLimits,
        ) {}
        fn liquidate(
            ref self: ContractState,
            user: ContractAddress,
            pool_key: PoolKey,
            ekubo_limits: EkuboSlippageLimits,
        ) {}
    }

    #[abi(embed_v0)]
    impl Locker of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.ekubo_core.read();
            let SwapData { pool_key, params, caller } = consume_callback_data(core, data);
            let delta = core.swap(pool_key, params);

            handle_delta(core, pool_key.token0, delta.amount0, caller);
            handle_delta(core, pool_key.token1, delta.amount1, caller);

            let mut arr: Array<felt252> = ArrayTrait::new();
            Serde::serialize(@delta, ref arr);
            arr.span()
        }
    }
}
