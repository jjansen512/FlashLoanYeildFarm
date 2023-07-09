pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@aave/protocol-v2/contracts/interfaces/ILendingPool.sol';
import '@uniswap/v3-periphery/contracts/interfaces/IUniswapV3Router.sol';
import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol'; // import

interface ILendingPool {
	function flashLoan(
		address _receiver,
		address[] calldata _reserveTokens,
		uint256[] calldata _amounts,
		uint256[] calldata _modes,
		address _onBehalfOf,
		bytes calldata _params,
		uint16 _referralCode
	) external;
}

interface IUniswapV3Router {
	function addLiquidity(
		address tokenA,
		address tokenB,
		uint24 fee,
		int24 tickLower,
		int24 tickUpper,
		uint128 amountDesired,
		uint128 amountMin,
		uint128 amountMax,
		address recipient,
		uint256 deadline
	) external returns (uint256 amountA, uint256 amountB, uint128 liquidity);
}

interface AggregatorV3Interface {
	function latestRoundData()
		external
		view
		returns (
			uint80 roundId,
			int256 answer,
			uint256 startedAt,
			uint256 updatedAt,
			uint80 answeredInRound
		);
}

contract FlashLoaner {
	// USDC token address on mainnet
	address constant USDC_ADDRESS = 0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48;

	// Aave lending pool address on mainnet
	address constant AAVE_LENDING_POOL_ADDRESS =
		0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;

	// Uniswap V3 router address on mainnet
	address constant UNISWAP_V3_ROUTER_ADDRESS =
		0xE592427A0AEce92De3Edee1F18E0157C05861564;

	// Uniswap V3 pool address for USDC/ETH pair on mainnet
	address constant UNISWAP_V3_POOL_ADDRESS =
		0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

	// Fast Gas / Gwei price feed address on mainnet
	address constant FAST_GAS_PRICE_FEED_ADDRESS =
		0x16924ae9C2ac6cdbC9D6bB16FAfCD38BeD560936;

	// Uniswap V3 router interface
	IUniswapV3Router public uniswapRouter;

	// Chainlink aggregator interface
	AggregatorV3Interface public fastGasPriceFeed; // add Chainlink interface

	constructor() {
		uniswapRouter = IUniswapV3Router(UNISWAP_V3_ROUTER_ADDRESS);
		fastGasPriceFeed = AggregatorV3Interface(FAST_GAS_PRICE_FEED_ADDRESS); // create Chainlink instance
	}

	function initiateFlashLoan(uint256 amount) external {
		// get the balance of USDC in this contract
		uint256 balance = ERC20(USDC_ADDRESS).balanceOf(address(this));

		// check if the requested amount is less than or equal to 67% of the balance
		require(amount <= (balance * 67) / 100, 'Amount exceeds limit');

		// create an array of assets to be borrowed
		address[] memory assets = new address[](1);
		assets[0] = USDC_ADDRESS;

		// create an array of amounts to be borrowed
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = amount;

		// create an array of modes for the flash loan
		// 0 = no debt, 1 = stable, 2 = variable
		uint256[] memory modes = new uint256[](1);
		modes[0] = 0;

		// get the lending pool instance
		ILendingPool lendingPool = ILendingPool(AAVE_LENDING_POOL_ADDRESS);

		// estimate the gas cost for the flash loan transaction
		uint256 gasCost = gasleft();

		// get the current gas price from the Chainlink oracle in gwei
		(, int256 gasPrice, , , ) = fastGasPriceFeed.latestRoundData();

		// convert the gas price to wei
		gasPrice = gasPrice * 1e9;

		// calculate the total gas fee in wei
		uint256 gasFee = uint256(gasPrice) * gasCost;

		// calculate the flash loan fee in wei
		uint256 flashLoanFee = (amount * 9) / 10000;

		// check if the balance is enough to cover the fees and gas
		require(
			balance >= amount + flashLoanFee + gasFee,
			'Insufficient funds'
		);

		// initiate the flash loan
		lendingPool.flashLoan(
			address(this),
			assets,
			amounts,
			modes,
			address(this),
			bytes(''),
			0
		);
	}

	function executeOperation(
		address[] calldata assets,
		uint256[] calldata amounts,
		uint256[] calldata premiums,
		address initiator,
		bytes calldata params
	) external returns (bool) {
		// check that the caller is the lending pool
		require(msg.sender == AAVE_LENDING_POOL_ADDRESS, 'Invalid caller');

		// check that the initiator is this contract
		require(initiator == address(this), 'Invalid initiator');

		// get the amount of USDC borrowed
		uint256 amount = amounts[0];

		// get the fee for the flash loan
		uint256 fee = premiums[0];

		// invest the borrowed USDC in the Uniswap V3 liquidity pool
		// this will require approving the USDC transfer to the Uniswap router
		// and calling the addLiquidity function with the appropriate parameters
		// this will also return some LP tokens to this contract

		try ERC20(USDC_ADDRESS).approve(UNISWAP_V3_ROUTER_ADDRESS, amount) {
			(
				uint128 liquidity,
				uint256 amount0,
				uint256 amount1
			) = uniswapRouter.addLiquidity(
					USDC_ADDRESS,
					WETH9(0xc778417E063141139Fce010982780140Aa0cD5Ab),
					UNISWAP_V3_POOL_ADDRESS,
					amount,
					0,
					0,
					address(this),
					block.timestamp
				);
		} catch Error(string memory reason) {
			// revert the transaction with the reason
			revert(reason);
		} catch {
			// revert the transaction with a generic message
			revert('Investment failed');
		}

		// take out a collateral loan from the Uniswap V3 liquidity pool
		// this will require approving the LP token transfer to the Uniswap router
		// and calling the borrow function with the appropriate parameters
		// this will also return some USDC and some debt tokens to this contract

		try
			ERC20(UNISWAP_V3_POOL_ADDRESS).approve(
				UNISWAP_V3_ROUTER_ADDRESS,
				liquidity
			)
		{
			(uint256 amount0, uint256 amount1) = uniswapRouter.borrow(
				USDC_ADDRESS,
				WETH9(0xc778417E063141139Fce010982780140Aa0cD5Ab),
				UNISWAP_V3_POOL_ADDRESS,
				liquidity,
				amount + fee,
				0,
				address(this),
				block.timestamp
			);
		} catch Error(string memory reason) {
			// revert the transaction with the reason
			revert(reason);
		} catch {
			// revert the transaction with a generic message
			revert('Borrowing failed');
		}

		// repay the flash loan plus the fee using the USDC from the collateral loan
		// this will require approving the USDC transfer to the lending pool
		ERC20(USDC_ADDRESS).approve(AAVE_LENDING_POOL_ADDRESS, amount + fee);
		return true;
	}
}
