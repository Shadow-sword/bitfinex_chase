# Bitfinex Chase

基于 `deribit_chase` 的 Flutter 桌面/移动应用移植。保留交易对、订单、仓位、历史、账户、日志、配置导入导出和主题布局，使用 Bitfinex v2 REST/WebSocket API。

## 运行

```sh
flutter pub get
flutter run -d macos
```

在连接面板选择 **Paper Trading** 或 Live，填写 **API Key / API Secret**，连接并认证。两个模式使用相同 API 域名；认证时读取账户 `PPT_ENABLED` 标志，账户与所选模式不匹配就断开。应用不会自动读取或打包项目 `.env`；它仅供本地验收工具使用。

默认 Paper 交易对：`TESTBTC:TESTUSD`、`TESTETH:TESTUSD`、`TESTBTCF0:TESTUSDTF0`。Live 默认：`BTCUSD`、`ETHUSD`、`BTCF0:USTF0`。自定义交易对可填写带或不带小写 `t` 前缀的 Bitfinex 符号，交易前会从交易所目录验证。衍生品需要在对应保证金钱包准备结算资产。

## 功能

- 盘口与行情订阅、买卖快捷操作、数量/计价金额换算、价格 tick 偏移。
- 限价 Post-only、市价、改单和撤单；改单保留买卖方向，纯改价不重发数量，避免部分成交后增加剩余订单。
- 按订单开启追价、价差百分比过滤、最大价格偏离限制、关闭追价；断开连接立即清除交易状态。
- 线性合约的杠杆、可用资金百分比下单、按比例平仓、全部平仓、反手、保本止损。
- 原生 Stop、Stop Limit、Trailing Stop；合约保护订单使用 reduce-only。
- 成交历史按日期查询、快捷日期范围、日分组、订单聚合、成交选择与统计；分页按成交 ID 去重。
- 钱包余额、可用/冻结金额和资产折算；提现与提现历史。提现前需填写 Bitfinex method/network、地址和可选 Memo，用户确认后才提交。Paper 不提供实际提现。
- 设置持久化、可选记住凭证、配置导入导出及加密导出、主题、桌面窗口恢复、成交通知。

## 与原项目的差异

- Bitfinex 使用 5 位价格有效数字（最多 8 位小数）和最多 8 位数量小数，不使用 Deribit 固定 tick/反向合约数量规则。
- Bitfinex 原生止损使用**最新成交价**触发；没有等价的 Mark/Index 触发选择、Take Profit Market 和触发式 Take Profit Limit。相关选择已禁用，限价平仓仍可用于止盈。不会通过客户端轮询伪装成交易所托管的保护单。
- 没有等价的公告列表/推送/已读状态和提款地址簿 API；公告页说明这一限制，提款改为显式填写地址和网络。
- 账户显示实际钱包数据；不展示不存在的期权、Deribit session PNL 等字段。仓位参考价及估算 PNL 与交易所最终结算可能有差异。
- 适配范围是**现货与线性衍生品**。Bitfinex 现货保证金仓位不能用 Exchange 订单平仓，应用会拒绝这种仓位操作。
- 网络断线后会退避重连，并利用当前会话中的凭证重新认证、恢复订阅；追价需重新开启。手动断开停止重连，写请求超时不会自动重发。REST 各接口存在频率限制，大量并发追价应关注日志中的拒绝信息。

## 本地 Paper 验收

在项目根目录创建 `.env`（已加入 Git 忽略）：

```dotenv
API_KEY=your_paper_api_key
API_SECRET=your_paper_api_secret
```

```sh
# 只读：连接、账户类型、行情、钱包、订单和持仓
dart run tool/paper_smoke.dart
# 真实模拟交易：限价下单/改价/撤单、市价买卖、历史记录
dart run tool/paper_smoke.dart --trade
```

`--trade` 会使用模拟资产，撤销验收创建的挂单，并仅卖出该轮买入的现货数量；不适用于 Live。需要至少少量 TESTUSD 可用余额。工具不输出密钥。

`dart run tool/paper_derivatives_smoke.dart` 验证合约下单、杠杆改单、三类止损、部分平仓、反手和清仓。余额不足时可显式加 `--fund`，用 0.0004 TESTBTC 对应的模拟美元兑换并划转模拟保证金。

`tool/paper_view_model_scenarios.dart` 验证界面模型的认证、百分比下单、保护单、平仓、反手、历史、账户以及自动断线重连。它同样只读取进程环境中的验收凭证。

`tool/paper_desktop_scenarios.dart` 在 Flutter 运行时中验证上层追价、价差过滤、断线与重新订阅，使用进程环境中的 `API_KEY` / `API_SECRET`。它是单独的业务验收入口，不是交付应用入口；发布和正常运行均使用 `lib/main.dart`。

## API 参考

- [Paper Trading](https://docs.bitfinex.com/docs/paper-trading)
- [WebSocket authentication](https://docs.bitfinex.com/docs/ws-auth)
- [Order book](https://docs.bitfinex.com/reference/ws-public-books)
- [Submit order](https://docs.bitfinex.com/reference/rest-auth-submit-order)、[Update order](https://docs.bitfinex.com/reference/rest-auth-update-order)
- [User info / Paper flag](https://docs.bitfinex.com/reference/rest-auth-info-user)
- [Wallets](https://docs.bitfinex.com/reference/rest-auth-wallets)、[Trades](https://docs.bitfinex.com/reference/rest-auth-trades)
