# Bitfinex Chase

基于 `deribit_chase` 的 Flutter 桌面/移动应用移植。保留交易对、订单、仓位、历史、账户、日志、配置导入导出和主题布局，使用 Bitfinex v2 REST/WebSocket API。

## 运行

```sh
flutter pub get
flutter run -d macos
```

在连接面板选择 **Paper Trading** 或 Live，填写 **API Key / API Secret**，连接并认证。两个模式使用相同 API 域名；认证时读取账户 `PPT_ENABLED` 标志，账户与所选模式不匹配就断开。应用不会自动读取或打包项目 `.env`；它仅供本地验收工具使用。

默认 Paper 交易对：`TESTBTC:TESTUSD`、`TESTBTC:TESTUSDT`、`TESTETH:TESTUSD`、`TESTBTCF0:TESTUSDTF0`。Live 默认：`BTCUSD`、`BTCUST`（BTC/USDT 现货）、`ETHUSD`、`BTCF0:USTF0`。自定义交易对可填写带或不带小写 `t` 前缀的 Bitfinex 符号，交易前会从交易所目录验证。衍生品需要在对应保证金钱包准备结算资产。

## 功能

- 盘口与行情订阅、买卖快捷操作、数量/计价金额换算、价格 tick 偏移。
- 限价 Post-only、市价、改单和撤单；改单保留买卖方向，纯改价不重发数量，避免部分成交后增加剩余订单。
- 普通限价单可选择 Post-only，Margin 和合约订单可选择 Reduce-only；按订单追价、价差百分比过滤和最大偏离限制。下单/改单/撤单走原生 WebSocket，账户查询不占用交易请求队列。
- 移动端底部导航（行情/订单/持仓/历史/账户/更多），滑动顺序与底栏一致，支持 Ctrl+Tab / Ctrl+Shift+Tab。
- Android 后台连接保活默认关闭，可在 Home 开启；此选项支持持久化及配置导入导出。
- 线性合约的杠杆、可用资金百分比下单、同方向加仓（数量/计价金额/资金比例）、按比例平仓、全部平仓、反手、保本止损。
- 现货交易对支持 Exchange / Margin 切换；Margin 支持限价/市价买卖、追价、加仓、按比例平仓、全部平仓、反手和保本止损。只有交易所确认支持保证金的交易对可以选择 Margin。
- 原生 Stop、Stop Limit、Trailing Stop；Margin 和合约保护订单使用 reduce-only。
- 成交历史按日期查询、快捷日期范围、日分组、订单聚合、成交选择与统计；分页按成交 ID 去重。
- 钱包余额、可用/冻结金额和并发资产折算；隐藏零余额按 balance 判断；提现与提现历史。提现前需填写 Bitfinex method/network、地址和可选 Memo，用户确认后才提交。Paper 不提供实际提现。
- 账户页提供同账号钱包划转：Exchange、Margin、Funding、Capital Raise、Derivatives。按转出钱包选择币种，支持全部可用余额和提交前确认；提交前复核余额，成功后刷新钱包及账户。Derivatives 自动映射对应 F0 币种，实际币种资格与账号权限由 Bitfinex 校验。
- 环境隔离的交易对元数据缓存，以及认证后的账户信息/提款记录缓存；缓存不会恢复实时价格、余额或交易权限。
- 设置持久化、可选记住凭证、配置导入导出及加密导出、主题、桌面窗口恢复、成交通知。

## 与原项目的差异

- Bitfinex 使用 5 位价格有效数字（最多 8 位小数）和最多 8 位数量小数，不使用 Deribit 固定 tick/反向合约数量规则。
- Bitfinex 原生止损使用**最新成交价**触发；没有等价的 Mark/Index 触发选择、Take Profit Market 和触发式 Take Profit Limit。相关选择已禁用，限价平仓仍可用于止盈。不会通过客户端轮询伪装成交易所托管的保护单。
- 没有等价的公告列表/推送/已读状态和提款地址簿 API；公告页说明这一限制，提款改为显式填写地址和网络。
- 账户显示实际钱包数据；不展示不存在的期权、Deribit session PNL 等字段。仓位参考价及估算 PNL 与交易所最终结算可能有差异。
- 适配范围是**Exchange 现货、现货 Margin 与线性衍生品**。现货选择 Margin 后使用保证金钱包，需先在 Bitfinex 准备 Margin 抵押资金。Margin 按基础币数量或计价金额下单，实际杠杆由交易所保证金与借贷决定，不使用衍生品的杠杆参数或资金百分比下单。
- 模式选择只影响新订单；现有订单和仓位按自身类型管理。现货成交历史可分别加载 Exchange / Margin，避免混算 FIFO 盈亏。Margin 未实现盈亏与账户净值按最新成交价估算为计价币金额，融资费用与最终结算可能不同。
- Bitfinex 改单后的快照可能省略 Post-only 标志；应用在当前会话保留已知的 Post-only 设置，每次改单显式发送。重新连接后以交易所快照为准，追价需重新开启。
- 网络断线后会退避重连，并利用当前会话中的凭证重新认证、恢复订阅；追价需重新开启。手动断开停止重连，写请求超时不会自动重发。交易所接口存在频率限制；追价收到改单错误会停止并记入日志，超时写请求不自动重发。

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

