pragma solidity ^0.5.0;

// Import base Initializable contract
import "@openzeppelin/upgrades/contracts/Initializable.sol";
// Import interface and library from OpenZeppelin contracts
import "../zeppelin/upgradable/lifecycle/UpgradablePausable.sol";
import "../zeppelin/upgradable/ownership/UpgradableOwnable.sol";

import "../zeppelin/token/ERC20/ERC20Detailed.sol";
import "../zeppelin/token/ERC20/SafeERC20.sol";
import "../zeppelin/utils/Address.sol";
import "../zeppelin/math/SafeMath.sol";

import "../IBridge.sol";
import "../SideToken.sol";
import "../SideTokenFactory.sol";
import "../AllowTokens.sol";

contract Bridge_upgrade_test is Initializable, IBridge, IERC777Recipient, UpgradablePausable, UpgradableOwnable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20Detailed;
    using Address for address;

    address private federation;
    uint256 private crossingPayment;
    string public symbolPrefix;
    uint256 public lastDay;
    uint256 public spentToday;

    mapping (address => SideToken) public mappedTokens; // OirignalToken => SideToken
    mapping (address => address) public originalTokens; // SideToken => OriginalToken
    mapping (address => bool) public knownTokens; // OriginalToken => true
    mapping(bytes32 => bool) processed; // ProcessedHash => true
    AllowTokens public allowTokens;
    SideTokenFactory public sideTokenFactory;

    event FederationChanged(address _newFederation);

    // solium-disable-next-line max-len
    function initialize(address _manager, address _federation, address _allowTokens, address _sideTokenFactory, string memory _symbolPrefix) public initializer {
        require(bytes(_symbolPrefix).length > 0, "Empty symbol prefix");
        require(_allowTokens != address(0), "Missing AllowTokens contract address");
        require(_manager != address(0), "Manager is empty");
        UpgradableOwnable.initialize(_manager);
        UpgradablePausable.initialize(_manager);
        symbolPrefix = _symbolPrefix;
        allowTokens = AllowTokens(_allowTokens);
        sideTokenFactory = SideTokenFactory(_sideTokenFactory);
        // solium-disable-next-line security/no-block-members
        lastDay = now;
        spentToday = 0;
        _changeFederation(_federation);
    }

    function version() public pure returns (string memory) {
        return "test";
    }

    modifier onlyFederation() {
        require(msg.sender == federation, "Bridge: Caller is not the Federation");
        _;
    }
    function acceptTransfer(
        address tokenAddress,
        address receiver,
        uint256 amount,
        string memory symbol,
        bytes32 blockHash,
        bytes32 transactionHash,
        uint32 logIndex
    ) public  onlyFederation whenNotPaused returns(bool) {
        require(!transactionWasProcessed(blockHash, transactionHash, receiver, amount, logIndex), "Transaction already processed");

        processToken(tokenAddress, symbol);
        processTransaction(blockHash, transactionHash, receiver, amount, logIndex);

        if (isMappedToken(tokenAddress)) {
            SideToken sideToken = mappedTokens[tokenAddress];
            sideToken.operatorMint(receiver, amount, "", "");
        }
        else {
            require(knownTokens[tokenAddress], "Bridge: Token address is not in knownTokens");
            ERC20Detailed token = ERC20Detailed(tokenAddress);
            token.safeTransfer(receiver, amount);
        }
        emit AcceptedCrossTransfer(tokenAddress, receiver, amount);
        return true;
    }

    /**
     * ERC-20 tokens approve and transferFrom pattern
     * See https://eips.ethereum.org/EIPS/eip-20#transferfrom
     */
    function receiveTokens(address tokenToUse, uint256 amount) public payable whenNotPaused returns(bool){
        validateToken(tokenToUse, amount);
        address sender = _msgSender();
        require(!sender.isContract(), "Bridge: Contracts can't cross tokens to their addresses");
        //Transfer the tokens on IERC20, they should be already Approved for the bridge Address to use them
        sendIncentiveToEventsCrossers(msg.value);
        crossTokens(tokenToUse, msg.sender, amount, "");
        ERC20Detailed(tokenToUse).safeTransferFrom(msg.sender, address(this), amount);
        return true;
    }

    /**
     * ERC-677 and ERC-223 implementation for Receiving Tokens Contracts
     * See https://github.com/ethereum/EIPs/issues/677 for details
     * See https://github.com/ethereum/EIPs/issues/223 for details
     */
    function tokenFallback(address from, uint amount, bytes memory userData) public whenNotPaused payable returns (bool) {
        //This can only be used with trusted contracts
        require(allowTokens.isValidatingAllowedTokens(), "Bridge: onTokenTransfer needs to have validateAllowedTokens enabled");
        validateToken(_msgSender(), amount);
        //TODO cant make it payable find a work around
        sendIncentiveToEventsCrossers(msg.value);
        return crossTokens(_msgSender(), from, amount, userData);
    }


    /**
     * ERC-777 tokensReceived hook allows to send tokens to a contract and notify it in a single transaction
     * See https://eips.ethereum.org/EIPS/eip-777#motivation for details
     */
    function tokensReceived (
        address,
        address from,
        address to,
        uint amount,
        bytes memory userData,
        bytes memory
    ) public whenNotPaused {
        //Hook from ERC777
        require(to == address(this), "Bridge: This contract is not the address recieving the tokens");
        /**
        * TODO add Balance check
        */
        validateToken(msg.sender, amount);
        //TODO cant make it payable find a work around
        sendIncentiveToEventsCrossers(0);
        crossTokens(msg.sender, from, amount, userData);
    }

    function crossTokens(address tokenToUse, address from, uint256 amount, bytes memory userData)
    private returns (bool) {
        if (isSideToken(tokenToUse)) {
            sideTokenCrossingBack(from, SideToken(tokenToUse), amount, userData);
        } else {
            require(allowTokens.isTokenAllowed(tokenToUse), "Token is not allowed for transfer");
            mainTokenCrossing(from, tokenToUse, amount, userData);
        }
        return true;
    }

    function sendIncentiveToEventsCrossers(uint256 payment) private {
        require(payment >= crossingPayment, "Bridge: Insufficient coins sent for crossingPayment");
        //Send the payment to the MultiSig of the Federation
        address payable receiver = address(uint160(owner()));
        receiver.transfer(payment);
    }

    function sideTokenCrossingBack(address from, SideToken tokenToUse, uint256 amount, bytes memory userData) private {
        tokenToUse.burn(amount, userData);
        emit Cross(originalTokens[address(tokenToUse)], from, amount, tokenToUse.symbol(), userData);
    }

    function mainTokenCrossing(address from, address tokenToUse, uint256 amount, bytes memory userData) private {
        knownTokens[tokenToUse] = true;
        emit Cross(tokenToUse, from, amount, (ERC20Detailed(tokenToUse)).symbol(), userData);
    }

    function processToken(address token, string memory symbol) private {
        if (knownTokens[token])
            return;

        SideToken sideToken = mappedTokens[token];

        if (address(sideToken) == address(0)) {
            string memory newSymbol = string(abi.encodePacked(symbolPrefix, symbol));
            sideToken = sideTokenFactory.createSideToken(newSymbol, newSymbol);
            mappedTokens[token] = sideToken;
            address sideTokenAddress = address(sideToken);
            originalTokens[sideTokenAddress] = token;
            emit NewSideToken(sideTokenAddress, token, newSymbol);
        }
    }

    function validateToken(address tokenToUse, uint256 amount) private {
        ERC20Detailed detailedTokenToUse = ERC20Detailed(tokenToUse);
        require(detailedTokenToUse.decimals() == 18, "Bridge: Token has decimals other than 18");
        require(bytes(detailedTokenToUse.symbol()).length != 0, "Birdge: Token doesn't have a symbol");
        require(amount <= allowTokens.getMaxTokensAllowed(), "Bridge: The amount of tokens to transfer is greater than allowed");
        require(isUnderDailyLimit(amount), "Bridge: The amount of tokens to transfer is over the daily limit");
    }

    function isSideToken(address token) private view returns (bool) {
        return originalTokens[token] != address(0);
    }

    function isMappedToken(address token) private view returns (bool) {
        return address(mappedTokens[token]) != address(0);
    }

    function getTransactionCompiledId(
        bytes32 _blockHash,
        bytes32 _transactionHash,
        address _receiver,
        uint256 _amount,
        uint32 _logIndex
    )
        private pure returns(bytes32)
    {
        return keccak256(abi.encodePacked(_blockHash, _transactionHash, _receiver, _amount, _logIndex));
    }

    function transactionWasProcessed(
        bytes32 _blockHash,
        bytes32 _transactionHash,
        address _receiver,
        uint256 _amount,
        uint32 _logIndex
    )
        public view returns(bool)
    {
        bytes32 compiledId = getTransactionCompiledId(_blockHash, _transactionHash, _receiver, _amount, _logIndex);

        return processed[compiledId];
    }

    function processTransaction(
        bytes32 _blockHash,
        bytes32 _transactionHash,
        address _receiver,
        uint256 _amount,
        uint32 _logIndex
    )
        private
    {
        bytes32 compiledId = getTransactionCompiledId(_blockHash, _transactionHash, _receiver, _amount, _logIndex);

        processed[compiledId] = true;
    }

    function setCrossingPayment(uint amount) public onlyOwner whenNotPaused {
        crossingPayment = amount;
        emit CrossingPaymentChanged(crossingPayment);
    }

    function getCrossingPayment() public view returns(uint) {
        return crossingPayment;
    }

    function isUnderDailyLimit(uint amount) private returns (bool)
    {
        uint dailyLimit = allowTokens.dailyLimit();
        // solium-disable-next-line security/no-block-members
        if (now > lastDay + 24 hours) {
            // solium-disable-next-line security/no-block-members
            lastDay = now;
            spentToday = 0;
        }
        if (spentToday + amount > dailyLimit || spentToday + amount < spentToday)
            return false;
        return true;
    }

    function calcMaxWithdraw() public view returns (uint)
    {
        uint dailyLimit = allowTokens.dailyLimit();
        uint maxTokensAllowed = allowTokens.getMaxTokensAllowed();
        uint maxWithrow = dailyLimit - spentToday;
        // solium-disable-next-line security/no-block-members
        if (now > lastDay + 24 hours)
            maxWithrow = dailyLimit;
        if (dailyLimit < spentToday)
            return 0;
        if(maxWithrow > maxTokensAllowed)
            maxWithrow = maxTokensAllowed;
        return maxWithrow;
    }

    function newMethodTest() public whenNotPaused view returns(bool) {
        return true;
    }

    function _changeFederation(address newFederation) private {
        federation = newFederation;
        emit FederationChanged(federation);
    }

    function changeFederation(address newFederation) public onlyOwner whenNotPaused {
        _changeFederation(newFederation);
    }

    function getFederation() public view returns(address) {
        return federation;
    }

}
