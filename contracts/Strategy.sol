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

    ICurveFi public constant pool = ICurveFi(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 public constant steCRV = IERC20(0x06325440D014e39736583c165C2963BA99fAf14E);
    Iyv2 public yvsteCRV = Iyv2(0xdCD90C7f6324cfa40d7169ef80b12031770B4325);
    WETH public weth = WETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint constant public DENOMINATOR = 10000;
    uint public threshold = 6000;
    uint public slip = 50;
    uint public maxAmount = 1e20;
    uint public tank;
    uint public p;
    uint public tip;
    uint public rip;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 31500; // 6300 * 5
        // profitFactor = 100;
        // debtThreshold = 0;
        want.approve(address(pool), uint(-1));
        steCRV.approve(address(pool), uint(-1));
        steCRV.approve(address(yvsteCRV), uint(-1));
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

    function name() external view override returns (string memory) {
        return "StrategysteCurveWETHSingleSided";
    }

    function balanceOfWant() public view returns (uint) {
        return want.balanceOf(address(this));
    }
    
    function balanceOfsteCRV() public view returns (uint) {
        return steCRV.balanceOf(address(this));
    }
    
    function balanceOfsteCRVinWant() public view returns (uint) {
        return balanceOfsteCRV().mul(pool.get_virtual_price()).div(1e18);
    }

    function balanceOfyvsteCRV() public view returns (uint) {
        return yvsteCRV.balanceOf(address(this));
    }

    function balanceOfyvsteCRVinsteCRV() public view returns (uint) {
        return balanceOfyvsteCRV().mul(yvsteCRV.pricePerShare()).div(1e18);
    }

    function balanceOfyvsteCRVinWant() public view returns (uint) {
        return balanceOfyvsteCRVinsteCRV().mul(pool.get_virtual_price()).div(1e18);
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfyvsteCRVinWant());
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
        uint _want = (want.balanceOf(address(this))).sub(tank);
        if (_want > 0) {
            if (_want > maxAmount) _want = maxAmount;
            uint v = _want.mul(1e18).div(pool.get_virtual_price());
            weth.withdraw(_want);
            _want = address(this).balance;
            pool.add_liquidity{value: _want}([_want, 0], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
        }
        uint _amnt = steCRV.balanceOf(address(this));
        if (_amnt > 0) {
            yvsteCRV.deposit(_amnt);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        rebalance();
        deposit();
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        rebalance();
        uint _balance = want.balanceOf(address(this));
        if (_balance < _amountNeeded) {
            _liquidatedAmount = _withdrawSome(_amountNeeded.sub(_balance));
            _liquidatedAmount = _liquidatedAmount.add(_balance);
            if (_liquidatedAmount > _amountNeeded) _liquidatedAmount = _amountNeeded;
            tank = 0;
        }
        else {
            _liquidatedAmount = _amountNeeded;
            if (tank >= _amountNeeded) tank = tank.sub(_amountNeeded);
            else tank = 0;
        }
    }

    function _withdrawSome(uint _amount) internal returns (uint) {
        uint _amnt = _amount.mul(1e18).div(pool.get_virtual_price());
        uint _amt = _amnt.mul(1e18).div(yvsteCRV.pricePerShare());
        uint _bal = yvsteCRV.balanceOf(address(this));
        if (_amt > _bal) _amt = _bal;
        uint _before = steCRV.balanceOf(address(this));
        yvsteCRV.withdraw(_amt);
        uint _after = steCRV.balanceOf(address(this));
        return _withdrawOne(_after.sub(_before));
    }

    function _withdrawOne(uint _amnt) internal returns (uint _bal) {
        uint _before = address(this).balance;
        pool.remove_liquidity_one_coin(_amnt, 0, _amnt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
        uint _after = address(this).balance;
        _bal = _after.sub(_before);
        weth.deposit{value: _bal}();
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        yvsteCRV.transfer(_newStrategy, yvsteCRV.balanceOf(address(this)));
        steCRV.transfer(_newStrategy, steCRV.balanceOf(address(this)));
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = address(steCRV);
        protected[1] = address(yvsteCRV);
        return protected;
    }

    function forceD(uint _amount) external onlyAuthorized {
        drip();
        uint v = _amount.mul(1e18).div(pool.get_virtual_price());
        weth.withdraw(_amount);
        pool.add_liquidity{value: _amount}([_amount, 0], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
        if (_amount < tank) tank = tank.sub(_amount);
        else tank = 0;

        uint _amnt = steCRV.balanceOf(address(this));
        yvsteCRV.deposit(_amnt);
    }

    function forceW(uint _amt) external onlyAuthorized {
        drip();
        uint _before = steCRV.balanceOf(address(this));
        yvsteCRV.withdraw(_amt);
        uint _after = steCRV.balanceOf(address(this));
        _amt = _after.sub(_before);
        
        _before = address(this).balance;
        pool.remove_liquidity_one_coin(_amt, 0, _amt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
        _after = address(this).balance;
        _amt = _after.sub(_before);
        weth.deposit{value: _amt}();
        tank = tank.add(_amt);
    }

    function drip() internal {
        uint _p = yvsteCRV.pricePerShare();
        _p = _p.mul(pool.get_virtual_price()).div(1e18);
        if (_p >= p) {
            tip = tip.add((_p.sub(p)).mul(balanceOfyvsteCRV()).div(1e18));
        }
        else {
            rip = rip.add((p.sub(_p)).mul(balanceOfyvsteCRV()).div(1e18));
        }
        p = _p;
    }

    function tick() public view returns (uint _t, uint _c) {
        _t = pool.balances(0).mul(threshold).div(DENOMINATOR);
        _c = balanceOfyvsteCRVinWant();
    }

    function rebalance() internal {
        drip();
        (uint _t, uint _c) = tick();
        if (_c > _t) {
            _withdrawSome(_c.sub(_t));
            tank = want.balanceOf(address(this));
        }
    }

    receive() external payable {}
}
