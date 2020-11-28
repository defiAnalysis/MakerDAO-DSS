// SPDX-License-Identifier: AGPL-3.0-or-later

/// flop.sol -- Debt auction

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
    function suck(address,address,uint) external;
}
interface GemLike {
    function mint(address,uint) external;
}
interface VowLike {
    function Ash() external returns (uint);
    function kiss(uint) external;
}

/*
   This thing creates gems on demand in return for dai.

 - `lot` gems in return for bid
 - `bid` dai paid
 - `gal` receives dai income
 - `ttl` single bid lifetime
 - `beg` minimum bid increase
 - `end` max auction duration
*/
//债务拍卖也称为MKR拍卖
//Gov通过MKR持有者决定了债务上限(vow.sump)，当dai的坏账超过了这个上限，触发债务拍卖。
//通过vow.dump决定开始拍卖dai的数量，在出价期间可以减少MKR数量。
//当系统有坏账时，负责发行和出售 MKR 的 拍卖合约。	

//beg、ttl、tau智能被Gov治理合约通过file()赋值，只有Vow调用kick()

//债务拍卖通过拍卖MKR来换取固定金额的dai来调整系统的平衡。

//在特殊的时期(Global Settlement)cage被调用，则拍卖(dent)和完成拍卖(deal)不能调用。

//通过对盈余、稳定费来进行对账，如果有足够的债务，(清理后的债务> vow.sump)，任何用户可以发送vow.flop来触发债务拍卖。

//Flop的拍卖是反向拍卖，系统每次拍卖的dai的数量是固定的，通过出价需要MKR数量少获胜.当调用kick后，将需要出售的Dai设置为Vow.sump,
//首次竞标的MKR数量为vow.dump.拍卖将在超过投标时间ttl结束，或者在超过拍卖时间tau结束，第一个投标人开始偿还系统债务，
//后续投标将偿还之前没中标者的投标人。拍卖结束后，将清理债务并为中标者铸造MKR。


//如果拍卖到期还没有收到报价，则任何人都可以调用tick重启拍卖:
 //   重置1. bids[id].end to now + tau
 //      2. bids[id].lot to bids[id].lot * pad / ONE

 //竞拍期间，每次出价的MKR数量递减，递减最少wei上一个的beg倍，如第一个人竞价100Dai出价10MKR,则下一个竞价者最大出价9.5MKR竞争100Dai

 //首次触发债务拍卖时，全系统抵押不足的债务超过400万美元后触发，这一拍卖会会出售MKR代币换取50000 增量DAI 的形式，并使用筹集的资金来偿还未偿还的坏账。
 //第一次MKR的竞拍价从200Dai 起，总共出售250MKR （代表 50,000Dai）。
 //接下来一个竞拍同样对应50,000Dai，但竞拍者只可获得230MKR，相当于217Dai/MKR 的价格。
 //如果没有人对第一次出价250MKR进行竞拍，则会在三天后重新开始拍卖，50,000Dai对应300MKR，即每枚 MKR 价格为166.66Dai。
 //最终，如果至少有一个出价，并且在6小时内没有人出价更高，则拍卖结​​束。

