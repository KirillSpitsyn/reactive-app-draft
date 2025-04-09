// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "reactive-lib/src/interfaces/IReactive.sol";
import "reactive-lib/src/abstract-base/AbstractReactive.sol";

/**
 * @title ReactiveEscrowManager
 * @notice This contract bridges escrow contracts across multiple chains with an adjudicator marketplace
 * contract through Reactive.network. It handles dynamic subscriptions to deployed escrow contracts,
 * routes dispute events to the adjudicator marketplace, and relays adjudicator assignments and rulings
 * back to escrow contracts.
 */
contract ReactiveEscrowManager is IReactive, AbstractReactive {
    // Constants for topic values (keccak256 hashes of event signatures)
    uint256 private constant ESCROW_DEPLOYED_TOPIC_0 = 0xbf81906d85c322e2e0e31f4aaf86bd8dcde8d12f3258276c031899960e2e5c11; // keccak256("EscrowDeployed(string,address)")
    uint256 private constant DISPUTE_RAISED_TOPIC_0 = 0xe94479a9f7e1952cc78f2d68165860d955fc8fb6f956da4c7d5f8332a95f9d60; // keccak256("DisputeRaised(string,string)")
    uint256 private constant ADJUDICATOR_ASSIGNED_TOPIC_0 = 0x56f8a38e7ebc3a7a366d88a1d608d9f0da2e22d54e70d1039dc8a87a15e8b4d9; // keccak256("AdjudicatorAssigned(string,address)")
    uint256 private constant ESCROW_COMPLETED_TOPIC_0 = 0x1f6d9c29e577abbf86b9bff647709f5185cd84db7a7dc8a73917c8c481e10dd8; // keccak256("EscrowCompleted(string)")
    uint256 private constant RULING_ISSUED_TOPIC_0 = 0x3d55442cc5b6f50b85e0fe0dcda994b23a72a4bd079ba4e9ea567129a941d0c1; // keccak256("RulingIssued(string,uint256,uint256)")

    // Chain IDs (to be configured based on deployment)
    uint256 public adjudicatorChainId;
    
    // Gas limits for different types of callbacks
    uint64 private constant SUBSCRIPTION_GAS_LIMIT = 300000;
    uint64 private constant DISPUTE_RELAY_GAS_LIMIT = 500000;
    uint64 private constant ADJUDICATOR_RELAY_GAS_LIMIT = 400000;
    uint64 private constant RULING_RELAY_GAS_LIMIT = 600000;

    // Factory contracts on various chains (keyed by chain ID)
    mapping(uint256 => address[]) public factoryContracts;
    
    // Map escrow identifiers to their contract addresses and chain IDs
    mapping(string => address) public escrowContracts;
    mapping(string => uint256) public escrowChainIds;
    
    // Dispute tracking for state validation
    enum DisputeStatus { None, Pending, AdjudicatorAssigned, Resolved }
    mapping(string => DisputeStatus) public disputeStatuses;
    
    // Adjudicator marketplace contract address
    address public adjudicatorMarketplaceAddress;

    // Events to log important actions
    event EscrowSubscribed(string escrowId, address escrowContract, uint256 chainId);
    event EscrowUnsubscribed(string escrowId, address escrowContract, uint256 chainId);
    event DisputeRelayed(string escrowId, string reason, uint256 fromChainId, uint256 toChainId);
    event AdjudicatorRelayed(string escrowId, address adjudicator, uint256 fromChainId, uint256 toChainId);
    event RulingRelayed(string escrowId, uint256 fixedFee, uint256 payoutBasisPoints, uint256 fromChainId, uint256 toChainId);
    event FailedCallback(string escrowId, bytes payload, string reason);

    // --- Event emitted to generate a callback to the Reactive Network system contract ---
    event Callback(uint256 targetChainId, address targetAddress, uint256 gasLimit, bytes payload);

    /**
     * @notice Constructor for the ReactiveEscrowManager
     * @param _adjudicatorChainId Chain ID where the adjudicator marketplace is deployed
     * @param _adjudicatorMarketplaceAddress Address of the adjudicator marketplace contract
     */
    constructor(
        uint256 _adjudicatorChainId,
        address _adjudicatorMarketplaceAddress
    ) payable {
        require(_adjudicatorChainId > 0, "Invalid chain ID");
        
        adjudicatorChainId = _adjudicatorChainId;
        
        if (_adjudicatorMarketplaceAddress != address(0)) {
            adjudicatorMarketplaceAddress = _adjudicatorMarketplaceAddress;
            
            // Initial subscriptions to adjudicator events if address is known at deployment
            if (!vm) {
                service.subscribe(
                    _adjudicatorChainId,
                    _adjudicatorMarketplaceAddress,
                    RULING_ISSUED_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.subscribe(
                    _adjudicatorChainId,
                    _adjudicatorMarketplaceAddress,
                    ADJUDICATOR_ASSIGNED_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }
        }
    }

    /**
     * @notice Add a new factory contract to watch for escrow deployment events
     * @param chainId The chain ID where the factory is deployed
     * @param factory The address of the factory contract
     */
    function addFactoryContract(uint256 chainId, address factory) external onlyOwner {
        require(factory != address(0), "Invalid factory address");
        require(chainId > 0, "Invalid chain ID");
        
        // Check if factory already added
        address[] storage factories = factoryContracts[chainId];
        for (uint i = 0; i < factories.length; i++) {
            if (factories[i] == factory) {
                revert("Factory already added");
            }
        }
        
        // Add the factory to the list and subscribe to its events
        factoryContracts[chainId].push(factory);
        
        if (!vm) {
            service.subscribe(
                chainId,
                factory,
                ESCROW_DEPLOYED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    /**
     * @notice Remove a factory contract
     * @param chainId The chain ID where the factory is deployed
     * @param factory The address of the factory contract to remove
     */
    function removeFactoryContract(uint256 chainId, address factory) external onlyOwner {
        address[] storage factories = factoryContracts[chainId];
        bool found = false;
        uint indexToRemove;
        
        for (uint i = 0; i < factories.length; i++) {
            if (factories[i] == factory) {
                found = true;
                indexToRemove = i;
                break;
            }
        }
        
        require(found, "Factory not found");
        
        // Unsubscribe from the factory's events
        if (!vm) {
            service.unsubscribe(
                chainId,
                factory,
                ESCROW_DEPLOYED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        
        // Remove factory from the array by replacing with the last element and popping
        factories[indexToRemove] = factories[factories.length - 1];
        factories.pop();
    }

    /**
     * @notice Set the adjudicator marketplace contract address
     * @param _adjudicatorMarketplaceAddress The new address
     */
    function setAdjudicatorMarketplaceAddress(address _adjudicatorMarketplaceAddress) external onlyOwner {
        require(_adjudicatorMarketplaceAddress != address(0), "Invalid adjudicator marketplace address");
        
        // Unsubscribe from the old address if it was set
        if (adjudicatorMarketplaceAddress != address(0) && !vm) {
            service.unsubscribe(
                adjudicatorChainId,
                adjudicatorMarketplaceAddress,
                RULING_ISSUED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.unsubscribe(
                adjudicatorChainId,
                adjudicatorMarketplaceAddress,
                ADJUDICATOR_ASSIGNED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        
        adjudicatorMarketplaceAddress = _adjudicatorMarketplaceAddress;
        
        // Subscribe to the new address
        if (!vm) {
            service.subscribe(
                adjudicatorChainId,
                _adjudicatorMarketplaceAddress,
                RULING_ISSUED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.subscribe(
                adjudicatorChainId,
                _adjudicatorMarketplaceAddress,
                ADJUDICATOR_ASSIGNED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    /**
     * @notice Set the adjudicator chain ID
     * @param _adjudicatorChainId The new chain ID
     */
    function setAdjudicatorChainId(uint256 _adjudicatorChainId) external onlyOwner {
        require(_adjudicatorChainId > 0, "Invalid chain ID");
        
        // If adjudicator address is set, we need to update subscriptions
        if (adjudicatorMarketplaceAddress != address(0) && !vm) {
            // Unsubscribe from old chain ID
            service.unsubscribe(
                adjudicatorChainId,
                adjudicatorMarketplaceAddress,
                RULING_ISSUED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.unsubscribe(
                adjudicatorChainId,
                adjudicatorMarketplaceAddress,
                ADJUDICATOR_ASSIGNED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            // Subscribe to new chain ID
            service.subscribe(
                _adjudicatorChainId,
                adjudicatorMarketplaceAddress,
                RULING_ISSUED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.subscribe(
                _adjudicatorChainId,
                adjudicatorMarketplaceAddress,
                ADJUDICATOR_ASSIGNED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        
        adjudicatorChainId = _adjudicatorChainId;
    }

    /**
     * @notice The main react() method processes incoming events from the Reactive Network
     * @param chain_id Origin chain ID of the event
     * @param originatingContract Contract address that emitted the event
     * @param topic_0 Primary topic indicating event type
     * @param topic_1 Secondary topic (varies by event type)
     * @param topic_2 Tertiary topic (varies by event type)
     * @param topic_3 Fourth topic (varies by event type)
     * @param data The ABI-encoded event data
     * @param block_number Block number of the event
     * @param op_code Operation code
     */
    function react(
        uint256 chain_id,
        address originatingContract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3,
        bytes calldata data,
        uint256 block_number,
        uint256 op_code
    ) external vmOnly {
        if (topic_0 == ESCROW_DEPLOYED_TOPIC_0) {
            // New escrow deployment detected
            // Validate factory is registered for this chain
            bool validFactory = false;
            address[] storage factories = factoryContracts[chain_id];
            for (uint i = 0; i < factories.length; i++) {
                if (factories[i] == originatingContract) {
                    validFactory = true;
                    break;
                }
            }
            require(validFactory, "Event from unregistered factory");
            
            handleEscrowDeployed(chain_id, originatingContract, data);
        } else if (topic_0 == DISPUTE_RAISED_TOPIC_0) {
            // Dispute raised on an escrow contract
            handleDisputeRaised(chain_id, originatingContract, data);
        } else if (topic_0 == ADJUDICATOR_ASSIGNED_TOPIC_0) {
            // Adjudicator assigned by the marketplace
            handleAdjudicatorAssigned(chain_id, originatingContract, data);
        } else if (topic_0 == RULING_ISSUED_TOPIC_0) {
            // Ruling issued by the adjudicator
            handleRulingIssued(chain_id, originatingContract, data);
        } else if (topic_0 == ESCROW_COMPLETED_TOPIC_0) {
            // Escrow contract completed
            handleEscrowCompleted(chain_id, originatingContract, data);
        }
    }

    /**
     * @notice Handle an EscrowDeployed event
     * @param chain_id Origin chain ID
     * @param factory Factory contract that deployed the escrow
     * @param data Event data containing escrowId and escrowContract address
     */
    function handleEscrowDeployed(uint256 chain_id, address factory, bytes calldata data) internal {
        // Decode escrow identifier and contract address from event data
        (string memory escrowId, address escrowContract) = abi.decode(data, (string, address));
        require(escrowContract != address(0), "Invalid escrow contract address");
        require(bytes(escrowId).length > 0, "Empty escrow identifier");
        
        // Ensure this escrow ID hasn't been registered before
        require(escrowContracts[escrowId] == address(0), "Escrow ID already registered");

        // Store mapping of escrow ID to contract address and chain ID
        escrowContracts[escrowId] = escrowContract;
        escrowChainIds[escrowId] = chain_id;

        // Subscribe to the DisputeRaised event from this escrow
        if (!vm) {
            service.subscribe(
                chain_id,
                escrowContract,
                DISPUTE_RAISED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // Also subscribe to the EscrowCompleted event from this escrow
            service.subscribe(
                chain_id,
                escrowContract,
                ESCROW_COMPLETED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }

        // Log subscription
        emit EscrowSubscribed(escrowId, escrowContract, chain_id);
    }

    /**
     * @notice Handle a DisputeRaised event
     * @param chain_id Origin chain ID
     * @param escrowContract Escrow contract that raised the dispute
     * @param data Event data containing escrowId and dispute reason
     */
    function handleDisputeRaised(uint256 chain_id, address escrowContract, bytes calldata data) internal {
        // Decode escrow identifier and dispute reason from event data
        (string memory escrowId, string memory disputeReason) = abi.decode(data, (string, string));
        
        // Validate originating contract matches stored escrow address
        require(escrowContract == escrowContracts[escrowId], "Event from unexpected escrow");
        
        // Validate dispute state transitions
        require(disputeStatuses[escrowId] == DisputeStatus.None, "Dispute already in progress");
        
        // Update dispute status
        disputeStatuses[escrowId] = DisputeStatus.Pending;

        // Generate callback to relay the dispute to the adjudicator marketplace
        bytes memory payload = abi.encodeWithSignature(
            "requestAdjudicator(string,string,address,uint256)",
            escrowId,
            disputeReason,
            escrowContract,
            chain_id
        );
        emit Callback(adjudicatorChainId, adjudicatorMarketplaceAddress, DISPUTE_RELAY_GAS_LIMIT, payload);

        // Log dispute relay
        emit DisputeRelayed(escrowId, disputeReason, chain_id, adjudicatorChainId);
    }

    /**
     * @notice Handle an AdjudicatorAssigned event
     * @param chain_id Origin chain ID (should be adjudicator chain)
     * @param adjudicatorContract Adjudicator marketplace contract
     * @param data Event data containing escrowId and adjudicator address
     */
    function handleAdjudicatorAssigned(uint256 chain_id, address adjudicatorContract, bytes calldata data) internal {
        // Verify the event is from the adjudicator marketplace
        require(adjudicatorContract == adjudicatorMarketplaceAddress, "Invalid adjudicator contract");
        require(chain_id == adjudicatorChainId, "Event from unexpected chain");

        // Decode escrow identifier and adjudicator address from event data
        (string memory escrowId, address adjudicator) = abi.decode(data, (string, address));
        require(adjudicator != address(0), "Invalid adjudicator address");

        // Look up the escrow contract address and chain ID
        address escrowContract = escrowContracts[escrowId];
        uint256 escrowChainId = escrowChainIds[escrowId];
        require(escrowContract != address(0), "Unknown escrow identifier");
        
        // Validate dispute state transitions
        require(
            disputeStatuses[escrowId] == DisputeStatus.Pending,
            "Invalid dispute status for adjudicator assignment"
        );
        
        // Update dispute status
        disputeStatuses[escrowId] = DisputeStatus.AdjudicatorAssigned;

        // Generate callback to set the adjudicator on the escrow contract
        bytes memory payload = abi.encodeWithSignature(
            "setAdjudicator(address)",
            adjudicator
        );
        emit Callback(escrowChainId, escrowContract, ADJUDICATOR_RELAY_GAS_LIMIT, payload);

        // Log adjudicator relay
        emit AdjudicatorRelayed(escrowId, adjudicator, chain_id, escrowChainId);
    }

    /**
     * @notice Handle a RulingIssued event
     * @param chain_id Origin chain ID (should be adjudicator chain)
     * @param adjudicatorContract Adjudicator marketplace contract
     * @param data Event data containing escrowId, fixedFee, and payoutBasisPoints
     */
    function handleRulingIssued(uint256 chain_id, address adjudicatorContract, bytes calldata data) internal {
        // Verify the event is from the adjudicator marketplace
        require(adjudicatorContract == adjudicatorMarketplaceAddress, "Invalid adjudicator contract");
        require(chain_id == adjudicatorChainId, "Event from unexpected chain");

        // Decode escrow identifier, fixed fee, and payout basis points from event data
        (string memory escrowId, uint256 fixedFee, uint256 payoutBasisPoints) = abi.decode(data, (string, uint256, uint256));
        require(payoutBasisPoints <= 10000, "Invalid basis points");

        // Look up the escrow contract address and chain ID
        address escrowContract = escrowContracts[escrowId];
        uint256 escrowChainId = escrowChainIds[escrowId];
        require(escrowContract != address(0), "Unknown escrow identifier");
        
        // Validate dispute state transitions
        require(
            disputeStatuses[escrowId] == DisputeStatus.AdjudicatorAssigned, 
            "Invalid dispute status for ruling"
        );
        
        // Update dispute status
        disputeStatuses[escrowId] = DisputeStatus.Resolved;

        // Generate callback to finalize the dispute on the escrow contract
        bytes memory payload = abi.encodeWithSignature(
            "finalizeDispute(uint256,uint256)",
            fixedFee,
            payoutBasisPoints
        );
        emit Callback(escrowChainId, escrowContract, RULING_RELAY_GAS_LIMIT, payload);

        // Log ruling relay
        emit RulingRelayed(escrowId, fixedFee, payoutBasisPoints, chain_id, escrowChainId);
    }

    /**
     * @notice Handle an EscrowCompleted event
     * @param chain_id Origin chain ID
     * @param escrowContract Escrow contract that completed
     * @param data Event data containing escrowId
     */
    function handleEscrowCompleted(uint256 chain_id, address escrowContract, bytes calldata data) internal {
        // Decode escrow identifier from event data
        (string memory escrowId) = abi.decode(data, (string));
        
        // Validate originating contract matches stored escrow address
        require(escrowContract == escrowContracts[escrowId], "Event from unexpected escrow");

        // Unsubscribe from the escrow's DisputeRaised and EscrowCompleted events
        if (!vm) {
            service.unsubscribe(
                chain_id,
                escrowContract,
                DISPUTE_RAISED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            service.unsubscribe(
                chain_id,
                escrowContract,
                ESCROW_COMPLETED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }

        // Store values before deletion for event emission
        address completedEscrow = escrowContracts[escrowId];
        uint256 completedChainId = escrowChainIds[escrowId];
        
        // Delete mappings to prevent state bloat
        delete escrowContracts[escrowId];
        delete escrowChainIds[escrowId];
        delete disputeStatuses[escrowId];

        // Log unsubscription
        emit EscrowUnsubscribed(escrowId, completedEscrow, completedChainId);
    }

    /**
     * @notice Manual resolution for a failed callback (administrative function)
     * @param escrowId The escrow identifier
     * @param chainId The chain ID where the escrow is deployed
     * @param payload The callback payload to retry
     */
    function retryCallback(string calldata escrowId, uint256 chainId, bytes calldata payload) external onlyOwner {
        address escrowContract = escrowContracts[escrowId];
        require(escrowContract != address(0), "Unknown escrow identifier");
        require(escrowChainIds[escrowId] == chainId, "Chain ID mismatch");
        
        // Re-emit the callback
        emit Callback(chainId, escrowContract, RULING_RELAY_GAS_LIMIT, payload);
    }

    /**
     * @notice Allows the owner to fund the contract with more REACT tokens for operations
     */
    function refillReactTokens() external payable onlyOwner {
        // No additional logic needed, the payable modifier will handle the deposit
    }

    /**
     * @notice Allows the owner to withdraw REACT tokens if needed
     * @param amount The amount of REACT tokens to withdraw
     */
    function withdrawReactTokens(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        payable(owner()).transfer(amount);
    }

    /**
     * @notice Get dispute status for an escrow
     * @param escrowId The escrow identifier
     * @return status The current dispute status (0=None, 1=Pending, 2=AdjudicatorAssigned, 3=Resolved)
     */
    function getDisputeStatus(string calldata escrowId) external view returns (DisputeStatus) {
        return disputeStatuses[escrowId];
    }

    /**
     * @notice Check if a factory is registered for a chain
     * @param chainId The chain ID to check
     * @param factory The factory address to check
     * @return isRegistered Whether the factory is registered
     */
    function isFactoryRegistered(uint256 chainId, address factory) external view returns (bool) {
        address[] storage factories = factoryContracts[chainId];
        for (uint i = 0; i < factories.length; i++) {
            if (factories[i] == factory) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Get the number of registered factories for a chain
     * @param chainId The chain ID to check
     * @return count The number of registered factories
     */
    function getFactoryCount(uint256 chainId) external view returns (uint256) {
        return factoryContracts[chainId].length;
    }
}
