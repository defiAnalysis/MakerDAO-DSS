// SPDX-License-Identifier: AGPL-3.0-or-later

/// vow.sol -- Dai settlement module

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

interface FlopLike {
    function kick(address gal, uint lot, uint bid) external returns (uint);
    function cage() external;
    function live() external returns (uint);
}

interface FlapLike {
    function kick(uint lot, uint bid) external returns (uint);
    function cage(uint) external;
    function live() external returns (uint);
}

interface VatLike {
    function dai (address) external view returns (uint);
    function sin (address) external view returns (uint);
    function heal(uint256) external;
    function hope(address) external;
    function nope(address) external;
}

//Maker协议的资产负债率，包含系统盈余和系统债务，它的任务是让系统回归平衡
//它的主要功能是通过拍卖MKR来弥补赤字，通过拍卖盈余dai来销毁MKR使得系统平衡。


//当一个Vault处于不安全状态被清算，被查封的债务被放入到队列中等待拍卖(sin[时间戳]=债务),在cat.bite时发生.
//当vow的wait到期时，释放队列中的债务拍卖。

//Sin在加入债务队列时会被存储，进行拍卖的债务是通过债务队列里面的债务与Vat.dai[Vow] Vow的dai的余额比较得出
//如果Vat.sin[Vow]大于Vow.Sin和Ash(正在进行拍卖的债务)的总和，差额有可能符合Flop拍卖的条件。

//在执行cat.bite或者vow.fess的情况下，债务会被添加到sin[now]和Sin中.
//这笔债务发送会放入队列缓冲区Sin中发送给flop，并且所有的借贷dai通过清算flip进行恢复。
//如果不放入缓冲队列中，直接进行拍卖，如果债务比较巨大，将对系统稳定产生影响，

//vat.sin(vow) 总的债务,通过时间戳记录每个部分，这些不是直接拍卖，而是调用flog函数清除掉，
//如果flip在清算时间内没有消除借贷，则债务会被到期加入坏账，坏账超过最小值(lot size)时，可以通过flop债务拍卖来进行弥补
//当一个清算拍卖Flip收到dai,它减少Vat.dai[vow]的余额

//vow.Sin 缓冲区的债务(在队列中的债务)
//vow.Ash 拍卖中的债务

//在vaults被清算(bitten)的情况下，他们的债务由Vow.sin来承担，作为系统债务，将债务Sin数量放入Sin队列。
//如果通过清算拍卖flip未能偿还完债务(在清算拍卖的时间内)，则将此笔债务视为坏账，当坏账超过了最小值，通过债务拍卖来进行偿还(批量操作)。