contract Flopper is LibNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Flopper/not-authorized");
        _;
    }

    // --- Data ---
    struct Bid {
        //支付的金额
        uint256 bid;  // dai paid                [rad]
        //拍卖的数量/出售的MKR
        uint256 lot;  // gems in return for bid  [wad]
        //最高出价人
        address guy;  // high bidder
        //出价有效期
        uint48  tic;  // bid expiry time         [unix epoch time]
        //拍卖结束时间
        uint48  end;  // auction expiry time     [unix epoch time]
    }

    mapping (uint => Bid) public bids;

    VatLike  public   vat;  // CDP Engine
    //MKR地址
    GemLike  public   gem;

    uint256  constant ONE = 1.00E18;
    //最低出价率 %%
    uint256  public   beg = 1.05E18;  // 5% minimum bid increase
    //在出价期间增加的清算数量的大小
    uint256  public   pad = 1.50E18;  // 50% lot increase for tick
    uint48   public   ttl = 3 hours;  // 3 hours bid lifetime         [seconds]
    //最大拍卖时间
    uint48   public   tau = 2 days;   // 2 days total auction length  [seconds]
    //拍卖总数，递增的id
    uint256  public kicks = 0;
    uint256  public live;             // Active Flag
    address  public vow;              // not used until shutdown

    // --- Events ---
    event Kick(
      uint256 id,
      uint256 lot,
      uint256 bid,
      address indexed gal
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
    function min(uint x, uint y) internal pure returns (uint z) {
        if (x > y) { z = y; } else { z = x; }
    }

    // --- Admin ---
    function file(bytes32 what, uint data) external note auth {
        if (what == "beg") beg = data;
        else if (what == "pad") pad = data;
        else if (what == "ttl") ttl = uint48(data);
        else if (what == "tau") tau = uint48(data);
        else revert("Flopper/file-unrecognized-param");
    }

    //首先vow调用kick函数开始一个新的拍卖，guy出价最高人设置为vow合约地址，如首次拍卖参数第一此竞价参数(vow地址，250MKR,50000Dai)
    // --- Auction ---
    //开始一个新的竞价拍卖
    function kick(address gal, uint lot, uint bid) external auth returns (uint id) {
        require(live == 1, "Flopper/not-live");
        require(kicks < uint(-1), "Flopper/overflow");
        id = ++kicks;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].guy = gal;
        bids[id].end = add(uint48(now), tau);

        emit Kick(id, lot, bid, gal);
    }
    //重新开始拍卖
    function tick(uint id) external note {
        require(bids[id].end < now, "Flopper/not-finished");
        require(bids[id].tic == 0, "Flopper/bid-already-placed");
        bids[id].lot = mul(pad, bids[id].lot) / ONE;
        bids[id].end = add(uint48(now), tau);
    }
    //提交一个固定的dai金额，谁要求的MKR数量更少谁获胜，如果没有对第一次出价进行竞价，则三天后重新开始拍卖。
    //首次拍卖是拍卖50000Dai，初始出价250MKR.
    //第一个竞拍者A竞拍出价230MKR，beg为5%,230MKR*(1+5%) > 250MKR
    //则将50000Dai转入vat.dai[vow]中，首次竞拍由vow自动触发,A的vat中的Dai的余额减少50000Dai.
    //第二个竞拍者B继续减少MKR的数量，需要满足beg要求,将vat.dai[A] += 50000Dai,vat.dai[B] += 50000Dai.
    //知道其他竞价者认为不值得接收较低的价格，停止竞拍。一旦报价到期
    function dent(uint id, uint lot, uint bid) external note {
        require(live == 1, "Flopper/not-live");
        require(bids[id].guy != address(0), "Flopper/guy-not-set");
        require(bids[id].tic > now || bids[id].tic == 0, "Flopper/already-finished-tic");
        require(bids[id].end > now, "Flopper/already-finished-end");

        require(bid == bids[id].bid, "Flopper/not-matching-bid");
        require(lot <  bids[id].lot, "Flopper/lot-not-lower");
        require(mul(beg, lot) <= mul(bids[id].lot, ONE), "Flopper/insufficient-decrease");

        if (msg.sender != bids[id].guy) {
            vat.move(msg.sender, bids[id].guy, bid);

            // on first dent, clear as much Ash as possible
            if (bids[id].tic == 0) {
                uint Ash = VowLike(bids[id].guy).Ash();
                VowLike(bids[id].guy).kiss(min(bid, Ash));
            }

            bids[id].guy = msg.sender;
        }

        bids[id].lot = lot;
        bids[id].tic = add(uint48(now), ttl);
    }
    //完成拍卖
    function deal(uint id) external note {
        require(live == 1, "Flopper/not-live");
        require(bids[id].tic != 0 && (bids[id].tic < now || bids[id].end < now), "Flopper/not-finished");
        gem.mint(bids[id].guy, bids[id].lot);
        delete bids[id];
    }

    // --- Shutdown ---
    //系统关闭时调用这两个参数
    function cage() external note auth {
       live = 0;
       vow = msg.sender;
    }
    function yank(uint id) external note {
        require(live == 0, "Flopper/still-live");
        require(bids[id].guy != address(0), "Flopper/guy-not-set");
        vat.suck(vow, bids[id].guy, bids[id].bid);
        delete bids[id];
    }
}
