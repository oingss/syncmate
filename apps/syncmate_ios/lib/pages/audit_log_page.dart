import 'dart:io';

import 'package:flutter/material.dart';

/// 操作留痕查看页：读取本机审计日志尾部（最新在前，最近 200 行）。
class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key, required this.logPath});

  final String? logPath;

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  List<String> _lines = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final path = widget.logPath;
    if (path == null) {
      setState(() {
        _loading = false;
        _error = '操作留痕未启用（日志路径不可写）';
      });
      return;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        setState(() {
          _lines = [];
          _loading = false;
        });
        return;
      }
      final all = await file.readAsLines();
      final tail = all.length > 200 ? all.sublist(all.length - 200) : all;
      if (!mounted) return;
      setState(() {
        _lines = tail.reversed.toList();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('操作日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_lines.isEmpty) {
      return const Center(child: Text('暂无日志记录'));
    }
    return ListView.builder(
      itemCount: _lines.length,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            _lines[index],
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        );
      },
    );
  }
}