//系统盈余主要是由于稳定费而产生，在vow中产生了超额的dai,这些dai通过盈余拍卖(flap)来进行释放。
contract Vow is LibNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { require(live == 1, "Vow/not-live"); wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Vow/not-authorized");
        _;
    }

    // --- Data ---
    //vat地址与vat进行交互
    VatLike public vat;        // CDP Engine
    //flap地址盈余拍卖时进行交互
    FlapLike public flapper;   // Surplus Auction House
    //债务拍卖时进行交互
    FlopLike public flopper;   // Debt Auction House

    //系统的债务队列
    mapping (uint256 => uint256) public sin;  // debt queue
    //队列中的债务总额
    uint256 public Sin;   // Queued debt            [rad]
    //正在进行拍卖的债务
    uint256 public Ash;   // On-auction debt        [rad]
    //债务拍卖时长
    uint256 public wait;  // Flop delay             [seconds]
    //债务拍卖抵押物的数量起始数量，如第一次MKR竞价拍卖，拍卖50000Dai，首次竞价为250MKR,则dump为250MKR
    uint256 public dump;  // Flop initial lot size  [wad]
    //每次债务拍卖规模，如系统首次拍卖时拍卖50,000Dai
    uint256 public sump;  // Flop fixed bid size    [rad]
    //盈余拍卖的初始出价
    uint256 public bump;  // Flap fixed lot size    [rad]
    //在进行盈余拍卖时，必须超过盈余缓冲大小，也称为盈余缓冲金。
    //当系统盈余超过 50 万时，会进行盈余拍卖，每批拍卖 50,000  Dai
    uint256 public hump;  // Surplus buffer         [rad]

    uint256 public live;  // Active Flag

    // --- Init ---
    constructor(address vat_, address flapper_, address flopper_) public {
        wards[msg.sender] = 1;
        vat     = VatLike(vat_);
        flapper = FlapLike(flapper_);
        flopper = FlopLike(flopper_);
        vat.hope(flapper_);
        live = 1;
    }

    // --- Math ---
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function min(uint x, uint y) internal pure returns (uint z) {
        return x <= y ? x : y;
    }

    // --- Administration ---
    function file(bytes32 what, uint data) external note auth {
        if (what == "wait") wait = data;
        else if (what == "bump") bump = data;
        else if (what == "sump") sump = data;
        else if (what == "dump") dump = data;
        else if (what == "hump") hump = data;
        else revert("Vow/file-unrecognized-param");
    }

    function file(bytes32 what, address data) external note auth {
        if (what == "flapper") {
            vat.nope(address(flapper));
            flapper = FlapLike(data);
            vat.hope(data);
        }
        else if (what == "flopper") flopper = FlopLike(data);
        else revert("Vow/file-unrecognized-param");
    }

    // Push to debt-queue
    //将坏账加入到债务拍卖队列中
    function fess(uint tab) external note auth {
        sin[now] = add(sin[now], tab);
        Sin = add(Sin, tab);
    }
    // Pop from debt-queue
    //从债务队列取出一个债务
    function flog(uint era) external note {
        require(add(era, wait) <= now, "Vow/wait-not-finished");
        Sin = sub(Sin, sin[era]);
        sin[era] = 0;
    }

    // Debt settlement
    //调用Vat的heal销毁稳定币dai与债务
    function heal(uint rad) external note {
        require(rad <= vat.dai(address(this)), "Vow/insufficient-surplus");
        require(rad <= sub(sub(vat.sin(address(this)), Sin), Ash), "Vow/insufficient-debt");
        vat.heal(rad);
    }
    //抵消盈余和待售债务，销毁dai和债务恢复平衡
    function kiss(uint rad) external note {
        require(rad <= Ash, "Vow/not-enough-ash");
        require(rad <= vat.dai(address(this)), "Vow/insufficient-surplus");
        Ash = sub(Ash, rad);
        vat.heal(rad);
    }

    // Debt auction
    //触发赤字拍卖
    //如果在清算拍卖flip中没有还完赤字，那么债务拍卖将用于固定金额的dai拍卖MKR来摆脱债务赤字.
    //当拍卖结束，vow将会收到Flopper发送过来dai,来免除债务赤字，Flopper将为中标者铸造MKR。
    function flop() external note returns (uint id) {
        require(sump <= sub(sub(vat.sin(address(this)), Sin), Ash), "Vow/insufficient-debt");
        require(vat.dai(address(this)) == 0, "Vow/surplus-not-zero");
        Ash = add(Ash, sump);
        id = flopper.kick(address(this), dump, sump);
    }
    // Surplus auction
    //触发盈余拍卖
    //通过固定数量的内部dai来换取MKR,以摆脱vow的剩余，拍卖结束后，Flapper将会销毁中标的MKR，并将内部的dai发送给中标人。
    function flap() external note returns (uint id) {
        require(vat.dai(address(this)) >= add(add(vat.sin(address(this)), bump), hump), "Vow/insufficient-surplus");
        require(sub(sub(vat.sin(address(this)), Sin), Ash) == 0, "Vow/debt-not-zero");
        id = flapper.kick(bump, 0);
    }

    function cage() external note auth {
        require(live == 1, "Vow/not-live");
        live = 0;
        Sin = 0;
        Ash = 0;
        flapper.cage(vat.dai(address(flapper)));
        flopper.cage();
        vat.heal(min(vat.dai(address(this)), vat.sin(address(this))));
    }
}
