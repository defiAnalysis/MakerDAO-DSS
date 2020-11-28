## MakerDAO-DSS代码解析

本代码库包含了MakerDAO项目的多抵押品抵押的智能合约核心代码解析。



**MakerDAO项目概述**

​		MakerDao的核心，是用户通过抵押ETH等资产，变现出Dai，一个跟美元1:1软绑定的稳定币。而不同于其他稳定币的实现，Dai完全通过市场机制控制与美元的1:1兑换比例，一切通过去中心化完全开源的智能合约实现对Dai的价值保证。



更多MakerDAO项目知识请阅读以下文档。

[MakerDAO项目概述](./doc/01-MakerDAO项目概述.md)

[Maker协议白皮书](https://makerdao.com/zh-CN/whitepaper/#%E6%91%98%E8%A6%81)

[Dai稳定货币系统白皮书](./doc/Dai-Whitepaper-Dec17-zh.pdf)



## MakerDAO核心部件智能合约

MakerDAO 是由多个合约组成，其中最重要的三个合约叫做核心模块（Core Module），而核心模块中，又以 Vat 合约最为重要（下面中最大的圆柱形的部分），倘若日后发现了更好的方案，MakerDAO 的合约发生升级，那么最不可能发生变化的就是 Vat 合约。

![](https://gitee.com/superbbb/hayden-note/raw/master/img/Maker协议.png)



​		DAI 的铸造过程并不是由中央金融机构宏观调控完成的，而是通过在智能合约中托管的超额抵押物。在多抵押 DAI 合约中，负责托管抵押物的数据结构 由原先的 CDPs（抵押债仓）变更为了 Vualts，负责描述相关行为的合约就叫做 Vat。



智能合约模块与功能：

- [vat.sol](./src/vat.sol)   Vat是dss的核心。它储存金库，并追踪所有相关的Dai和抵押品余额
- [spot.sol](./dss/Spot.sol) Spot合约是预言机和核心模块vat直接的接口，实现给抵押物喂价 
- [cat.sol](./src/cat.sol) Cat合约是系统的清算代理，它使keepers用户能够将安全线以下的债仓发送给拍卖

- [flip.sol](./src/flip.sol) Flip合约是拍卖合约，负责在 CDP 清算时卖掉 Dai 的 抵押品
- [join.sol](./src/join.sol) 主要为GemJoin和DaiJoin两个合约，是ERC20抵押物Token与稳定币Dai的适配器
- [dai.sol](./src/dai.sol) 稳定币Dai的标准ERC20实现
- [vow.sol](./src/vow.sol) vow合约通过拍卖债务来弥补赤字，通过拍卖盈余来偿还盈余
- [flop.sol](./src/flop.sol) 债务拍卖合约，当系统产生债务时拍卖MKR获得固定数量的内部系统Dai来摆脱vow债务
- [flap.sol](./src/flap.sol) 盈余拍卖合约，用于通过拍卖固定数量的内部Dai来换取MKR，从而摆脱Vow的剩余
- [pot.sol](./src/pot.sol) Pot合约是储蓄率(DSR)的核心。 它允许用户存款dai并激活Dai储蓄率，并在dai上赚取储蓄
- [jug.sol](./src/jug.sol) 为特定抵押品计算累计稳定费用
- [end.sol](./src.end.sol) 协调系统的关闭



### 用户抵押合约流程

---

MakerDAO中使用 routing 合约来处理用户交互一样，普通用户与核心模块的交互逻辑是在 [代理模块（Proxy Module）]() 中进行的。下面流程省略了Proxy Actions部分，直接通过CDP Manager与核心模块进行交互(后续正在完善`代理模块`代码部分再进行修改)。



举个例子，如果你想抵押ETH，贷出Dai，界面操作上会有以下几个步骤：

1. 选择抵押物种类

2. 输入抵押物ETH数量与借贷Dai数量

3. 归还Dai

    

### Vault合约代码交互生命周期：

​	**抵押借贷**

1. 创建Vault

    1. `DssCdpManager.open()`  -调用DssCdpManager.sol中的open函数，传入抵押物ETH名称和包含ETH钱包的地址，回Vault的cdpId,将创建一个新的Vault。

    2. `DssCdpManager.urns()` -调用DssCdpManager.sol中的urns函数，传入cdpId,返回Vault的地址。每个抵押物都有一个Vault，每个Vault都有一个独一无二的地址，就像钱包地址一样。

        

2. 在Valut中存入抵押物

    1. `ETH.approve()` - 调用抵押物ETH对应的ERC20合约中的weth.sol中的approve函数，传入join.sol的地址与抵押物抵押的数量，允许ETH的适配器从你的钱包取出相应数量的抵押物。
    2. `GemJoin.join()`  - 调用join.sol合约的join函数，传入Vault地址与抵押物数量。转移抵押物ETH到ETH的适配器GemJoin中。

3. 锁定抵押物生成Dai

    1. `DssCdpManager.frob()` - 调用`DssCdpManager.sol中的frob函数，传入cdpId，抵押物数量和借出的Dai数量，函数内调用vat.sol合约内frob函数，锁定抵押物ETh生成Dai，在Vault内部可以查询到抵押物和借贷Dai数量。
    2. ``DssCdpManager.move()` -调用DssCdpManager.sol中的move函数，传入cdpId,钱包地址与借贷Dai金额。函数内会调用vat.sol合约中的move函数，增加钱包地址上Dai数量，减少Vault地址Dai数量，在vat中记录的数量没有触发真正的Dai进行转账。只是在Vault系统上可以查询的各自账户Dai数量。
    3. `vat.hope()` -调用vat.sol中的hope函数，传入join.sol的地址，授权给join合约地址，DaiJoin适配器能够从Dai合约提取Dai代币。
    4. `DaiJoin.exit()` -调用join.sol中的exit函数，传入钱包地址和借贷Dai数量，函数内部会调用vat.move函数，也会调用Dai的Mint给钱包地址铸造Dai货币。可以使用钱包操作Dai。

    

    **偿还Dai**

    1. `dai.approve()` -调用dai.sol中的approve函数，传入join.sol合约的地址与偿还债务总额(包括借贷和稳定率，相当于贷款率)，允许DaiJoin适配器能够从你的钱包地址操作相应的Dai。
    2. `DaiJoin.join()` -调用join.sol中的join函数，传入Vault地址与偿还贷款Dai数量，系统将调用dai.sol中的burn函数销毁Dai。
    3. `DssCdpManager.frob()` -调用DssCdpManager.sol中的frob函数，传入cdpId，抵押物数量与偿还Dai数量。函数内调用vat.sol合约内frob函数，减去系统内部Vault地址记录的Dai数量和系统内部的债务。

    **取回抵押物**

    1. ``DssCdpManager.flux()` -调用DssCdpManager.sol中的flux函数，传入cdpId，钱包地址与抵押物数量。函数内调用vat.sol合约内flux函数，修改系统内部Vault地址记录的抵押物数量和钱包地址抵押物数量。
    2. `GemJoin.exit()` -调用join.sol中的exit函数，传入钱包地址和抵押物数量，将抵押物从GemJoin的抵押品适配器合约地址转到钱包地址。取回抵押物。

    

    ### Keepers用户发起清算

    ---

    Keepers用户通过监控MakerDao系统运行，寻找资不抵债的借贷，从而寻找套利机会，有3%的套利空间。他们主要通过发起清算和拍卖来逐出系统中资不抵债的用户，获取他们的抵押。

    

    **keepers清算流程:**

    1. `Cat.bite()` -调用cat.sol中的bite函数，任何人都调用bite，但只有在抵押债仓不安全的情况下才会成功。内部会调用flip.kick函数进行抵押品清算拍卖。
    2. `flip.tend()` -调用flip.sol中的tend函数进行第一阶段竞拍，第一阶段拍卖为全部抵押物，如果竞拍时间到结束且价格还没到可以偿还完借贷金额加上稳定率费用，则价高者得胜，每次出价需要在上个出价人基础上最少加上一定比例(具体值系统参数确定)。当这一竞拍阶段竞拍者出价刚好偿还完借贷额加稳定费用，则进行第二阶段拍卖。
    3. `flip.dent()` -第二阶段拍卖调用flip.sol中的dent函数，竞拍者保持第一阶段最后出价，及可以还完全部借贷加稳定费用，降低抵押物数量，每次也是最低一定比例下降。
    4. `flip.deal` -如果竞拍到期，任何人可以调用flip.sol中的deal函数来完成竞拍。当结算时，抵押物交给获胜者。

    

    

    

    

