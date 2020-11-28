// SPDX-License-Identifier: AGPL-3.0-or-later

/// flip.sol -- Collateral auction

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
    function move(address,address,uint256) external;
    function flux(bytes32,address,address,uint256) external;
}

interface CatLike {
    function claw(uint256) external;
}

/*
   This thing lets you flip some gems for a given amount of dai.
   Once the given amount of dai is raised, gems are forgone instead.

 - `lot` gems in return for bid
 - `tab` total dai wanted
 - `bid` dai paid
 - `gal` receives dai income
 - `usr` receives gem forgone
 - `ttl` single bid lifetime
 - `beg` minimum bid increase
 - `end` max auction duration
*/
//拍卖合约，负责在 CDP 清算时卖掉 Dai 的 抵押品
//抵押品拍卖是用来出售担保品不足的金库里的担保品，以保存dai的稳定。
//Cat.bitten把抵押品送到Flip模块，然后keepers进项拍卖。
//抵押品拍卖有两个阶段:tend和dent

//MKR投票决定了最低抵押率，在Spot.mat字段，当Spot.poke函数接收到预言机抵押物价格后，由于抵押物价格在变化
//则通过poke计算出此价格下可借出的最多借贷金额，然后与cdp的状态，包括借贷金额进行风险评估，在Cat.bite中确定cdp是否安全
//当借贷金额大于可借贷出的最大金额，存在风险时，则调用flip.kick进行拍卖
//当进行flip.kick时，清算罚金也包括在内，但是清算罚金只加到清算部分，不会加到总的债务金额。

//当进行清算拍卖时，MKR持有者投票决定了每批次的大小(目前为50)，这允许对cdp进行部分清算，防止大型拍卖对抵押物价格影响。

//一旦拍卖的最后出价人出价时间到期没有参与拍卖或者本身拍卖已经结束，此时可能会发生拍卖价格低于需要偿还价格，则抵押物从Flipper的在Vat中的余额转移到最高出价人手里

