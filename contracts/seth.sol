// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface ICurveFi {
    function get_virtual_price() external view returns (uint256);
    function balances(uint256) external view returns (uint256);
    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external payable;
    function remove_liquidity_one_coin(
        uint256 _token_amount,
        int128 i,
        uint256 min_amount
    ) external;
}

interface Iyv2 is IERC20 {
    function pricePerShare() external view returns (uint256);
    function deposit(uint256) external returns (uint256);
    function withdraw(uint256) external returns (uint256);
}

interface WETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    ICurveFi public constant pool = ICurveFi(0xc5424B857f758E906013F3555Dad202e4bdB4567);
    IERC20 public constant eCRV = IERC20(0xA3D87FffcE63B53E0d54fAa1cc983B7eB0b74A9c);
    Iyv2 public yveCRV = Iyv2(0x986b4AFF588a109c09B50A03f42E4110E29D353F);
    WETH public weth = WETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint constant public DENOMINATOR = 10000;
    uint public threshold = 6000;
    uint public slip = 50;
    uint public maxAmount = 5e20;
    uint public interval = 6 hours;
    uint public tank;
    uint public p;
    uint public tip;
    uint public rip;
    uint public checkpoint;

    constructor(address _vault) public BaseStrategy(_vault) {
        minReportDelay = 1 days;
        maxReportDelay = 3 days;
        profitFactor = 1000;
        debtThreshold = 1e20;

        want.approve(address(pool), uint(-1));
        eCRV.approve(address(pool), uint(-1));
        eCRV.approve(address(yveCRV), uint(-1));
    }

    function setThreshold(uint _threshold) external onlyAuthorized {
        threshold = _threshold;
    }

    function setSlip(uint _slip) external onlyAuthorized {
        slip = _slip;
    }

    function setMaxAmount(uint _maxAmount) external onlyAuthorized {
        maxAmount = _maxAmount;
    }

    function setInterval(uint _interval) external onlyAuthorized {
        interval = _interval;
    }

    function name() external view override returns (string memory) {
        return "StrategyeCurveWETHSingleSided";
    }

    function balanceOfWant() public view returns (uint) {
        return want.balanceOf(address(this));
    }
    
    function balanceOfeCRV() public view returns (uint) {
        return eCRV.balanceOf(address(this));
    }
    
    function balanceOfeCRVinWant() public view returns (uint) {
        return balanceOfeCRV().mul(pool.get_virtual_price()).div(1e18);
    }

    function balanceOfyveCRV() public view returns (uint) {
        return yveCRV.balanceOf(address(this));
    }

    function balanceOfyveCRVineCRV() public view returns (uint) {
        return balanceOfyveCRV().mul(yveCRV.pricePerShare()).div(1e18);
    }

    function balanceOfyveCRVinWant() public view returns (uint) {
        return balanceOfyveCRVineCRV().mul(pool.get_virtual_price()).div(1e18);
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfyveCRVinWant());
    }

    function delegatedAssets() external view override returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    function ethToWant(uint256 _amount) public view override returns (uint256) {
        return _amount;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        rebalance();
        // net gain net loss
        if (tip > rip) {
            tip = tip.sub(rip);
            rip = 0;
        }
        else {
            rip = rip.sub(tip);
            tip = 0;
        }

        tank = balanceOfWant();
        uint _free = tip + _debtOutstanding;
        if (_free > 0) {
            if (tank >= _free) {
                _profit = tip;
                _debtPayment = _debtOutstanding;
                tank = tank.sub(_free);
            }
            else {
                uint _withdrawn = _withdrawSome(_free.sub(tank));
                _withdrawn = _withdrawn.add(tank);
                tank = 0;
                if (_withdrawn >= tip) {
                    _profit = tip;
                    _debtPayment = _withdrawn.sub(tip);
                }
                else {
                    _profit = _withdrawn;
                    _debtPayment = 0;
                }
            }
            tip = 0;
        }

        if (rip > 0) {
            _loss = _loss.add(rip);
            rip = 0;
        }
    }

    function deposit() internal {
        uint _want = balanceOfWant();
        if (_want > 0) {
            if (_want > maxAmount) _want = maxAmount;
            uint v = _want.mul(1e18).div(pool.get_virtual_price());
            weth.withdraw(_want);
            _want = address(this).balance;
            pool.add_liquidity{value: _want}([_want, 0], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
            if (_want < tank) tank = tank.sub(_want);
            else tank = 0;
        }
        uint _amnt = eCRV.balanceOf(address(this));
        if (_amnt > 0) {
            yveCRV.deposit(_amnt);
            checkpoint = block.timestamp;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) return;
        rebalance();
        deposit();
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        rebalance();
        uint _balance = balanceOfWant();
        if (_balance < _amountNeeded) {
            _liquidatedAmount = _withdrawSome(_amountNeeded.sub(_balance));
            _liquidatedAmount = _liquidatedAmount.add(_balance);
            if (_liquidatedAmount > _amountNeeded) _liquidatedAmount = _amountNeeded;
            else _loss = _amountNeeded.sub(_liquidatedAmount);
            tank = 0;
        }
        else {
            _liquidatedAmount = _amountNeeded;
            if (tank >= _amountNeeded) tank = tank.sub(_amountNeeded);
            else tank = 0;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed,) = liquidatePosition(vault.strategies(address(this)).totalDebt);
    }

    function _withdrawSome(uint _amount) internal returns (uint) {
        uint _amnt = _amount.mul(1e18).div(pool.get_virtual_price());
        uint _amt = _amnt.mul(1e18).div(yveCRV.pricePerShare());
        uint _bal = yveCRV.balanceOf(address(this));
        if (_amt > _bal) _amt = _bal;
        uint _before = eCRV.balanceOf(address(this));
        yveCRV.withdraw(_amt);
        uint _after = eCRV.balanceOf(address(this));
        return _withdrawOne(_after.sub(_before));
    }

    function _withdrawOne(uint _amnt) internal returns (uint _bal) {
        uint _before = address(this).balance;
        pool.remove_liquidity_one_coin(_amnt, 0, _amnt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
        uint _after = address(this).balance;
        _bal = _after.sub(_before);
        weth.deposit{value: _bal}();
    }

    function tendTrigger(uint256 callCost) public override view returns (bool) {
        uint _want = balanceOfWant();
        (uint256 _t, uint256 _c) = tick();
        return (_c > _t) || (checkpoint.add(interval) < block.timestamp && _want > 0);
    }

    function prepareMigration(address _newStrategy) internal override {
        yveCRV.transfer(_newStrategy, yveCRV.balanceOf(address(this)));
        eCRV.transfer(_newStrategy, eCRV.balanceOf(address(this)));
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = address(eCRV);
        protected[1] = address(yveCRV);
        return protected;
    }

    function forceD(uint _amount) external onlyEmergencyAuthorized {
        drip();
        weth.withdraw(_amount);
        pool.add_liquidity{value: _amount}([_amount, 0], 0);
        if (_amount < tank) tank = tank.sub(_amount);
        else tank = 0;

        uint _amnt = eCRV.balanceOf(address(this));
        yveCRV.deposit(_amnt);
    }

    function forceW(uint _amt) external onlyEmergencyAuthorized {
        drip();
        uint _before = eCRV.balanceOf(address(this));
        yveCRV.withdraw(_amt);
        uint _after = eCRV.balanceOf(address(this));
        _amt = _after.sub(_before);
        
        _before = address(this).balance;
        pool.remove_liquidity_one_coin(_amt, 0, 0);
        _after = address(this).balance;
        _amt = _after.sub(_before);
        weth.deposit{value: _amt}();
        tank = tank.add(_amt);
    }

    function drip() internal {
        uint _p = yveCRV.pricePerShare();
        _p = _p.mul(pool.get_virtual_price()).div(1e18);
        if (_p >= p) {
            tip = tip.add((_p.sub(p)).mul(balanceOfyveCRV()).div(1e18));
        }
        else {
            rip = rip.add((p.sub(_p)).mul(balanceOfyveCRV()).div(1e18));
        }
        p = _p;
    }

    function tick() public view returns (uint _t, uint _c) {
        _t = pool.balances(0).mul(threshold).div(DENOMINATOR);
        _c = balanceOfyveCRVinWant();
    }

    function rebalance() internal {
        drip();
        (uint _t, uint _c) = tick();
        if (_c > _t) {
            _withdrawSome(_c.sub(_t));
            tank = balanceOfWant();
        }
    }

    receive() external payable {}
}
