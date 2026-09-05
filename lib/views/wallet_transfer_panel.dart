import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../models/wallet_transfer.dart';
import '../services/trading_service.dart';

class WalletTransferPanel extends StatefulWidget {
  const WalletTransferPanel({
    super.key,
    required this.service,
    required this.accountLabel,
    required this.onTransferred,
  });

  final TradingService service;
  final String accountLabel;
  final Future<void> Function() onTransferred;

  @override
  State<WalletTransferPanel> createState() => _WalletTransferPanelState();
}

class _WalletTransferPanelState extends State<WalletTransferPanel> {
  final _amount = TextEditingController();
  late final int _sessionGeneration;
  List<TransferBalance> _balances = [];
  TransferWallet _from = TransferWallet.exchange;
  TransferWallet _to = TransferWallet.margin;
  String? _currency;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  String? _result;

  @override
  void initState() {
    super.initState();
    _sessionGeneration = widget.service.walletSessionGeneration;
  }

  List<TransferBalance> get _sources =>
      _balances.where((b) => b.wallet == _from).toList()
        ..sort((a, b) => a.currency.compareTo(b.currency));

  TransferBalance? get _source {
    for (final balance in _sources) {
      if (balance.currency == _currency) return balance;
    }
    return null;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _balances = [];
    });
    try {
      final balances = await widget.service.getTransferBalances(
        sessionGeneration: _sessionGeneration,
      );
      if (!mounted) return;
      setState(() {
        _balances = balances;
        if (!_sources.any((b) => b.currency == _currency)) {
          _currency = _sources.firstOrNull?.currency;
          _amount.clear();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '钱包余额刷新失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmAndTransfer() async {
    if (_busy || _loading) return;
    final source = _source;
    final destination = _to;
    late final Decimal quantity;
    try {
      quantity = parseTransferAmount(_amount.text);
      if (source == null || source.available == null) {
        throw StateError('请选择币种并获取钱包可用余额');
      }
      if (quantity > source.available!) {
        throw StateError('划转数量超过钱包可用余额');
      }
    } catch (e) {
      setState(() => _error = e.toString());
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认同账号钱包划转'),
          content: Text(
            '${widget.accountLabel}\n\n'
            '${source.wallet.label} → ${destination.label}\n'
            '转出：$quantity ${source.currency}\n'
            '转入：$quantity ${destination.currencyFor(source.currency)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认划转'),
            ),
          ],
        ),
      );
      // A session change replaces this panel, invalidating its confirmation.
      if (!mounted || confirmed != true) return;
      try {
        await widget.service.transferBetweenWallets(
          sessionGeneration: _sessionGeneration,
          from: source.wallet,
          to: destination,
          currency: source.currency,
          amount: quantity.toString(),
        );
      } catch (e) {
        if (mounted) {
          setState(() => _error = '未能确认划转成功：$e。请核对余额和账本后再操作。');
        }
        return;
      }
      if (!mounted ||
          !widget.service.isCurrentWalletSession(_sessionGeneration)) {
        return;
      }
      setState(() {
        _amount.clear();
        _result =
            '划转成功：$quantity ${source.currency}，'
            '${source.wallet.label} → ${destination.label}';
      });
      await _refresh();
      if (mounted) await widget.onTransferred();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final available = source?.available;
    final enabled = !_busy && !_loading;
    return Card(
      child: ExpansionTile(
        title: const Text('Transfer 钱包划转'),
        subtitle: const Text(
          '同账号 Exchange / Margin / Funding / Capital Raise / Derivatives',
        ),
        onExpansionChanged: (expanded) {
          if (expanded && !_busy) _refresh();
        },
        childrenPadding: const EdgeInsets.all(12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading || _busy) const LinearProgressIndicator(),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<TransferWallet>(
                  key: ValueKey('from-$_from'),
                  initialValue: _from,
                  decoration: const InputDecoration(labelText: '转出钱包'),
                  items: TransferWallet.values
                      .map(
                        (w) => DropdownMenuItem(value: w, child: Text(w.label)),
                      )
                      .toList(),
                  onChanged: enabled
                      ? (wallet) {
                          if (wallet == null) return;
                          setState(() {
                            final previous = _from;
                            _from = wallet;
                            if (_to == _from) _to = previous;
                            _currency = _sources.firstOrNull?.currency;
                            _amount.clear();
                            _error = null;
                            _result = null;
                          });
                        }
                      : null,
                ),
              ),
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<TransferWallet>(
                  key: ValueKey('to-$_to-$_from'),
                  initialValue: _to,
                  decoration: const InputDecoration(labelText: '转入钱包'),
                  items: TransferWallet.values
                      .where((w) => w != _from)
                      .map(
                        (w) => DropdownMenuItem(value: w, child: Text(w.label)),
                      )
                      .toList(),
                  onChanged: enabled
                      ? (wallet) {
                          if (wallet != null) setState(() => _to = wallet);
                        }
                      : null,
                ),
              ),
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('currency-$_from-$_currency-$_loading'),
                  initialValue: source?.currency,
                  decoration: const InputDecoration(labelText: '转出币种'),
                  items: _sources
                      .map(
                        (b) => DropdownMenuItem(
                          value: b.currency,
                          child: Text(b.currency),
                        ),
                      )
                      .toList(),
                  onChanged: enabled
                      ? (currency) => setState(() {
                          _currency = currency;
                          _amount.clear();
                        })
                      : null,
                ),
              ),
              SizedBox(
                width: 230,
                child: TextField(
                  controller: _amount,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '划转数量'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (source != null) ...[
            Text(
              '余额：${source.balance} ${source.currency}  '
              '可用：${available ?? '尚未计算'}',
            ),
            Text('转入币种：${_to.currencyFor(source.currency)}'),
          ] else if (!_loading)
            const Text('当前转出钱包没有可划转币种。'),
          const Text('各钱包支持的币种、账号权限和划转限制以 Bitfinex 为准。'),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: enabled ? _refresh : null,
                child: const Text('刷新钱包余额'),
              ),
              TextButton(
                onPressed:
                    enabled && available != null && available > Decimal.zero
                    ? () => _amount.text = available.toString()
                    : null,
                child: const Text('全部可用'),
              ),
              FilledButton(
                onPressed:
                    enabled && available != null && available > Decimal.zero
                    ? _confirmAndTransfer
                    : null,
                child: Text(_busy ? '处理中…' : '划转'),
              ),
            ],
          ),
          if (_result != null) Text(_result!),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