//在Global Settlement阶段，Dai一个重要特性是可以直接调用cage关闭，关闭系统向Dai持有人返还抵押物。此功能也为了Dai迭代升级，并且在代码和设计存在缺陷时提供安全性
contract Flipper is LibNote {
    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Flipper/not-authorized");
        _;
    }
    //拍卖
    // --- Data ---
    struct Bid {
        //支付金额
        uint256 bid;  // dai paid                 [rad]
        //拍卖的抵押物数量
        uint256 lot;  // gems in return for bid   [wad]
        //最高出价人地址
        address guy;  // high bidder
        //出价到期时间
        uint48  tic;  // bid expiry time          [unix epoch time]
        //拍卖到期时间
        uint48  end;  // auction expiry time      [unix epoch time]
        //cdp的地址，在dent阶段接收抵押物
        address usr;
        //拍卖收入所得，所得者为Vow
        address gal;
        //要筹集的总dai数
        uint256 tab;  // total dai wanted         [rad]
    }
    //拍卖物id =》 拍卖
    mapping (uint256 => Bid) public bids;
    //cdp合约
    VatLike public   vat;            // CDP Engine
    //清算合约负责的抵押物id
    bytes32 public   ilk;            // collateral type

    uint256 constant ONE = 1.00E18;
    //最低出价每次增加额度，默认5%
    uint256 public   beg = 1.05E18;  // 5% minimum bid increase
    //投标持续时间，默认为3小时,也就是如果你出价3小时没人出价，则可以成交
    uint48  public   ttl = 3 hours;  // 3 hours bid duration         [seconds]
    //拍卖时间，默认为2天
    uint48  public   tau = 2 days;   // 2 days total auction length  [seconds]
    //拍卖总数，用于跟踪拍卖id，持续增加
    uint256 public kicks = 0;
    CatLike public   cat;            // cat liquidation module

    // --- Events ---
    event Kick(
      uint256 id,
      uint256 lot,
      uint256 bid,
      uint256 tab,
      address indexed usr,
      address indexed gal
    );

    // --- Init ---
    constructor(address vat_, address cat_, bytes32 ilk_) public {
        vat = VatLike(vat_);
        cat = CatLike(cat_);
        ilk = ilk_;
        wards[msg.sender] = 1;
    }

    // --- Math ---
    function add(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Admin ---
    function file(bytes32 what, uint256 data) external note auth {
        if (what == "beg") beg = data;
        else if (what == "ttl") ttl = uint48(data);
        else if (what == "tau") tau = uint48(data);
        else revert("Flipper/file-unrecognized-param");
    }
    function file(bytes32 what, address data) external note auth {
        if (what == "cat") cat = CatLike(data);
        else revert("Flipper/file-unrecognized-param");
    }

    // --- Auction ---
    //由Cat合约发起拍卖，将抵押品拍卖
    //在Cat合约bite函数中，发现资不抵债不安全，调用发生拍卖
    function kick(address usr, address gal, uint256 tab, uint256 lot, uint256 bid)
        public auth returns (uint256 id)
    {
        //每次拍卖都有一个id，且持续增加
        require(kicks < uint256(-1), "Flipper/overflow");
        id = ++kicks;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].guy = msg.sender;  // configurable??
        bids[id].end = add(uint48(now), tau);
        bids[id].usr = usr;
        bids[id].gal = gal;
        bids[id].tab = tab;

        vat.flux(ilk, msg.sender, address(this), lot);

        emit Kick(id, lot, bid, tab, usr, gal);
    }

    //有零个竞标或者拍卖结束重新开始拍卖
    function tick(uint256 id) external note {
        require(bids[id].end < now, "Flipper/not-finished");
        require(bids[id].tic == 0, "Flipper/bid-already-placed");
        bids[id].end = add(uint48(now), tau);
    }

    //拍卖第一阶段，最高价者所得，id为拍卖的id,lot为出价的抵押品数量，bid为出价
    //如为1 Eth出价 A出价 450dai

    //1.出价人A增加了在上个出价人基础上beg(默认5%)的出价，减少A在Vat中dai的余额，增加Vow在Vat中的余额
    //2.出价人B增加了在A出价基础上beg(默认5%)的出价，B的Vat中dai的余额会减少，A的由于有人投标比它高而退换则增加，Vow的余额也增加，tic被重置为tic+ttl
    //3.出价人A增加了在出价基础上beg(默认5%)的出价,Vat.dai[A] = Vat.dai[A] - 出价bid, Vat.dai[Vow] = Vat.dai[Vow] + A的出价-B上次出价
    //4.当一个新的出价出来，满足条件后向新的出价倾斜
    function tend(uint256 id, uint256 lot, uint256 bid) external note {
        require(bids[id].guy != address(0), "Flipper/guy-not-set");
        require(bids[id].tic > now || bids[id].tic == 0, "Flipper/already-finished-tic");
        require(bids[id].end > now, "Flipper/already-finished-end");
        //第一阶段拍卖需要为全部抵押品出价，如1 Eth
        require(lot == bids[id].lot, "Flipper/lot-not-matching");
        //在第一阶段出价小于等于筹集金额，且出价要大于上次出价的最高价格,如现在B 出价460dai
        require(bid <= bids[id].tab, "Flipper/higher-than-tab");
        require(bid >  bids[id].bid, "Flipper/bid-not-higher");
        //出价每次比上次增加beg,默认值为5%,或者出价金额已经到了所要筹集的金额
        require(mul(bid, ONE) >= mul(beg, bids[id].bid) || bid == bids[id].tab, "Flipper/insufficient-increase");
        //如果自己出最高价顶替了上个最高价，则需要给上个最高价者转回它的出价
        //当B出价460dai时，则将先退换A出价的450dai,所以B先给A转450dai,再给受益人vow转10dai
        if (msg.sender != bids[id].guy) {
            vat.move(msg.sender, bids[id].guy, bids[id].bid);
            bids[id].guy = msg.sender;
        }
        //转给vow出价，退回上个最高出价者后的出价
        vat.move(msg.sender, bids[id].gal, bid - bids[id].bid);
        //存储出价状态，修改出价到期时间
        bids[id].bid = bid;
        bids[id].tic = add(uint48(now), ttl);
    }

    //拍卖第二阶段，当拍卖价格足够还清所欠借贷与惩罚金时，进行第二阶段拍卖
    //第二阶段在满足上述条件的前提下，拍卖需要借贷人抵押物越少者所得
    //当B出价460dai刚好能偿还借贷人所欠460dai时，则进入第二阶段，
    //第二阶段如果A出价也是460只需要0.9个抵押物，在相同A出价所需抵押物更少，则选择A

    //这阶段在出价到期和拍卖结束之前
    //当拍卖中的B和其他所有出价人和竞买人认为不值得提高出价，会停止出价竞买，则会tic出价到期，则A调用deal获得抵押物支付Vat.dai的出价金额

    //当出价在tend阶段结束时，在tic和end时间到期还没达到要筹集的金额，那么中标者获取交易的奖励，最终出价与需要筹集金额的差异作为坏账保存在Vow中，在失败的拍卖中Flop中处理。
    function dent(uint256 id, uint256 lot, uint256 bid) external note {
        require(bids[id].guy != address(0), "Flipper/guy-not-set");
        require(bids[id].tic > now || bids[id].tic == 0, "Flipper/already-finished-tic");
        require(bids[id].end > now, "Flipper/already-finished-end");
        //第二阶段出价金额需要在第一阶段满足的前提下，所以第二阶段金额需要等于第一阶段最后的出价
        //如出价人需要满足借贷人所需还款(借贷额+罚金)，第一阶段结束时必须满足才进入第二阶段 
        require(bid == bids[id].bid, "Flipper/not-matching-bid");
        //第二阶段出价需要等于需要筹集的金额
        require(bid == bids[id].tab, "Flipper/tend-not-finished");
        //同等的金额需要少的抵押品者获胜，如A相同出价只需要0.9ETH小于A相同出价的1ETH
        require(lot < bids[id].lot, "Flipper/lot-not-lower");
        //每次出价的抵押品都最少减少beg,默认5%
        require(mul(beg, lot) <= mul(bids[id].lot, ONE), "Flipper/insufficient-decrease");
        //不是在上次最为最高出价者基础上加价，退回上个最高出价者价格
        if (msg.sender != bids[id].guy) {
            vat.move(msg.sender, bids[id].guy, bid);
            bids[id].guy = msg.sender;
        }
    
        vat.flux(ilk, address(this), bids[id].usr, bids[id].lot - lot);

        bids[id].lot = lot;
        bids[id].tic = add(uint48(now), ttl);
    }
    //完成拍卖
    function deal(uint256 id) external note {
        //tic竞标时间内无人出价或者拍卖结束，则完成拍卖
        require(bids[id].tic != 0 && (bids[id].tic < now || bids[id].end < now), "Flipper/not-finished");
        //系统债务减少
        cat.claw(bids[id].tab);
        //将抵押物转给拍卖获胜者
        vat.flux(ilk, address(this), bids[id].guy, bids[id].lot);
        delete bids[id];
    }
    //当在Global Settlement阶段，直接调用yank函数，将抵押物转移到抵押者
    function yank(uint256 id) external note auth {
        require(bids[id].guy != address(0), "Flipper/guy-not-set");
        require(bids[id].bid < bids[id].tab, "Flipper/already-dent-phase");
        cat.claw(bids[id].tab);
        vat.flux(ilk, address(this), msg.sender, bids[id].lot);
        vat.move(msg.sender, bids[id].guy, bids[id].bid);
        delete bids[id];
    }
}
