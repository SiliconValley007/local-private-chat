import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../errors.dart';
import '../widgets/error_banner.dart';

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _title = TextEditingController();
  final _selected = <int>{};
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await context.read<AppState>().refreshUsers();
    } catch (e) {
      _error = friendlyMessage(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Please enter a name for the group.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final conv = await context.read<AppState>().createGroup(
        _title.text.trim(),
        _selected.toList(),
      );
      if (mounted) Navigator.of(context).pop(conv);
    } catch (e) {
      setState(() => _error = friendlyMessage(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: const Text('Create'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: 'Group name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ErrorBanner(message: _error!),
                  ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: state.users.length,
                    itemBuilder: (context, index) {
                      final u = state.users[index];
                      final checked = _selected.contains(u.id);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(u.id);
                            } else {
                              _selected.remove(u.id);
                            }
                          });
                        },
                        title: Text(u.displayName),
                        subtitle: Text('@${u.username}'),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
