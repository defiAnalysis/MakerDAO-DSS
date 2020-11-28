// SPDX-License-Identifier: AGPL-3.0-or-later

/// cat.sol -- Dai liquidation module

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

import "./lib.sol";

//定义了拍卖合约中 kick() 函数的接口，
//而这个接口的具体逻辑则在外部的合约中定义，目前拍卖相关的逻辑，在 主合约仓库的 flip 合约 中
interface Kicker {
    function kick(address urn, address gal, uint256 tab, uint256 lot, uint256 bid)
        external returns (uint256);
}
//核心合约模块Vat的接口
interface VatLike {
    function ilks(bytes32) external view returns (
        uint256 Art,  // [wad]
        uint256 rate, // [ray]
        uint256 spot, // [ray]
        uint256 line, // [rad]
        uint256 dust  // [rad]
    );
    function urns(bytes32,address) external view returns (
        uint256 ink,  // [wad]
        uint256 art   // [wad]
    );
    function grab(bytes32,address,address,address,int256,int256) external;
    function hope(address) external;
    function nope(address) external;
}
//
interface VowLike {
    function fess(uint256) external;
}

//系统的清算代理，它使keepers用户能够将安全线以下的债仓发送给拍卖。
contract Cat is LibNote {
    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Cat/not-authorized");
        _;
    }

    // --- Data ---
    struct Ilk {
        //具体负责执行抵押品清算拍卖逻辑的合约地址
        address flip;  // Liquidator
        //抵押物的罚金,目前ETH是13%
        uint256 chop;  // Liquidation Penalty  [wad]
        //等待被清算的资产数量
        uint256 dunk;  // Liquidation Quantity [rad]
    }

    mapping (bytes32 => Ilk) public ilks;
    //通过live为1来确认是否结束，部署后只能通过cage函数设置为0，不能再设置为1
    uint256 public live;   // Active Flag
    //核心合约vat的合约地址
    VatLike public vat;    // CDP Engine
    //
    VowLike public vow;    // Debt Engine
    //系统包括罚金最大可拍卖的金额(MKR投票设置)
    uint256 public box;    // Max Dai out for liquidation        [rad]
    //系统清算需要总的还款金额
    uint256 public litter; // Balance of Dai out for liquidation [rad]

    // --- Events ---
    event Bite(
      bytes32 indexed ilk,
      address indexed urn,
      uint256 ink,
      uint256 art,
      uint256 tab,
      address flip,
      uint256 id
    );

    // --- Init ---
    constructor(address vat_) public {
        wards[msg.sender] = 1;
        vat = VatLike(vat_);
        live = 1;
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    //安全计算函数，判断上下溢出
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (x > y) { z = y; } else { z = x; }
    }
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    //只有外部管理员权限可调
    // --- Administration ---
    function file(bytes32 what, address data) external note auth {
        if (what == "vow") vow = VowLike(data);
        else revert("Cat/file-unrecognized-param");
    }
    function file(bytes32 what, uint256 data) external note auth {
        if (what == "box") box = data;
        else revert("Cat/file-unrecognized-param");
    }
    function file(bytes32 ilk, bytes32 what, uint256 data) external note auth {
        if (what == "chop") ilks[ilk].chop = data;
        else if (what == "dunk") ilks[ilk].dunk = data;
        else revert("Cat/file-unrecognized-param");
    }
    function file(bytes32 ilk, bytes32 what, address flip) external note auth {
        if (what == "flip") {
            vat.nope(ilks[ilk].flip);
            ilks[ilk].flip = flip;
            vat.hope(flip);
        }
        else revert("Cat/file-unrecognized-param");
    }

    // --- CDP Liquidation ---
    //可以在任何时候调用bite，但只有在抵押债仓不安全的情况下才会成功。
    //当被锁定的抵押品乘以抵押品的抵押率低于其债务(抵押品乘以抵押品费率)时，cdp就不安全了。
    function bite(bytes32 ilk, address urn) external returns (uint256 id) {
        //分别获得抵押率、预言机的实时价格,和最小可借贷额
        (,uint256 rate,uint256 spot,,uint256 dust) = vat.ilks(ilk);
        //返回抵押品数量和贷款总额
        (uint256 ink, uint256 art) = vat.urns(ilk, urn);
        //确保还没有结束，部署后只能设置为0
        require(live == 1, "Cat/not-live");
        //通过抵押品乘以抵押率如果小于抵押数量乘以预言机的实时价格时，才会调用成功
        //触发清算要求，个人抵押品数量 * 具有安全边际的抵押品价格 < 个人债务 * 抵押率
        //如在ETH价格为300usd/eth时用1ETH借贷 200dai,当Eth价格变化为200usd/eth时,则 1Eth * 200usd/Eth < 200dai * 150%时,触发清算 
        //抵押品价格下降到一定程度后，触发清算
        require(spot > 0 && mul(ink, spot) < mul(art, rate), "Cat/not-unsafe");
        //把link加入到内存从而优化效率
        Ilk memory milk = ilks[ilk];
        uint256 dart;
        //申请一个新的作用域，防止栈太深溢出发生错误
        {
            //此刻抵押物存在的价格缓冲区间
            uint256 room = sub(box, litter);

            // test whether the remaining space in the litterbox is dusty
            require(litter < box && room >= dust, "Cat/liquidation-limit-hit");

            dart = min(art, mul(min(milk.dunk, room), WAD) / rate / milk.chop);
        }

        uint256 dink = min(ink, mul(ink, dart) / art);

        require(dart >  0      && dink >  0     , "Cat/null-auction");
        require(dart <= 2**255 && dink <= 2**255, "Cat/overflow"    );

        // This may leave the CDP in a dusty state
        //清算，将个人抵押品减掉，个人债务也减掉,将减掉的抵押品转移到本地址下(gem)
        //管控用户的待清算资产
        vat.grab(
            ilk, urn, address(this), address(vow), -int256(dink), -int256(dart)
        );
        vow.fess(mul(dart, rate));

        { // Avoid stack too deep
            // This calcuation will overflow if dart*rate exceeds ~10^14,
            // i.e. the maximum dunk is roughly 100 trillion DAI.
            //
            uint256 tab = mul(mul(dart, rate), milk.chop) / WAD;
            litter = add(litter, tab);
            //触发拍卖
            //交由相应的清算合约发起拍卖请求
            id = Kicker(milk.flip).kick({
                urn: urn,
                gal: address(vow),
                tab: tab,
                lot: dink,
                bid: 0
            });
        }

        emit Bite(ilk, urn, dink, dart, mul(dart, rate), milk.flip, id);
    }

    function claw(uint256 rad) external note auth {
        litter = sub(litter, rad);
    }

    function cage() external note auth {
        live = 0;
    }
}
