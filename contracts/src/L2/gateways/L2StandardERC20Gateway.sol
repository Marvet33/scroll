// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IL2ERC20Gateway, L2ERC20Gateway } from "./L2ERC20Gateway.sol";
import { IL2ScrollMessenger } from "../IL2ScrollMessenger.sol";
import { IL1ERC20Gateway } from "../../L1/gateways/IL1ERC20Gateway.sol";
import { IScrollStandardERC20 } from "../../libraries/token/IScrollStandardERC20.sol";
import { ScrollStandardERC20 } from "../../libraries/token/ScrollStandardERC20.sol";
import { IScrollStandardERC20Factory } from "../../libraries/token/IScrollStandardERC20Factory.sol";
import { ScrollGatewayBase, IScrollGateway } from "../../libraries/gateway/ScrollGatewayBase.sol";

/// @title L2StandardERC20Gateway
/// @notice The `L2StandardERC20Gateway` is used to withdraw standard ERC20 tokens in layer 2 and
/// finalize deposit the tokens from layer 1.
/// @dev The withdrawn ERC20 tokens will be burned directly. On finalizing deposit, the corresponding
/// token will be minted and transfered to the recipient. Any ERC20 that requires non-standard functionality
/// should use a separate gateway.
contract L2StandardERC20Gateway is Initializable, ScrollGatewayBase, L2ERC20Gateway {
  using SafeERC20 for IERC20;
  using Address for address;

  /**************************************** Variables ****************************************/

  /// @notice Mapping from l2 token address to l1 token address.
  mapping(address => address) private tokenMapping;

  /// @notice The address of ScrollStandardERC20Factory.
  address public tokenFactory;

  /**************************************** Constructor ****************************************/

  function initialize(
    address _counterpart,
    address _router,
    address _messenger,
    address _tokenFactory
  ) external initializer {
    require(_router != address(0), "zero router address");
    ScrollGatewayBase._initialize(_counterpart, _router, _messenger);

    require(_tokenFactory != address(0), "zero token factory");
    tokenFactory = _tokenFactory;
  }

  /**************************************** View Functions ****************************************/

  /// @inheritdoc IL2ERC20Gateway
  function getL1ERC20Address(address _l2Token) external view override returns (address) {
    return tokenMapping[_l2Token];
  }

  /// @inheritdoc IL2ERC20Gateway
  function getL2ERC20Address(address _l1Token) public view override returns (address) {
    return IScrollStandardERC20Factory(tokenFactory).computeL2TokenAddress(address(this), _l1Token);
  }

  /**************************************** Mutate Functions ****************************************/

  /// @inheritdoc IL2ERC20Gateway
  function finalizeDepositERC20(
    address _l1Token,
    address _l2Token,
    address _from,
    address _to,
    uint256 _amount,
    bytes calldata _data
  ) external payable override onlyCallByCounterpart {
    require(msg.value == 0, "nonzero msg.value");

    {
      // avoid stack too deep
      address _expectedL2Token = IScrollStandardERC20Factory(tokenFactory).computeL2TokenAddress(
        address(this),
        _l1Token
      );
      require(_l2Token == _expectedL2Token, "l2 token mismatch");
    }

    bytes memory _deployData;
    bytes memory _callData;

    if (tokenMapping[_l2Token] == address(0)) {
      // first deposit, update mapping
      tokenMapping[_l2Token] = _l1Token;
      (_callData, _deployData) = abi.decode(_data, (bytes, bytes));
    } else {
      _callData = _data;
    }

    if (!_l2Token.isContract()) {
      _deployL2Token(_deployData, _l1Token);
    }

    // @todo forward `_callData` to `_to` using transferAndCall in the near future

    IScrollStandardERC20(_l2Token).mint(_to, _amount);

    emit FinalizeDepositERC20(_l1Token, _l2Token, _from, _to, _amount, _callData);
  }

  /// @inheritdoc IScrollGateway
  function finalizeDropMessage() external payable virtual onlyMessenger {
    // @todo should refund token back to sender.
  }

  /**************************************** Internal Functions ****************************************/

  /// @inheritdoc L2ERC20Gateway
  function _withdraw(
    address _token,
    address _to,
    uint256 _amount,
    bytes memory _data,
    uint256 _gasLimit
  ) internal virtual override {
    require(_amount > 0, "withdraw zero amount");

    // 1. Extract real sender if this call is from L2GatewayRouter.
    address _from = msg.sender;
    if (router == msg.sender) {
      (_from, _data) = abi.decode(_data, (address, bytes));
    }

    address _l1Token = tokenMapping[_token];
    require(_l1Token != address(0), "no corresponding l1 token");

    // 2. Burn token.
    IScrollStandardERC20(_token).burn(_from, _amount);

    // 3. Generate message passed to L1StandardERC20Gateway.
    bytes memory _message = abi.encodeWithSelector(
      IL1ERC20Gateway.finalizeWithdrawERC20.selector,
      _l1Token,
      _token,
      _from,
      _to,
      _amount,
      _data
    );

    // 4. send message to L2ScrollMessenger
    IL2ScrollMessenger(messenger).sendMessage{ value: msg.value }(counterpart, msg.value, _message, _gasLimit);

    emit WithdrawERC20(_l1Token, _token, _from, _to, _amount, _data);
  }

  function _deployL2Token(bytes memory _deployData, address _l1Token) internal {
    address _l2Token = IScrollStandardERC20Factory(tokenFactory).deployL2Token(address(this), _l1Token);
    (string memory _symbol, string memory _name, uint8 _decimals) = abi.decode(_deployData, (string, string, uint8));
    ScrollStandardERC20(_l2Token).initialize(_name, _symbol, _decimals, address(this), _l1Token);
  }
}