// SPDX-License-Identifier: MIT
pragma solidity 0.7.1;

import {
    ISuperfluid,
    ISuperToken,
    ISuperAgreement,
    ISuperApp,
    SuperAppDefinitions
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {
    IConstantFlowAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import "@openzeppelin/contracts/access/Ownable.sol";


contract LotterySuperApp is Ownable, ISuperApp { 

    /// @dev Entrance fee for the game (hardcoded to $1)
    uint256 constant private _ENTRANCE_FEE = 1e18;
    /// @dev Minimum flow rate to participate (hardcoded to $10 / mo)
    int96 constant private _MINIMUM_FLOW_RATE = int96(uint256(10e18) / uint256(3600 * 24 * 30));

    string constant private _ERR_STR_NO_TICKET = "LotterySuperApp: need ticket to play";
    string constant private _ERR_STR_LOW_FLOW_RATE = "LotterySuperApp: flow rate too low";

    ISuperfluid private _host; // host
    IConstantFlowAgreementV1 private _cfa; // the stored constant flow agreement class address
    ISuperToken private _acceptedToken; // accepted token

    address[] private _players;
    mapping (address => uint) private _playerIndices;
    address private _winner;

    constructor(
        ISuperfluid host,
        IConstantFlowAgreementV1 cfa,
        ISuperToken acceptedToken) {
        assert(address(host) != address(0));
        assert(address(cfa) != address(0));
        assert(address(acceptedToken) != address(0));

        _host = host;
        _cfa = cfa;
        _acceptedToken = acceptedToken;

        uint256 configWord =
            SuperAppDefinitions.TYPE_APP_FINAL;

        _host.registerApp(configWord);
    }

    /// @dev Tickets by users
    mapping (address => uint) public tickets;

    /**************************************************************************
     * Game Logic
     *************************************************************************/

    /// @dev Take entrance fee from the user and issue a ticket
    function participate(bytes calldata ctx) external {
        // msg sender is encoded in the Context
        (,,address sender,,) = _host.decodeCtx(ctx);
        _acceptedToken.transferFrom(sender, address(this), _ENTRANCE_FEE);
        tickets[sender]++;
    }

    function currentWinner()
        external view
        returns (
            uint256 drawingTime,
            address player,
            int96 flowRate
        )
    {
        if (_winner != address(0)) {
            (drawingTime, flowRate,,) = _cfa.getFlow(_acceptedToken, address(this), _winner);
            player = _winner;
        }
    }

    event WinnerChanged(address winner);

    /// @dev Check requirements before letting the user playing the game
    function _beforePlay(
        bytes calldata ctx
    )
        private view
        returns (bytes memory cbdata)
    {
        (,,address sender,,) = _host.decodeCtx(ctx);
        require(tickets[sender] > 0, _ERR_STR_NO_TICKET);
        cbdata = abi.encode(sender);
    }

    /// @dev Play the game
    function _play(
        bytes calldata ctx,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata cbdata
    )
        private
        returns (bytes memory newCtx)
    {
        (address player) = abi.decode(cbdata, (address));

        (,int96 flowRate,,) = IConstantFlowAgreementV1(agreementClass).getFlowByID(_acceptedToken, agreementId);
        require(flowRate >= _MINIMUM_FLOW_RATE, _ERR_STR_LOW_FLOW_RATE);

        // charge one ticket
        tickets[player]--; 

        // arrange players list
        if (_playerIndices[player] == 0) {
            _players.push(player);
            _playerIndices[player] = _players.length;
        }

        return _draw(ctx);
    }

    /// @dev Play the game
    function _quit(
        bytes calldata ctx
    )
        private
        returns (bytes memory newCtx)
    {
        (,,address player,,) = _host.decodeCtx(ctx);

        // arrange players list
        uint playerIndex = _playerIndices[player] - 1;
        address lastPlayer = _players[_players.length - 1];
        _players[playerIndex] = lastPlayer;
        delete _players[_players.length - 1];
        _playerIndices[player] = 0;

        return _draw(ctx);
    }

    // @dev Make a new draw
    function _draw(
        bytes calldata ctx
    )
        private
        returns (bytes memory newCtx)
    {
        address oldWinner = _winner;

        // rand() adaptation from: https://ethereum.stackexchange.com/questions/72940/solidity-how-do-i-generate-a-random-address
        _winner = _players[
            uint(keccak256(abi.encodePacked(_players.length, blockhash(block.number))))
            %
            _players.length
        ];

        newCtx = ctx;

        // delete flow to old winner 
        if (oldWinner != address(0)) {
            (newCtx, ) = _host.callAgreementWithContext(
                _cfa,
                abi.encodeWithSelector(
                    _cfa.deleteFlow.selector,
                    _acceptedToken,
                    address(this),
                    oldWinner,
                    new bytes(0)
                ),
                newCtx
            );
        }

        // create flow to new winner
        (newCtx, ) = _host.callAgreementWithContext(
            _cfa,
            abi.encodeWithSelector(
                _cfa.createFlow.selector,
                _acceptedToken,
                _winner,
                _cfa.getNetFlow(_acceptedToken, address(this)),
                new bytes(0)
            ),
            newCtx
        );

        emit WinnerChanged(_winner);
    }

    /**************************************************************************
     * SuperApp callbacks
     *************************************************************************/

    function beforeAgreementCreated(
        ISuperToken superToken,
        bytes calldata ctx,
        address agreementClass,
        bytes32 /*agreementId*/
    )
        external view override
        onlyHost
        onlyExpected(superToken, agreementClass)
        returns (bytes memory cbdata)
    {
        cbdata = _beforePlay(ctx);
    }

    function afterAgreementCreated(
        ISuperToken /* superToken */,
        bytes calldata ctx,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata cbdata
    )
        external override
        onlyHost
        returns (bytes memory newCtx)
    {
        return _play(ctx, agreementClass, agreementId, cbdata);
    }

    function beforeAgreementUpdated(
        ISuperToken superToken,
        bytes calldata ctx,
        address agreementClass,
        bytes32 /*agreementId*/
    )
        external view override
        onlyHost
        onlyExpected(superToken, agreementClass)
        returns (bytes memory cbdata)
    {
        cbdata = _beforePlay(ctx);
    }

    function afterAgreementUpdated(
        ISuperToken /* superToken */,
        bytes calldata ctx,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata cbdata
    )
        external override
        onlyHost
        returns (bytes memory newCtx)
    {
        return _play(ctx, agreementClass, agreementId, cbdata);
    }

    function beforeAgreementTerminated(
        ISuperToken superToken,
        bytes calldata /*ctx*/,
        address agreementClass,
        bytes32 /*agreementId*/
    )
        external view override
        onlyHost
        returns (bytes memory cbdata)
    {
        // According to the app basic law, we should never revert in a termination callback
        if (!_isSameToken(superToken) || !_isCFAv1(agreementClass)) return abi.encode(false);
        return abi.encode(true);
    }

    ///
    function afterAgreementTerminated(
        ISuperToken /* superToken */,
        bytes calldata ctx,
        address /* agreementClass */,
        bytes32 /* agreementId */,
        bytes calldata cbdata
    )
        external override
        onlyHost
        returns (bytes memory newCtx)
    {
        // According to the app basic law, we should never revert in a termination callback
        (bool shouldIgnore) = abi.decode(cbdata, (bool));
        if (shouldIgnore) return ctx;
        return _quit(ctx);
    }

    function _isSameToken(ISuperToken superToken) private view returns (bool) {
        return address(superToken) == address(_acceptedToken);
    }

    function _isCFAv1(address agreementClass) private pure returns (bool) {
        return ISuperAgreement(agreementClass).agreementType()
            == keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
    }

    modifier onlyHost() {
        require(msg.sender == address(_host), "LotterySuperApp: support only one host");
        _;
    }

    modifier onlyExpected(ISuperToken superToken, address agreementClass) {
        require(_isSameToken(superToken), "LotterySuperApp: not accepted token");
        require(_isCFAv1(agreementClass), "LotterySuperApp: only CFAv1 supported");
        _;
    }

}