`dart run tool/paper_margin_smoke.dart` 验证同一交易对的 Exchange/Margin 隔离、Post-only 改单及越价取消、Margin 开多/加仓/减仓/反手做空/平仓、保护单与历史。要求 Paper 账户没有现存挂单或仓位；必要时临时从 Exchange 划转 TESTUSD，使保证金可用余额达到 25，结束后清理本轮订单/仓位并返还临时抵押资金（扣除交易损耗）。

`dart run tool/paper_wallet_transfer_scenarios.dart` 使用 `.env` 进行真实 Paper 钱包划转验收。要求没有挂单或仓位，Exchange 中至少有 0.03 TESTUSD、Derivatives 中至少有 0.04 TESTUSDTF0；逐笔划转 0.01，校验两端余额，最后逆序归还。资金写入间隔至少 30 秒以避开 Paper 的结算检查，不自动重试；任何服务端拒绝均明确输出并以非零状态退出。可用重复的 `--route=exchange:margin`、`--route=derivatives:margin` 等参数仅验证指定路径，钱包名使用 `exchange`、`margin`、`funding`、`capitalRaise`、`derivatives`。Paper 的 Capital Raise 可能拒绝测试币，不能将拒绝结果视为成功划转；失败后先核对余额再重新执行。

`tool/paper_view_model_scenarios.dart` 验证界面模型的认证、百分比下单、保护单、平仓、反手、历史、账户以及自动断线重连。它同样只读取进程环境中的验收凭证。

`tool/paper_desktop_scenarios.dart` 在 Flutter 运行时中验证上层追价、价差过滤、断线与重新订阅，使用进程环境中的 `API_KEY` / `API_SECRET`。它是单独的业务验收入口，不是交付应用入口；发布和正常运行均使用 `lib/main.dart`。

## 实盘只读验收

将真实账户凭据保存在本地 `.env.live`（同样使用 `API_KEY` / `API_SECRET`，已被 Git 忽略），执行：

```sh
dart run tool/live_readonly.dart
```

验收覆盖认证、账户及余额模型、现货/合约元数据及 Margin 资格、盘口/Ticker、USD/BTC/CNY 估值、订单/持仓、成交历史和提款历史。传输层只允许指定的读取接口，并禁止交易/资金写请求和会触发撤单的 dead-man switch；输出不包含密钥或账户明细。当前账户没有订单/持仓时，只能验证对应空快照，不会为测试创建仓位。

## GitHub Actions Secrets

在仓库 **Settings → Secrets and variables → Actions → Repository secrets** 中配置：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEY_ALIAS` | Android 签名 keystore 中的密钥别名 |
| `ANDROID_KEY_BASE64` | 签名 `.jks` / keystore 文件的完整 Base64 内容 |
| `ANDROID_KEY_PASSWORD` | keystore 和该密钥的密码；沿用原项目约定，两者必须相同 |

`build-mobile.yml` 在推送 `main` 时分别构建 arm64-v8a、armeabi-v7a、x86_64 的签名 Release APK，并上传各自的 workflow artifact。Android CI 固定使用已验证的 Flutter 3.35.5，与项目的 Gradle 8.12 配套。Flutter Release 不支持原 Tauri workflow 中的 32 位 x86，因此没有该构建项。缺少签名 Secret 时 Android job 明确失败，不生成替代的未签名 APK。

iOS job 使用 `--no-codesign` 进行编译检查，不生成可安装的签名 IPA，不需要 Apple 证书或相关 Secret。桌面 workflow 覆盖 Windows、macOS、Linux，不需要自定义 Secret，分别上传便携 Windows 应用、未公证的 macOS DMG 和保留执行权限的 Linux tar.gz。Bitfinex `API_KEY` / `API_SECRET` 仅用于本地验收，不要配置为构建 Secret。

本地可使用 `.github/workflows/act-build-android-release.sh` 运行同一 Android workflow。需要已有 `act`、Docker、Python 3，并显式设置 `ANDROID_KEYSTORE_PATH`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`；脚本不安装这些工具、不输出密钥，失败即退出。

## 远端基线核对

本轮以 `deribit-chase` 远端 `master` 的 `26cce1f8af5f54e50af43615df8e0c51b604eda1` 为对照，补齐加仓、订单标志、移动导航、可选保活、缓存、批量恢复和多平台 CI。继续使用 Flutter；Tauri 特有的 MSI/AppImage 打包格式对应为上述便携产物。

桌面系统钥匙串存储尚待新增依赖授权；当前“记住凭证”仍使用原有 SharedPreferences，默认关闭。

## API 参考

- [Paper Trading](https://docs.bitfinex.com/docs/paper-trading)
- [WebSocket authentication](https://docs.bitfinex.com/docs/ws-auth)
- [Order book](https://docs.bitfinex.com/reference/ws-public-books)
- [Submit order](https://docs.bitfinex.com/reference/rest-auth-submit-order)、[Update order](https://docs.bitfinex.com/reference/rest-auth-update-order)
- [User info / Paper flag](https://docs.bitfinex.com/reference/rest-auth-info-user)
- [Wallets](https://docs.bitfinex.com/reference/rest-auth-wallets)、[Transfer Between Wallets](https://docs.bitfinex.com/reference/rest-auth-transfer)、[Trades](https://docs.bitfinex.com/reference/rest-auth-trades)
