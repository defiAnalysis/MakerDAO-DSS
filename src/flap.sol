// SPDX-License-Identifier: AGPL-3.0-or-later

/// flap.sol -- Surplus auction

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

interface VatLike {
    function move(address,address,uint) external;
}
interface GemLike {
    function move(address,address,uint) external;
    function burn(address,uint) external;
}

/*
   This thing lets you sell some dai in return for gems.

 - `lot` dai in return for bid
 - `bid` gems paid
 - `ttl` single bid lifetime
 - `beg` minimum bid increase
 - `end` max auction duration
*/
//当系统有盈余时，负责购买和销毁 MKR 拍卖合约。	
//小结:Flapper是一种盈余的拍卖。这些拍卖被用来拍卖系统中为MKR的固定数量的剩余Dai。
//这些盈余将来自于从金库中积累的稳定费。在这种拍卖类型中，竞标者与越来越多的MKR竞争。
//一旦拍卖结束，被拍卖的Dai将被送到中标者手中。系统然后燃烧从中标者那里收到的MKR。

//通过MKR投票决定盈余最大限额，当系统中的Dai超过了设定的限额，触发盈余拍卖。

//一旦拍卖开始，一定数量的Dai将被拍卖。然后，竞标者完成一个固定数量的Dai与增加投标金额的MKR。
//换句话说，这意味着竞标者将不断增加MKR的投标金额，其增量beg将大于已设定的最低投标增加金额。

//当竞投期限结束(ttl)而没有另一个竞投或竞投期限已满(tau)时，剩余竞投即正式结束。
//在拍卖结束时，剩余的MKR会被送往焚烧，从而减少MKR的总供应。

contract Flapper is LibNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Flapper/not-authorized");
        _;
    }

    // --- Data ---
    //竞拍
    struct Bid {
        //报价(MKR数量)
        uint256 bid;  // gems paid               [wad]
        //竞价Dai数量
        uint256 lot;  // dai in return for bid   [rad]
        //最高出价人
        address guy;  // high bidder
        //投标期
        uint48  tic;  // bid expiry time         [unix epoch time]
        //拍卖结束期
        uint48  end;  // auction expiry time     [unix epoch time]
    }
    //映射 id=>投标
    mapping (uint => Bid) public bids;

    VatLike  public   vat;  // CDP Engine
    //MKR合约地址
    GemLike  public   gem;

    uint256  constant ONE = 1.00E18;
    uint256  public   beg = 1.05E18;  // 5% minimum bid increase
    uint48   public   ttl = 3 hours;  // 3 hours bid duration         [seconds]
    //拍卖持续时间
    uint48   public   tau = 2 days;   // 2 days total auction length  [seconds]
    //拍卖的id
    uint256  public kicks = 0;
    uint256  public live;  // Active Flag

    // --- Events ---
    event Kick(
      uint256 id,
      uint256 lot,
      uint256 bid
    );

    // --- Init ---
    constructor(address vat_, address gem_) public {
        wards[msg.sender] = 1;
        vat = VatLike(vat_);
        gem = GemLike(gem_);
        live = 1;
    }

    // --- Math ---
    function add(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Admin ---
    //治理Gov投票设置 beg, ttl, and tau 参数
    function file(bytes32 what, uint data) external note auth {
        if (what == "beg") beg = data;
        else if (what == "ttl") ttl = uint48(data);
        else if (what == "tau") tau = uint48(data);
        else revert("Flapper/file-unrecognized-param");
    }

    // --- Auction ---
    //开启一个新的拍卖
    function kick(uint lot, uint bid) external auth returns (uint id) {
        require(live == 1, "Flapper/not-live");
        require(kicks < uint(-1), "Flapper/overflow");
        id = ++kicks;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].guy = msg.sender;  // configurable??
        bids[id].end = add(uint48(now), tau);

        vat.move(msg.sender, address(this), lot);

        emit Kick(id, lot, bid);
    }
    //开始拍卖后在拍卖期没有人竞标出价重置出价,两天后重新进行竞拍
    function tick(uint id) external note {
        require(bids[id].end < now, "Flapper/not-finished");
        require(bids[id].tic == 0, "Flapper/bid-already-placed");
        bids[id].end = add(uint48(now), tau);
    }
    //进行出价
    //竞标相同数量的Dai价高者胜出，每次出价增量bid*beg,每次价高者直接转移MKR给上个价高者，剩余部分转给本合约地址
    function tend(uint id, uint lot, uint bid) external note {
        require(live == 1, "Flapper/not-live");
        require(bids[id].guy != address(0), "Flapper/guy-not-set");
        require(bids[id].tic > now || bids[id].tic == 0, "Flapper/already-finished-tic");
        require(bids[id].end > now, "Flapper/already-finished-end");

        require(lot == bids[id].lot, "Flapper/lot-not-matching");
        require(bid >  bids[id].bid, "Flapper/bid-not-higher");
        require(mul(bid, ONE) >= mul(beg, bids[id].bid), "Flapper/insufficient-increase");

        if (msg.sender != bids[id].guy) {
            gem.move(msg.sender, bids[id].guy, bids[id].bid);
            bids[id].guy = msg.sender;
        }
        gem.move(msg.sender, address(this), bid - bids[id].bid);

        bids[id].bid = bid;
        bids[id].tic = add(uint48(now), ttl);
    }
    //已经完成拍卖
    //将Dai转移给价高者,焚烧MKR
    function deal(uint id) external note {
        require(live == 1, "Flapper/not-live");
        require(bids[id].tic != 0 && (bids[id].tic < now || bids[id].end < now), "Flapper/not-finished");
        vat.move(address(this), bids[id].guy, bids[id].lot);
        gem.burn(address(this), bids[id].bid);
        delete bids[id];
    }

    function cage(uint rad) external note auth {
       live = 0;
       vat.move(address(this), msg.sender, rad);
    }
    //在Global Settlement 时期，通过回收抵押物来向最高出价者竞价偿还Dai
    function yank(uint id) external note {
        require(live == 0, "Flapper/still-live");
        require(bids[id].guy != address(0), "Flapper/guy-not-set");
        gem.move(address(this), bids[id].guy, bids[id].bid);
        delete bids[id];
    }
}
