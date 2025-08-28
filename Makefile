-include .env

.PHONY: all test deploy-sepolia deploy-anvil

build :; forge build

test :; forge test

install :; forge install cyfrin/foundry-devops@0.2.2 && forge install smartcontractkit/chainlink-brownie-contracts@1.1.1 && forge install foundry-rs/forge-std && forge install transmissions11/solmate@v6

deploy-sepolia :; 
	@forge script scripts/Raffle.s.sol:RaffleScript --rpc-url $(SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv

deploy-anvil :;
	@forge script scripts/Raffle.s.sol:RaffleScript --rpc-url $(ANVIL_RPC_URL) --private-key $(ANVIL_PRIVATE_KEY) --broadcast -vvvv