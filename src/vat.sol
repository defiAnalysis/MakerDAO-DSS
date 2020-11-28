// SPDX-License-Identifier: AGPL-3.0-or-later

/// vat.sol -- Dai CDP database

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

//抵押债仓
//CDP 的核心，存储并跟踪所有关联的Dai和抵押余额。 
//它还定义了可用来操作CDP的规则与平衡策略。 
//Vat定义的规则是不可变的。
//Vat中的公共结构其他合约通过Vat地址全局调用，通过file传递参数来进行设置
contract Vat {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { require(live == 1, "Vat/not-live"); wards[usr] = 1; }
    function deny(address usr) external note auth { require(live == 1, "Vat/not-live"); wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Vat/not-authorized");
        _;
    }

    mapping(address => mapping (address => uint)) public can;
    //修改权限
    function hope(address usr) external note { can[msg.sender][usr] = 1; }
    function nope(address usr) external note { can[msg.sender][usr] = 0; }
    //检查一个地址是否允许修改另一个地址的gem或dai余额
    function wish(address bit, address usr) internal view returns (bool) {
        return either(bit == usr, can[bit][usr] == 1);
    }
    //wad、ray、rad三种数值单位
    //wad：具有18位小数的定点小数
    //ray: 具有27位小数的定点小数
    //rad: 具有45位小数的定点小数
   // ray  = 10 ** 27

    // --- Data ---
    //抵押物结构，已抵押物id为个体
    //rate和spot的作用主要是满足ink * spot >= art * rate可借贷，不然需要清算了。
    struct Ilk {
        // 此抵押物总的借贷总额Dai                                         [wad]
        uint256 Art; 
        // 累计稳定费用，贷款年化率复利累计                    [ray]  
        uint256 rate;  
        // 价格安全线，抵押品在当前价格下每单位担保品允许的最大稳定价格。价格低于当前值抵押品面临清算               [ray]
        //由合约spot在poke()调用vat.file()，给出每个单位资产允许借Dai的最大个数，比如 
        // spot=100Dai/ETH, 若之前抵押的1 ETH，借了120Dai，则要执行清算
        uint256 spot;  
        // 系统中此类抵押品最大可借贷                  [rad]
        uint256 line;  
        // 系统中此类抵押品最小可借贷                [rad]
        uint256 dust;  
    }
    //抵押金库
    struct Urn {
        //总的抵押物数量,如锁定10ETH
        uint256 ink;   // Locked Collateral  [wad]
        //用户总的借贷,从系统借出Dai
        uint256 art;   // Normalised Debt    [wad]
    }
    //抵押物id对应的抵押物
    mapping (bytes32 => Ilk)                       public ilks;
   ////抵押物id => 个人地址 => 个人债务
    mapping (bytes32 => mapping (address => Urn )) public urns;
    //token先生成gem,再通过Ilk对象借出dai
    //如将eth锁入债仓,再借出dai
    //抵押物id => 个人地址 => 个人抵押物总值
    mapping (bytes32 => mapping (address => uint)) public gem;  // [wad]
    //个人地址 => 含有的dai，统计作用
    mapping (address => uint256)                   public dai;  // [rad]
    //清算地址 => 清算总值， 统计作用
    mapping (address => uint256)                   public sin;  // [rad]
        
    // 比如，某个用户抵押一定数量ETH，会生成相应数量的dai，debt记录发行dai总和的数量
    uint256 public debt;  // Total Dai Issued    [rad]
    //资不抵债会启用缓冲金来进行还债，减少vice
    uint256 public vice;  // Total Unbacked Dai  [rad]
    // 系统可以贷出的最多总dai数量，系统中所有抵押物可以贷出的dai的上限总量
    uint256 public Line;  // Total Debt Ceiling  [rad]
    uint256 public live;  // Active Flag

    // --- Logs ---
    event LogNote(
        bytes4   indexed  sig,
        bytes32  indexed  arg1,
        bytes32  indexed  arg2,
        bytes32  indexed  arg3,
        bytes             data
    ) anonymous;

    modifier note {
        _;
        assembly {
            // log an 'anonymous' event with a constant 6 words of calldata
            // and four indexed topics: the selector and the first three args
            let mark := msize()                       // end of memory ensures zero
            mstore(0x40, add(mark, 288))              // update free memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 calldataload(4),                     // arg1
                 calldataload(36),                    // arg2
                 calldataload(68)                     // arg3
                )
        }
    }

    // --- Init ---
    constructor() public {
        wards[msg.sender] = 1;
        live = 1;
    }
    //安全数学函数防止缓冲区溢出
    // --- Math ---
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function sub(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function mul(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function init(bytes32 ilk) external note auth {
        require(ilks[ilk].rate == 0, "Vat/ilk-already-init");
        ilks[ilk].rate = 10 ** 27;
    }
    function file(bytes32 what, uint data) external note auth {
        require(live == 1, "Vat/not-live");
        if (what == "Line") Line = data;
        else revert("Vat/file-unrecognized-param");
    }
    function file(bytes32 ilk, bytes32 what, uint data) external note auth {
        require(live == 1, "Vat/not-live");
        if (what == "spot") ilks[ilk].spot = data;
        else if (what == "line") ilks[ilk].line = data;
        else if (what == "dust") ilks[ilk].dust = data;
        else revert("Vat/file-unrecognized-param");
    }
    function cage() external note auth {
        live = 0;
    }

    // --- Fungibility ---
    //修改用户抵押品余额,给已抵押物锁仓合约再增加抵押物时调用
    //借贷的第一步，会有一个join合约，就是帮忙保管币/代币。
    //调用join方法，会将币/代币转移到join合约地址下，然后join合约会调用vat.slip方法
    function slip(bytes32 ilk, address usr, int256 wad) external note auth {
        gem[ilk][usr] = add(gem[ilk][usr], wad);
    }
    //给dst转抵押品 
    //在拍卖时通过dai拍卖ETH,则ilk为dai的id,src为dai持有者地址，dst为拍卖合约flip合约地址，wad为出价金额
    function flux(bytes32 ilk, address src, address dst, uint256 wad) external note {
        require(wish(src, msg.sender), "Vat/not-allowed");
        gem[ilk][src] = sub(gem[ilk][src], wad);
        gem[ilk][dst] = add(gem[ilk][dst], wad);
    }
    //给dst转稳定币dai
    function move(address src, address dst, uint256 rad) external note {
        require(wish(src, msg.sender), "Vat/not-allowed");
        dai[src] = sub(dai[src], rad);
        dai[dst] = add(dai[dst], rad);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- CDP Manipulation ---
    //i 抵押物的标识， u cdp所有者，v 抵押物所有者，w 获得dai的所有者，dink 抵押物数量，dart 借出的债务Dai数量
    //修改用户u的CDP，使用用户v的gem，为用户w创造dai
    //当dart<0 时，是在还贷也就是赎回抵押物 
    function frob(bytes32 i, address u, address v, address w, int dink, int dart) external note {
        // system is live
        require(live == 1, "Vat/not-live");
        //用户u的个人债务
        Urn memory urn = urns[i][u];
        //抵押类型i
        Ilk memory ilk = ilks[i];
        // ilk has been initialised
        require(ilk.rate != 0, "Vat/ilk-not-init");
        //用户总的抵押物数量
        urn.ink = add(urn.ink, dink);
        //用户的借贷数量
        urn.art = add(urn.art, dart);
        //抵押物已经借出的总的借贷
        ilk.Art = add(ilk.Art, dart);
        //此笔借贷加上产生的累计稳定费
        int dtab = mul(ilk.rate, dart);
        //此用户的总的债务加上产生的稳定费
        uint tab = mul(ilk.rate, urn.art);
        //系统债务总量
        debt     = add(debt, dtab);
        //当dart<0 时，是在还贷也就是赎回抵押物
        //当赎回抵押物或者还没达到债务上限
        // either debt has decreased, or debt ceilings are not exceeded
        //每种抵押品都有一个可借贷上限
        require(either(dart <= 0, both(mul(ilk.Art, ilk.rate) <= ilk.line, debt <= Line)), "Vat/ceiling-exceeded");
        // urn is either less risky than before, or it is safe
        //随着抵押物价格变化，总的债务要小于抵押物安全价格时抵押物所值价值
        require(either(both(dart <= 0, dink >= 0), tab <= mul(urn.ink, ilk.spot)), "Vat/not-safe");
    
        // urn is either more safe, or the owner consents
        require(either(both(dart <= 0, dink >= 0), wish(u, msg.sender)), "Vat/not-allowed-u");
        // collateral src consents
        require(either(dink <= 0, wish(v, msg.sender)), "Vat/not-allowed-v");
        // debt dst consents
        require(either(dart >= 0, wish(w, msg.sender)), "Vat/not-allowed-w");

        // urn has no debt, or a non-dusty amount
        require(either(urn.art == 0, tab >= ilk.dust), "Vat/dust");
       //进行扣除/赎回抵押物(gem)，借出/偿还dai。
        gem[i][v] = sub(gem[i][v], dink);
        dai[w]    = add(dai[w],    dtab);

        urns[i][u] = urn;
        ilks[i]    = ilk;
    }
    // --- CDP Fungibility ---
    function fork(bytes32 ilk, address src, address dst, int dink, int dart) external note {
        Urn storage u = urns[ilk][src];
        Urn storage v = urns[ilk][dst];
        Ilk storage i = ilks[ilk];

        u.ink = sub(u.ink, dink);
        u.art = sub(u.art, dart);
        v.ink = add(v.ink, dink);
        v.art = add(v.art, dart);

        uint utab = mul(u.art, i.rate);
        uint vtab = mul(v.art, i.rate);

        // both sides consent
        require(both(wish(src, msg.sender), wish(dst, msg.sender)), "Vat/not-allowed");

        // both sides safe
        require(utab <= mul(u.ink, i.spot), "Vat/not-safe-src");
        require(vtab <= mul(v.ink, i.spot), "Vat/not-safe-dst");

        // both sides non-dusty
        require(either(utab >= i.dust, u.art == 0), "Vat/dust-src");
        require(either(vtab >= i.dust, v.art == 0), "Vat/dust-dst");
    }
    // --- CDP Confiscation ---
    //市场剧烈波动时可能会资不抵债，引发清算
    //本函数是执行最底层的清算逻辑，负责资产状态监控，标记危险资产的Agent,是另一个核心合约Cat
    function grab(bytes32 i, address u, address v, address w, int dink, int dart) external note auth {
        Urn storage urn = urns[i][u];
        Ilk storage ilk = ilks[i];

        urn.ink = add(urn.ink, dink);
        urn.art = add(urn.art, dart);
        ilk.Art = add(ilk.Art, dart);

        int dtab = mul(ilk.rate, dart);

        gem[i][v] = sub(gem[i][v], dink);
        sin[w]    = sub(sin[w],    dtab);
        vice      = sub(vice,      dtab);
    }

    //创建/销毁相等数量的稳定币和系统债务
    //只有Vom合约可以调用
    // --- Settlement ---
    function heal(uint rad) external note {
        //u为vow合约地址
        address u = msg.sender;
        sin[u] = sub(sin[u], rad);
        dai[u] = sub(dai[u], rad);
        vice   = sub(vice,   rad);
        debt   = sub(debt,   rad);
    }
    //债务计算
    function suck(address u, address v, uint rad) external note auth {
        sin[u] = add(sin[u], rad);
        dai[v] = add(dai[v], rad);
        vice   = add(vice,   rad);
        debt   = add(debt,   rad);
    }
    //提高/降低稳定费用
    // --- Rates ---
    function fold(bytes32 i, address u, int rate) external note auth {
        require(live == 1, "Vat/not-live");
        Ilk storage ilk = ilks[i];
        ilk.rate = add(ilk.rate, rate);
        int rad  = mul(ilk.Art, rate);
        dai[u]   = add(dai[u], rad);
        debt     = add(debt,   rad);
    }
}
